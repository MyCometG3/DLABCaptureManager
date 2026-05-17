//
//  CaptureManager.swift
//  DLABCapture
//
//  Created by Takashi Mochizuki on 2017/10/09.
//  Copyright © 2017-2026 MyCometG3. All rights reserved.
//

import Cocoa
@preconcurrency import DLABridging

extension Comparable {
    internal func clipped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Sendable SampleBuffer wrapper
/// Note: CMSampleBuffer is not Sendable, but this wrapper is used to safely transfer
/// sample buffers across actor boundaries in controlled contexts where the sender
/// guarantees exclusive access.
public struct UnsafeSampleBufferWrapper: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
}

/// Sendable SampleBuffer info wrapper
/// Note: Contains non-Sendable types but used in controlled contexts where
/// the caller guarantees thread-safe access patterns.
public struct UnsafeSampleBufferInfo: @unchecked Sendable {
    var sampleBuffer: CMSampleBuffer
    var setting: DLABTimecodeSetting?
}

/// Specify preferred timecodeSource.
public enum TimecodeType: Int, Sendable {
    ///  SERIAL: validate on DLABTimecodeFormatSerial
    case SERIAL = 1
    ///  VITC: validate on DLABTimecodeFormatVITC/VITCField2
    case VITC = 2
    ///  RP188: validate on DLABTimecodeFormatRP188HighFrameRate/RP188VITC1/RP188LTC/RP188VITC2
    case RP188 = 4
    ///  CoreAudio: validate on CoreAudio SMPTETime CMAttachment (experimental)
    case CoreAudio = 8
    
    /// True if it is from any Decklink Device
    /// - Returns: Bool
    public func byDevice() -> Bool {
        switch self {
        case .SERIAL, .VITC, .RP188:
            return true
        default:
            return false
        }
    }
}

// MARK: - Bounded Sample Processing Queue

/// A lock-protected bounded work queue for callback-driven sample processing.
///
/// Each lane (audio, video) gets its own queue instance.  `maxDepth` is a hard
/// limit — when the queue is full, `enqueue` returns `false` and the caller
/// drops the sample.  This prevents unbounded task creation and memory growth
/// under sustained overload.
///
/// Work is drained in FIFO batches: items within a single batch are processed
/// in enqueue order, but a new batch may include items that arrived while the
/// previous batch was executing.  Ordering across batch boundaries is still
/// FIFO, so the net effect is FIFO within each lane.
///
/// Queued closures capture `self` weakly; work may be silently dropped during
/// teardown / deinit when the `CaptureManager` is no longer alive.
private final class BoundedWorkQueue: @unchecked Sendable {
    private let lock = UnfairLockBox()
    private var items: [@Sendable () async -> Void] = []
    let maxDepth: Int
    
    init(maxDepth: Int) {
        self.maxDepth = maxDepth
    }
    
    /// Attempt to enqueue a work item.
    ///
    /// Returns `true` on success.  Returns `false` when the queue is full;
    /// the caller should drop the sample.  Never blocks.
    func enqueue(_ work: @escaping @Sendable () async -> Void) -> Bool {
        lock.withLock {
            guard items.count < maxDepth else { return false }
            items.append(work)
            return true
        }
    }
    
    /// Atomically drain all queued items.
    func takeAll() -> [@Sendable () async -> Void] {
        lock.withLock {
            guard !items.isEmpty else { return [] }
            let result = items
            items = []
            return result
        }
    }
}

private final class WeakParentViewBox: @unchecked Sendable {
    weak var view: NSView?

    init(view: NSView?) {
        self.view = view
    }
}

/// Extension to make CaptureManager conform to Sendable for cross-actor usage.
///
/// Concurrency model — mutable state falls into these categories:
///
/// - Lock-protected runtime state: managed via ``UnfairLockBox`` and
///   ``CaptureRuntimeState`` (e.g. running, recording, timecodeReady).
/// - Set-before-capture configuration: audio/video/encoder parameters
///   expected to be configured before ``captureStartAsync()`` and not
///   mutated concurrently during capture.
/// - UI / MainActor references: ``videoPreview`` and ``parentView`` are
///   weak and expected to be read/written on the main thread / actor.
/// - Callback references: ``inputAncillaryPacketHandler``,
///   ``recordedMoviePostProcessErrorHandler``, and
///   ``captureWriterDiagnosticHandler`` are controlled-mutation
///   callbacks.
/// - Backpressure / queue state: ``BoundedWorkQueue`` instances are
///   lock-protected and shared between callback threads and persistent
///   processor ``Task``s.
///
/// Marked `@unchecked Sendable` because the class contains non-Sendable
/// stored properties whose safety is guaranteed by these conventions.
extension CaptureManager: @unchecked Sendable {
}

public class CaptureManager: NSObject, DLABInputCaptureDelegate {
    private struct CaptureRuntimeState {
        var running: Bool = false
        var recording: Bool = false
        var writerPrepared: Bool = false
        var timecodeReady: Bool = false
        var lastDuration: Float64 = 0.0
        var lastRecordedMoviePostProcessError: Error? = nil
        var stopError: (any Error)? = nil
        var audioPreviewError: (any Error)? = nil
        var currentDevice: DLABDevice? = nil
        var audioCaptureEnabled: Bool = false
        var videoCaptureEnabled: Bool = false
    }
    
    /// Verbose mode (debugging purpose)
    public var verbose: Bool = false
    
    /* ============================================ */
    // MARK: - properties - Sample processing backpressure
    /* ============================================ */
    
    private let audioQueue = BoundedWorkQueue(maxDepth: 4)
    private let videoQueue = BoundedWorkQueue(maxDepth: 4)
    private var audioProcessorTask: Task<Void, Never>?
    private var videoProcessorTask: Task<Void, Never>?
    private var parentViewUpdateTask: Task<Void, Never>?
    
    /* ============================================ */
    // MARK: - properties - Lock-protected runtime state
    /* ============================================ */
    
    private let stateLock = UnfairLockBox()
    private var runtimeState = CaptureRuntimeState()
    
    private func withRuntimeState<T>(_ body: (inout CaptureRuntimeState) -> T) -> T {
        stateLock.withLock {
            body(&runtimeState)
        }
    }
    
    private func runtimeStateValue<T>(_ keyPath: KeyPath<CaptureRuntimeState, T>) -> T {
        stateLock.withLock {
            runtimeState[keyPath: keyPath]
        }
    }
    /// True while capture is running
    public private(set) var running: Bool {
        get { runtimeStateValue(\.running) }
        set { withRuntimeState { $0.running = newValue } }
    }
    
    /// Capture device as DLABDevice object
    public internal(set) var currentDevice: DLABDevice? {
        get { runtimeStateValue(\.currentDevice) }
        set { withRuntimeState { $0.currentDevice = newValue } }
    }
    /* ============================================ */
    // MARK: - properties - Capturing audio (set before capture)
    /* ============================================ */
    
    /// Capture audio bit depth (See DLABConstants.h)
    public var audioDepth: DLABAudioSampleType = .type16bitInteger
    
    /// Capture audio channels. 2 for Stereo. 8 or 16 for discrete.
    /// Set 8 to use with hdmiAudioChannels.
    /// Set 0 to disable audioCapture and audioPreview.
    public var audioChannels: UInt32 = 2
    
    /// Capture audio bit rate (See DLABConstants.h)
    public var audioRate: DLABAudioSampleRate = .rate48kHz
    
    /// Audio Input Connection
    public var audioConnection: DLABAudioConnection = .init()
    
    /// Volume of audio preview
    public var volume: Float = 1.0 {
        didSet {
            volume = max(0.0, min(1.0, volume))
            if let preview = currentAudioPreview() {
                preview.volume = Float32(volume)
            }
        }
    }
    
    /// Use HDMI audio channel order (L R C LFE Ls Rs Rls Rrs), instead of descrete. audioChannels should be 8.
    public var hdmiAudioChannels: UInt32 = 0
    
    /// For HDMI audio channel order. Set true if (ch3,ch4) == (LFE, C), as reveresed order.
    public var reverseCh3Ch4: Bool = false
    
    /// True while audio capture is enabled
    public private(set) var audioCaptureEnabled: Bool {
        get { runtimeStateValue(\.audioCaptureEnabled) }
        set { withRuntimeState { $0.audioCaptureEnabled = newValue } }
    }
    /// AudioPreview object
    private let audioPreviewLock = UnfairLockBox()
    private var audioPreviewStorage: CaptureAudioPreview? = nil
    private var previewDisposed: Bool = false
    
    private func currentAudioPreview() -> CaptureAudioPreview? {
        audioPreviewLock.withLock {
            previewDisposed ? nil : audioPreviewStorage
        }
    }
    
    private func setAudioPreview(_ preview: CaptureAudioPreview?) {
        audioPreviewLock.withLock {
            audioPreviewStorage = preview
            previewDisposed = false
        }
    }
    
    private func takeAudioPreview() -> CaptureAudioPreview? {
        audioPreviewLock.withLock {
            guard !previewDisposed else { return nil }
            let preview = audioPreviewStorage
            audioPreviewStorage = nil
            previewDisposed = true
            return preview
        }
    }
    /* ============================================ */
    // MARK: - properties - Capturing video (set before capture)
    /* ============================================ */
    
    /// Capture video DLABDisplayMode. (See DLABConstants.h)
    public var displayMode: DLABDisplayMode = .modeNTSC
    
    /// Capture video pixelFormat (See DLABConstants.h)
    public var pixelFormat: DLABPixelFormat = .format8BitYUV
    
    /// Override specific CoreVideoPixelFormat (with conversion)
    ///
    /// Set 0 to use Default CVPixelFormat
    public var cvPixelFormat: OSType = 0
    
    /// Capture video DLABVideoInputFlag (See DLABConstants.h)
    public var inputFlag: DLABVideoInputFlag = []
    
    /// Video Input Connection
    public var videoConnection: DLABVideoConnection = .init()
    
    /// True while video capture is enabled
    public private(set) var videoCaptureEnabled: Bool {
        get { runtimeStateValue(\.videoCaptureEnabled) }
        set { withRuntimeState { $0.videoCaptureEnabled = newValue } }
    }
    /// Set CaptureVideoPreview view here - based on AVSampleBufferDisplayLayer.
    /// Expected to be read/written on the `@MainActor`.
    public weak var videoPreview: CaptureVideoPreview? = nil
    
    /// Parent NSView for video preview - based on CreateCocoaScreenPreview().
    /// Expected to be read/written on the `@MainActor`.
    public weak var parentView: NSView? = nil {
        didSet {
            let requestedParentView = WeakParentViewBox(view: parentView)
            parentViewUpdateTask?.cancel()
            parentViewUpdateTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self, let device = self.currentDevice else { return }
                do {
                    if let view = requestedParentView.view {
                        try device.setInputScreenPreviewTo(view)
                    } else {
                        try device.setInputScreenPreviewTo(nil)
                    }
                } catch let error as NSError {
                    self.printVerbose("ERROR:\(error.domain)(\(error.code)): \(error.localizedFailureReason ?? "unknown reason")")
                }
            }
        }
    }
    
    /* ============================================ */
    // MARK: - properties - Recording
    /* ============================================ */
    
    /// True while recording
    public private(set) var recording: Bool {
        get { runtimeStateValue(\.recording) }
        set { withRuntimeState { $0.recording = newValue } }
    }
    
    /// Protects recording writer state across callback tasks and state transitions.
    private let appendGateLock = UnfairLockBox()
    private var appendGateOpenStorage: Bool = false
    private var appendGateOpen: Bool {
        get { appendGateLock.withLock { appendGateOpenStorage } }
        set { appendGateLock.withLock { appendGateOpenStorage = newValue } }
    }
    
    /// Writer object for recording
    private var writerStorage: CaptureWriter? = nil
    private var writer: CaptureWriter? {
        get { appendGateLock.withLock { writerStorage } }
        set { appendGateLock.withLock { writerStorage = newValue } }
    }
    
    private func currentAppendWriter() -> CaptureWriter? {
        appendGateLock.withLock {
            guard appendGateOpenStorage else { return nil }
            return writerStorage
        }
    }
    
    /// Keep writer instance alive and pre-warm encoder/writer path between recordings.
    private var writerPrepared: Bool {
        get { runtimeStateValue(\.writerPrepared) }
        set { withRuntimeState { $0.writerPrepared = newValue } }
    }
    
    /// Optional. Set preferred output URL.
    public var movieURL: URL? = nil
    
    /// Optional post-save movie range normalization.
    public var trimsRecordedMovieTimeRangeAfterRecording: Bool = false
    public var recordedMoviePostProcessErrorHandler: (@Sendable (URL, Error) -> Void)? = nil
    public private(set) var lastRecordedMoviePostProcessError: Error? {
        get { runtimeStateValue(\.lastRecordedMoviePostProcessError) }
        set { withRuntimeState { $0.lastRecordedMoviePostProcessError = newValue } }
    }
    
    /// Error from the last `captureStopAsync()` call, if stop failed.
    /// Cleared on successful stop.
    public private(set) var stopError: (any Error)? {
        get { runtimeStateValue(\.stopError) }
        set { withRuntimeState { $0.stopError = newValue } }
    }
    
    /// Last audio preview failure (enqueue/aqPrime/aqStart), if any.
    /// Overwritten on each new failure; not cleared automatically.
    /// Use ``clearAudioPreviewError()`` to reset after handling.
    public private(set) var audioPreviewError: (any Error)? {
        get { runtimeStateValue(\.audioPreviewError) }
        set { withRuntimeState { $0.audioPreviewError = newValue } }
    }
    
    /// Clear the last audio preview error.
    public func clearAudioPreviewError() {
        withRuntimeState { $0.audioPreviewError = nil }
    }
    
    /// Optional callback for non-fatal `CaptureWriter` diagnostics during fallback cleanup.
    public var captureWriterDiagnosticHandler: (@Sendable (CaptureWriterDiagnostic) -> Void)? = nil
    
    /// Optional. Auto-generated movie name prefix.
    public var prefix: String? = "DL-"
    
    /// Optional. Set preferred timeScale for video/timecode. 0 for default value.
    public var sampleTimescale :CMTimeScale = 0
    
    /// Duration in sec of last recording
    private var lastDuration: Float64 {
        get { runtimeStateValue(\.lastDuration) }
        set { withRuntimeState { $0.lastDuration = newValue } }
    }
    
    /// Duration in sec of recording
    public var duration :Float64 {
        get {
            if let writer = currentAppendWriter() {
                return writer.cachedDuration
            } else {
                return lastDuration
            }
        }
    }
    
    /* ============================================ */
    // MARK: - properties - Recording audio
    /* ============================================ */
    
    /// Set YES to encode audio in AAC. No to use LPCM.
    public var encodeAudio :Bool = false
    
    /// Set audioFormatID as kAudioFormatXXXX.
    public var encodeAudioFormatID : AudioFormatID = kAudioFormatMPEG4AAC
    
    /// Set encoded audio target bitrate. Default is 256 * 1000 bps.
    /// Recommends AAC-LC:64k~/ch, HE-AAC:24k~/ch, HE-AACv2: 12k~/ch.
    public var encodeAudioBitrate :UInt = CaptureWriter.defaultEncodeAudioBitrate
    
    /// Optional: customise audio encode settings of AVAssetWriterInput.
    public var updateAudioSettings : (@Sendable ([String:Any]) -> [String:Any])? = nil
    
    /* ============================================ */
    // MARK: - properties - Recording video
    /* ============================================ */
    
    /// Set output videoStyle template (See VideoStyle.swift).
    /// Should be compatible with displayMode value in (width, height).
    /// Will reset offset and encodedSize/visibleSize/aspectRatio.
    public var videoStyle :VideoStyle = .SD_720_486_16_9 {
        didSet {
            offset = NSPoint.zero
            encodedSize = videoStyle.encodedSize()
            visibleSize = videoStyle.visibleSize()
            aspectRatio = videoStyle.aspectRatio()
        }
    }
    
    /// Set preferred clean-aperture offset. 0 stands center(default).
    public var offset = NSPoint.zero
    
    /// ReadOnly encoded size of videoStyle.
    public private(set) var encodedSize = NSSize(width: 720, height: 486)
    
    /// ReadOnly clean-aperture size of videoStyle.
    public private(set) var visibleSize = NSSize(width: 704, height: 480)
    
    /// ReadOnly apect-ratio of videoStyle
    public private(set) var aspectRatio = NSSize(width: 40, height: 33)
    
    /// Set YES to encode video.
    public var encodeVideo :Bool = true
    
    /// Set YES to use ProRes422 for video. No to use specific videoCodec.
    public var encodeProRes422 :Bool = true
    
    /// Set VideoCodec type as kCMVideoCodecType_XXX. Should be compatible w/ videoStyle.
    public var encodeVideoCodecType :CMVideoCodecType? = kCMVideoCodecType_AppleProRes422LT
    
    /// Set encoded video target bitrate. Default is 0 bps = Undefined.
    /// BPP=0.20(30fps) 1920x1080=12Mbps, 1280x720=5.3Mbps, 720x486=2.0Mbps.
    /// BPP=0.20(25fps) 1920x1080=10Mbps, 1280x720=4.4Mbps, 720x576=2.0Mbps.
    public var encodeVideoBitrate :UInt = 0
    
    /// Optional: For interlaced encoding. Set kCMFormatDescriptionFieldDetail_XXX.
    public var fieldDetail :CFString? = kCMFormatDescriptionFieldDetail_SpatialFirstLineLate
    
    /// Optional: customise video encode settings of AVAssetWriterInput.
    public var updateVideoSettings : (@Sendable ([String:Any]) -> [String:Any])? = nil
    
    /* ============================================ */
    // MARK: - properties - Recording timecode (set before capture)
    /* ============================================ */
    
    /// True if input provides timecode data
    public private(set) var timecodeReady: Bool {
        get { runtimeStateValue(\.timecodeReady) }
        set { withRuntimeState { $0.timecodeReady = newValue } }
    }
    
    /// Timecode helper object
    private let timecodeHelperLock = UnfairLockBox()
    private var timecodeHelperStorage: CaptureTimecodeHelper? = nil
    
    private func currentTimecodeHelper() -> CaptureTimecodeHelper? {
        timecodeHelperLock.withLock { timecodeHelperStorage }
    }
    
    private func setTimecodeHelper(_ helper: CaptureTimecodeHelper?) {
        timecodeHelperLock.withLock { timecodeHelperStorage = helper }
    }
    
    private func clearTimecodeHelper() {
        timecodeHelperLock.withLock { timecodeHelperStorage = nil }
    }
    /// Timecode format type. Set before ``captureStartAsync()``.
    public var timecodeFormatType : CMTimeCodeFormatType = kCMTimeCodeFormatType_TimeCode32
    
    /// Validate if source provides timecode of specified type. Set before ``captureStartAsync()``.
    public var timecodeSource :TimecodeType? = nil
    
    /* ============================================ */
    // MARK: - properties - Capturing ancillary data
    /* ============================================ */
    
    /// Input ancillary packet callback. Use `dataSpace` to distinguish VANC and HANC packets.
    /// This is the preferred wrapper API for SDK 15.3+ ancillary packet capture.
    /// Set before or during capture; `didSet` immediately applies to the current device.
    public var inputAncillaryPacketHandler: InputAncillaryPacketHandler? = nil {
        didSet {
            if let device = currentDevice {
                applyInputAncillaryPacketHandler(to: device)
            }
        }
    }
    
    /* ============================================ */
    // MARK: - public init/deinit
    /* ============================================ */
    
    public override init() {
        super.init()
        
        // print("CaptureManager.\(#function)")
        
        // NOTE: idle wakeup uses Task.yield(); a future refinement could
        // use a continuation-based signal instead of a spin-yield loop.
        audioProcessorTask = Task(priority: .high) { [audioQueue] in
            while !Task.isCancelled {
                let batch = audioQueue.takeAll()
                if batch.isEmpty {
                    await Task.yield()
                    continue
                }
                for work in batch {
                    await work()
                }
            }
        }
        
        videoProcessorTask = Task(priority: .high) { [videoQueue] in
            while !Task.isCancelled {
                let batch = videoQueue.takeAll()
                if batch.isEmpty {
                    await Task.yield()
                    continue
                }
                for work in batch {
                    await work()
                }
            }
        }
    }
    
    deinit {
        // print("CaptureManager.\(#function)")
        
        detachedCleanup()
    }
    
    /* ============================================ */
    // MARK: - public method
    /* ============================================ */
    
    /// Start Capture session
    @discardableResult
    public func captureStartAsync() async -> Bool {
        printVerbose("NOTICE: CaptureManager.\(#function) - Start capture session...")
        if currentDevice == nil {
            _ = findFirstDevice()
        }
        
        if let device = currentDevice, running == false {
            if timecodeSource != nil {
                // support for timecode
                timecodeReady = false
                prepTimecodeHelper()
            }
            
            do {
                var vSetting:DLABVideoSetting? = nil
                var aSetting:DLABAudioSetting? = nil
                try vSetting = device.createInputVideoSetting(of: displayMode,
                                                              pixelFormat: pixelFormat,
                                                              inputFlag: inputFlag)
                if audioChannels > 0 {
                    // Currently 2, 8, 16 are valid (See IDeckLinkInput::EnableAudioInput)
                    try aSetting = device.createInputAudioSetting(of: audioDepth,
                                                                  channelCount: audioChannels,
                                                                  sampleRate: audioRate)
                    
                    // HDMI Audio support
                    if let aSetting = aSetting, videoConnection == .HDMI, audioConnection == .embedded,
                       audioChannels == 8, audioChannels >= hdmiAudioChannels, hdmiAudioChannels > 0 {
                        // rebuild formatDescription to support HDMI Audio Channel order
                        try aSetting.buildAudioFormatDescription(forHDMIAudioChannels: hdmiAudioChannels,
                                                                 swap3chAnd4ch: reverseCh3Ch4)
                    }
                }
                
                // NOTE: AVAssetWriter Buggy behavior found...
                // If "passthru write CMPixelBuffer w/ clap", auto generated tapt
                // (track aperture mode dimentions) atom contains error as following:
                //  invalid value in moov:trak:tapt:clef:cleanApertureWidth/height
                //  which is same value in moov:trak:tapt:prof:cleanApertureWidth/height
                // This error does not happen when compression is performed.
                //
                // i.e. 720x486 in 40:33 Aspect with 704x480 clean aperture
                // tapt | Correct      | Incorrect
                // -----+--------------+--------------
                // clef | 853.33x480.0 | 872.72x486.0 << no clean aperture applied rect
                // prof | 872.72x486.0 | 872.72x486.0
                // enof | 720.0 x486.0 | 720.0 x486.0
                //
                // https://developer.apple.com/library/content/documentation/
                //         QuickTime/QTFF/QTFFChap2/qtff2.html#//apple_ref/doc/uid/TP40000939-CH204-SW15
                
                if let vSetting = vSetting {
                    try vSetting.addClapExt(ofWidthN: Int32(visibleSize.width), widthD: 1,
                                            heightN: Int32(visibleSize.height), heightD: 1,
                                            hOffsetN: Int32(offset.x), hOffsetD: 1,
                                            vOffsetN: Int32(offset.y), vOffsetD: 1)
                    try vSetting.addPaspExt(ofHSpacing: UInt32(aspectRatio.width),
                                            vSpacing: UInt32(aspectRatio.height))
                }
                
                if let vSetting = vSetting, cvPixelFormat > 0 {
                    // rebuild formatDescription with new CVPixelFormat
                    vSetting.cvPixelFormatType = cvPixelFormat
                    try vSetting.buildVideoFormatDescription()
                }
                
                videoCaptureEnabled = false
                if let vSetting = vSetting {
                    // Enable Video Preview
                    if let parentView = parentView {
                        Task { @MainActor in
                            try attachInputScreenPreview(to: parentView) // @MainActor
                        }
                    }
                    if let videoPreview = videoPreview {
                        Task { @MainActor in
                            videoPreview.prepare() // @MainActor
                        }
                    }
                    
                    // Enable Video Capture
                    if videoConnection.rawValue > 0 {
                        try device.enableVideoInput(with: vSetting, on: videoConnection)
                    } else {
                        try device.enableVideoInput(with: vSetting)
                    }
                    videoCaptureEnabled = true
                }
                
                audioCaptureEnabled = false
                if let aSetting = aSetting {
                    // Enable Audio Preview
                    if let audioFormatDescription = aSetting.audioFormatDescription {
                        let preview = CaptureAudioPreview(audioFormatDescription)
                        if let preview = preview {
                            preview.volume = Float32(volume)
                        }
                        setAudioPreview(preview)
                    }
                    
                    // Enable Audio Capture
                    if audioConnection.rawValue > 0 {
                        try device.enableAudioInput(with: aSetting, on: audioConnection)
                    } else {
                        try device.enableAudioInput(with: aSetting)
                    }
                    audioCaptureEnabled = true
                }
                
                if (audioCaptureEnabled || videoCaptureEnabled) {
                    // Update inputVideoSetting
                    applyTimecodeSetting()
                    applyInputAncillaryPacketHandler(to: device)
                    
                    // Start stream
                    device.inputDelegate = self
                    try device.startStreams()
                    running = true
                }
                
                if running {
                    printVerbose("CaptureManager.\(#function) - Start capture session completed")
                    return true
                }
            } catch let error as NSError {
                printVerbose("ERROR:\(error.domain)(\(error.code)): \(error.localizedFailureReason ?? "unknown reason")")
            }
        }  else {
            printVerbose("ERROR: device is not ready")
        }
        return false
    }
    
    /// Stop capture session
    @discardableResult
    public func captureStopAsync() async -> Bool {
        if let device = currentDevice, running == true {
            if recording {
                await recordToggleAsync() // actor isolated (writer)
            }
            
            printVerbose("CaptureManager.\(#function) - Stop capture session...")
            
            do {
                // Stop stream
                try device.stopStreams()
                running = false
                device.inputDelegate = nil
                clearInputAncillaryPacketHandler(from: device)
                
                // Disable Capture
                if videoCaptureEnabled {
                    try device.disableVideoInput()
                    videoCaptureEnabled = false
                }
                if audioCaptureEnabled {
                    try device.disableAudioInput()
                    audioCaptureEnabled = false
                }
                
                // Disable Preview
                if let videoPreview = videoPreview {
                    await videoPreview.shutdown() // @MainActor
                }
                if let _ = parentView {
                    try await attachInputScreenPreview(to: nil) // @MainActor
                }
                if let preview = takeAudioPreview() {
                    try preview.aqStop()
                    try preview.aqDispose()
                }
                
                // support for timecode
                timecodeReady = false
                clearTimecodeHelper()
                
                stopError = nil
                printVerbose("CaptureManager.\(#function) - Stop capture session completed")
                return true
            } catch let error as NSError {
                printVerbose("ERROR:CaptureManager.\(#function) - \(error.domain)(\(error.code)): \(error.localizedFailureReason ?? "unknown reason")")
                stopError = error
            }
        } else {
            printVerbose("ERROR:CaptureManager.\(#function) - device is not ready")
            stopError = createError(-2, "Device is not ready", "No device available or already stopped")
        }
        
        return false
    }
    
    /// Toggle recording using current session
    public func recordToggleAsync() async {
        if running {
            if recording {
                printVerbose("CaptureManager.\(#function) - Stop recording...")
                appendGateOpen = false
                
                // stop recording
                if let writer = writer {
                    await writer.closeSession()
                    // keep last duration
                    lastDuration = await writer.duration
                    
                    let writerError = await writer.internalError
                    let outputURL = await writer.resolvedMovieURL()
                    await handleRecordedMoviePostProcess(writerError: writerError, outputURL: outputURL)
                }
                
                writerPrepared = (writer != nil)
                
                if recording {
                    recording = false
                }
                
                printVerbose("CaptureManager.\(#function) - Stop recording completed")
            } else {
                // support for timecode
                prepTimecodeHelper()
                
                // Update inputVideoSetting
                applyTimecodeSetting()
                
                // prepare writer
                if writer == nil {
                    writer = CaptureWriter()
                    writerPrepared = false
                }
                
                // start recording
                if let writer = writer {
                    printVerbose("CaptureManager.\(#function) - Start recording...")
                    
                    let config = makeWriterConfig(movieURL: movieURL, prefix: prefix)
                    
                    // apply CaptureWriterConfig
                    await writer.setConfig(config)
                    appendGateOpen = false
                    await writer.openSession()
                    
                    if await writer.isRecording {
                        appendGateOpen = true
                        recording = true
                        writerPrepared = true
                        // print("NOTICE: Recording started")
                        
                        printVerbose("CaptureManager.\(#function) - Start recording completed")
                    } else {
                        appendGateOpen = false
                        writerPrepared = false
                        printVerbose("ERROR: Failed to start recording")
                    }
                } else {
                    appendGateOpen = false
                    printVerbose("ERROR: Writer is not available")
                }
            }
        } else {
            printVerbose("ERROR: device is not ready")
        }
    }
    
    /// Prepare writer/encoder pipeline ahead of first user recording start.
    /// Safe to call repeatedly; it returns immediately when already prepared or recording.
    @discardableResult
    public func prewarmRecordingPathAsync() async -> Bool {
        guard running, !recording else { return false }
        guard writerPrepared == false else { return true }
        
        if writer == nil {
            writer = CaptureWriter()
        }
        guard let writer = writer else { return false }
        
        prepTimecodeHelper()
        applyTimecodeSetting()
        
        printVerbose("TRACE:CaptureManager.\(#function) - begin")
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recdl-prewarm-\(UUID().uuidString).mov")
        let config = makeWriterConfig(movieURL: tempURL, prefix: nil)
        
        await writer.setConfig(config)
        await writer.openSession()
        
        guard await writer.isRecording else {
            printVerbose("ERROR:CaptureManager.\(#function) - prewarm openSession failed")
            writerPrepared = false
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
        
        await writer.closeSession()
        try? FileManager.default.removeItem(at: tempURL)
        writerPrepared = true
        printVerbose("TRACE:CaptureManager.\(#function) - completed")
        return true
    }
    
    /// Mark prewarmed writer path as stale due to configuration changes.
    public func invalidateRecordingPreparation() {
        appendGateOpen = false
        writerPrepared = false
        if !recording {
            writer = nil
        }
    }
    
    /* ============================================ */
    // MARK: - private method
    /* ============================================ */
    
    /// deinit helper method for cleanup.
    private func detachedCleanup() {
        let isRunning = self.running
        appendGateOpen = false
        running = false
        _ = audioQueue.takeAll()
        _ = videoQueue.takeAll()
        
        audioProcessorTask?.cancel()
        videoProcessorTask?.cancel()
        
        // Copy actor isolated properties to nonisolated variables
        let verbose = self.verbose
        
        let device = self.currentDevice
        let writer = self.writer
        let videoPreview = self.videoPreview
        let parentView = self.parentView
        let audioPreview = takeAudioPreview()
        let isRecording = self.recording
        let isVideoCaptureEnabled = self.videoCaptureEnabled
        let isAudioCaptureEnabled = self.audioCaptureEnabled
        
        // Perform cleanup on a detached task
        Task.detached {
            // Avoid capturing self in the deinit task
            if verbose { print("CaptureManager.\(#function) - Task started") }
            
            if isRecording, let writer = writer {
                await writer.closeSession() // actor isolated (writer)
            }
            if isRunning, let device = device {
                do { try device.stopStreams() }
                catch {
                    if verbose { print("ERROR:CaptureManager.detachedCleanup - stopStreams failed: \(error.localizedDescription)") }
                }
                device.inputDelegate = nil
                device.inputAncillaryPacketHandler = nil
                
                if isVideoCaptureEnabled {
                    do { try device.disableVideoInput() }
                    catch {
                        if verbose { print("ERROR:CaptureManager.detachedCleanup - disableVideoInput failed: \(error.localizedDescription)") }
                    }
                }
                if isAudioCaptureEnabled {
                    do { try device.disableAudioInput() }
                    catch {
                        if verbose { print("ERROR:CaptureManager.detachedCleanup - disableAudioInput failed: \(error.localizedDescription)") }
                    }
                }
                if let videoPreview = videoPreview {
                    await videoPreview.shutdown() // @MainActor
                }
                if parentView != nil {
                    DispatchQueue.main.async { [device] in
                        do { try device.setInputScreenPreviewTo(nil) }
                        catch {
                            if verbose { print("ERROR:CaptureManager.detachedCleanup - setInputScreenPreviewTo failed: \(error.localizedDescription)") }
                        }
                    }
                }
                if let audioPreview = audioPreview {
                    do { try audioPreview.aqStop() }
                    catch {
                        if verbose { print("ERROR:CaptureManager.detachedCleanup - aqStop failed: \(error.localizedDescription)") }
                    }
                    do { try audioPreview.aqDispose() }
                    catch {
                        if verbose { print("ERROR:CaptureManager.detachedCleanup - aqDispose failed: \(error.localizedDescription)") }
                    }
                }
            }
            
            if verbose { print("CaptureManager.\(#function) - Task completed") }
        }
    }
    
    /// Helper method to update parentView for input video screen preview on MainActor.
    ///
    /// - Parameter parentView: The NSView to attach the input screen preview to. If nil, it will detach the preview.
    @MainActor
    private func attachInputScreenPreview(to parentView: NSView?) throws {
        guard let device = currentDevice else {
            throw createError(-1, "Current device is nil", "Device not initialized")
        }
        
        try device.setInputScreenPreviewTo(parentView)
    }
    
    private func applyInputAncillaryPacketHandler(to device: DLABDevice) {
        device.inputAncillaryPacketHandler = inputAncillaryPacketHandler
    }
    
    private func clearInputAncillaryPacketHandler(from device: DLABDevice) {
        device.inputAncillaryPacketHandler = nil
    }
    
    private func calcTimescale() -> CMTimeScale {
        if let timeScale = nativeTimescaleFor(displayMode) {
            return timeScale
        }
        return 60000 // 30.0 * 1000
    }
    
    private func calcFPS() -> Float {
        if let fps = nativeFPSFor(displayMode) {
            return fps
        }
        return 60.0 //
    }
    
    private func makeWriterConfig(movieURL: URL?, prefix: String?) -> CaptureWriter.CaptureWriterConfig {
        var config = CaptureWriter.CaptureWriterConfig()
        
        config.movieURL = movieURL
        config.prefix = prefix
        config.sampleTimescale = (sampleTimescale > 0 ? sampleTimescale : calcTimescale())
        
        config.encodeAudio = encodeAudio
        config.encodeAudioFormatID = encodeAudioFormatID
        config.encodeAudioBitrate = encodeAudioBitrate
        config.updateAudioSettings = updateAudioSettings
        
        config.videoStyle = videoStyle
        config.clapHOffset = Int(offset.x)
        config.clapVOffset = Int(offset.y)
        config.encodeVideo = encodeVideo
        config.encodeVideoBitrate = encodeVideoBitrate
        config.encodeVideoFrameRate = calcFPS()
        config.encodeProRes422 = encodeProRes422
        config.encodeVideoCodecType = encodeVideoCodecType
        config.fieldDetail = fieldDetail as String?
        config.updateVideoSettings = updateVideoSettings
        
        config.useTimecode = timecodeReady
        config.traceStartupTiming = verbose
        config.diagnosticHandler = captureWriterDiagnosticHandler
        config.sourceVideoFormatDescription = currentDevice?.inputVideoSetting?.videoFormatDescription
        config.sourceAudioFormatDescription = currentDevice?.inputAudioSetting?.audioFormatDescription
        
        return config
    }
    
    internal func testingWriterConfig(movieURL: URL?, prefix: String?) -> CaptureWriter.CaptureWriterConfig {
        makeWriterConfig(movieURL: movieURL, prefix: prefix)
    }
    
    internal func testingShouldPostProcessRecordedMovie(writerError: Error?, outputURL: URL?) -> Bool {
        shouldPostProcessRecordedMovie(writerError: writerError, outputURL: outputURL)
    }
    
    internal func testingHandleRecordedMoviePostProcess(writerError: Error?, outputURL: URL?) async {
        await handleRecordedMoviePostProcess(writerError: writerError, outputURL: outputURL)
    }
    
    internal func testingPostProcessRecordedMovieIfNeeded(at movieURL: URL) async {
        await postProcessRecordedMovieIfNeeded(at: movieURL)
    }
    
    private func prepTimecodeHelper() {
        if let timecodeSource = timecodeSource, timecodeSource == .CoreAudio {
            // Replace atomically to avoid racing with concurrent createTimeCodeSample(from:) reads.
            setTimecodeHelper(CaptureTimecodeHelper(formatType: timecodeFormatType))
        }
    }
    
    private func applyTimecodeSetting() {
        if let vSetting = currentDevice?.inputVideoSetting {
            vSetting.useSERIAL = false
            vSetting.useVITC = false
            vSetting.useRP188 = false
            if let timecodeSource = timecodeSource {
                switch timecodeSource {
                case .SERIAL:
                    vSetting.useSERIAL = true
                case .VITC:
                    vSetting.useVITC = true
                case .RP188:
                    vSetting.useRP188 = true
                default:
                    break
                }
            }
        }
    }
    
    internal func printVerbose(_ message: String...) {
        // print("\(#file) \(#line) \(#function)")
        
        if self.verbose {
            let output = message.joined(separator: "\n")
            print(output)
        }
    }
    
    private func shouldPostProcessRecordedMovie(writerError: Error?, outputURL: URL?) -> Bool {
        guard trimsRecordedMovieTimeRangeAfterRecording,
              writerError == nil,
              let outputURL,
              outputURL.isFileURL,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            return false
        }
        
        return true
    }
    
    private func handleRecordedMoviePostProcess(writerError: Error?, outputURL: URL?) async {
        lastRecordedMoviePostProcessError = nil
        
        guard let outputURL,
              shouldPostProcessRecordedMovie(writerError: writerError, outputURL: outputURL) else {
            return
        }
        
        await postProcessRecordedMovieIfNeeded(at: outputURL)
    }
    
    private func postProcessRecordedMovieIfNeeded(at movieURL: URL) async {
        lastRecordedMoviePostProcessError = nil
        
        do {
            _ = try normalizeRecordedMovieTimeRange(at: movieURL)
        } catch {
            lastRecordedMoviePostProcessError = error
            recordedMoviePostProcessErrorHandler?(movieURL, error)
            printVerbose("ERROR:CaptureManager.postProcessRecordedMovieIfNeeded - \(error.localizedDescription)")
        }
    }
    
    /* ============================================ */
    // MARK: - callback
    /* ============================================ */
    
    /// Callback method implementation - DLABInputCaptureDelegate
    /// - Note: Automatic format reconfiguration is not supported.
    ///   Events are logged for diagnostics but no state is changed.
    public nonisolated func processInputFormatChange(
        with videoSetting: DLABVideoSetting?,
        events: DLABVideoInputFormatChangedEvent,
        flags: DLABDetectedVideoInputFormatFlag,
        of sender: DLABDevice
    ) {
        guard sender === currentDevice else { return }
        guard verbose else { return }
        let modeName = videoSetting?.name ?? "nil"
        print(
            "NOTICE: CaptureManager.processInputFormatChange - displayMode=\(modeName) events=0x\(String(events.rawValue, radix: 16)) flags=0x\(String(flags.rawValue, radix: 16))"
        )
    }
    
    /// Callback method implementation - DLABInputCaptureDelegate
    /// - Parameters:
    ///   - sampleBuffer: CMSampleBuffer
    ///   - sender: DLABDevice
    public nonisolated func processCapturedAudioSample(_ sampleBuffer: CMSampleBuffer,
                                                       of sender:DLABDevice) {
        guard sender === currentDevice, running else { return }
        let info = UnsafeSampleBufferInfo(sampleBuffer: sampleBuffer, setting: nil)
        let enqueued = audioQueue.enqueue { [weak self] in
            await self?.processCapturedAudioSampleAsync(info)
        }
        if !enqueued {
            // Audio queue full — drop sample under backpressure.
            // Also implicitly dropped during teardown when self is nil.
        }
    }
    
    /// Callback method implementation - DLABInputCaptureDelegate
    /// - Parameters:
    ///   - sampleBuffer: CMSampleBuffer
    ///   - sender: DLABDevice
    public nonisolated func processCapturedVideoSample(_ sampleBuffer: CMSampleBuffer,
                                                       of sender:DLABDevice) {
        guard sender === currentDevice, running else { return }
        let info = UnsafeSampleBufferInfo(sampleBuffer: sampleBuffer, setting: nil)
        let enqueued = videoQueue.enqueue { [weak self] in
            await self?.processCapturedVideoSampleAsync(info)
        }
        if !enqueued {
            // Video queue full — drop sample under backpressure.
            // Also implicitly dropped during teardown when self is nil.
        }
    }
    
    /// Callback method implementation - DLABInputCaptureDelegate
    /// - Parameters:
    ///   - sampleBuffer: CMSampleBuffer
    ///   - setting: DLABTimecodeSetting
    ///   - sender: DLABDevice
    public nonisolated func processCapturedVideoSample(_ sampleBuffer: CMSampleBuffer,
                                                       timecodeSetting setting: DLABTimecodeSetting,
                                                       of sender:DLABDevice) {
        guard sender === currentDevice, running else { return }
        let info = UnsafeSampleBufferInfo(sampleBuffer: sampleBuffer, setting: setting)
        let enqueued = videoQueue.enqueue { [weak self] in
            await self?.processCapturedVideoSampleAsync(info)
        }
        if !enqueued {
            // Video queue full — drop sample under backpressure.
            // Also implicitly dropped during teardown when self is nil.
        }
    }
    
    /// Audio SampleBuffer callback - Enqueue immediately
    /// - Parameter info: A wrapper for sampleBuffer and optional timecode setting
    private func processCapturedAudioSampleAsync(_ info: UnsafeSampleBufferInfo) async {
        guard running else { return }
        let sampleBuffer = info.sampleBuffer
        
        if let writer = currentAppendWriter() {
            let wrapper = UnsafeSampleBufferWrapper(sampleBuffer: sampleBuffer)
            do {
                try await writer.appendSampleBuffer(wrapper: wrapper, mediaType: .audio)
            } catch {
                printVerbose("ERROR:CaptureManager.\(#function) - audio append failed: \(error.localizedDescription)")
            }
        }
        if let preview = currentAudioPreview() {
            if preview.running == true {
                do { try preview.enqueue(sampleBuffer) }
                catch {
                    audioPreviewError = error
                    printVerbose("ERROR:CaptureManager.\(#function) - audio preview enqueue failed: \(error.localizedDescription)")
                }
            } else {
                do { try preview.enqueue(sampleBuffer) }
                catch {
                    audioPreviewError = error
                    printVerbose("ERROR:CaptureManager.\(#function) - audio preview enqueue failed: \(error.localizedDescription)")
                    return
                }
                do { try preview.aqPrime() }
                catch {
                    audioPreviewError = error
                    printVerbose("ERROR:CaptureManager.\(#function) - audio preview aqPrime failed: \(error.localizedDescription)")
                    return
                }
                do { try preview.aqStart() }
                catch {
                    audioPreviewError = error
                    printVerbose("ERROR:CaptureManager.\(#function) - audio preview aqStart failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Video SampleBuffer callback - Enqueue immediately Or using DisplayLink
    /// - Parameter info: Video SampleBuffer wrapper
    private func processCapturedVideoSampleAsync(_ info: UnsafeSampleBufferInfo) async {
        guard running else { return }
        let sampleBuffer = info.sampleBuffer
        let setting = info.setting
        
        if let writer = currentAppendWriter() {
            let wrapper = UnsafeSampleBufferWrapper(sampleBuffer: sampleBuffer)
            do {
                try await writer.appendSampleBuffer(wrapper: wrapper, mediaType: .video)
            } catch {
                printVerbose("ERROR:CaptureManager.\(#function) - video append failed: \(error.localizedDescription)")
            }
        }
        
        if let videoPreview = videoPreview {
            let wrapper = UnsafeSampleBufferWrapper(sampleBuffer: sampleBuffer)
            do {
                await videoPreview.queueSampleBufferAsync(wrapper: wrapper)
            }
        }
        
        if let setting = setting {
            // support for Device timecode
            if let timecodeSource = timecodeSource, timecodeSource.byDevice() {
                let timecodeSampleBuffer = setting.createTimecodeSample(in: timecodeFormatType,
                                                                        videoSample: sampleBuffer)
                if let timecodeSampleBuffer = timecodeSampleBuffer {
                    if let writer = currentAppendWriter() {
                        let wrapper = UnsafeSampleBufferWrapper(sampleBuffer: timecodeSampleBuffer)
                        do {
                            try await writer.appendSampleBuffer(wrapper: wrapper, mediaType: .timecode)
                        } catch {
                            printVerbose("ERROR:CaptureManager.\(#function) - device timecode append failed: \(error.localizedDescription)")
                        }
                    }
                    
                    // source provides timecode
                    if timecodeReady == false {
                        timecodeReady = true
                        printVerbose("NOTICE: timecodeReady : \(timecodeSource)")
                    }
                }
            }
        } else {
            // support for core_audio_smpte_time
            if let timecodeSource = timecodeSource, timecodeSource == .CoreAudio, let helper = currentTimecodeHelper() {
                let timecodeSampleBuffer = helper.createTimeCodeSample(from: sampleBuffer)
                if let timecodeSampleBuffer = timecodeSampleBuffer {
                    if let writer = currentAppendWriter() {
                        let wrapper = UnsafeSampleBufferWrapper(sampleBuffer: timecodeSampleBuffer)
                        do {
                            try await writer.appendSampleBuffer(wrapper: wrapper, mediaType: .timecode)
                        } catch {
                            printVerbose("ERROR:CaptureManager.\(#function) - core audio timecode append failed: \(error.localizedDescription)")
                        }
                    }
                    
                    // source provides timecode
                    if timecodeReady == false {
                        timecodeReady = true
                        printVerbose("NOTICE: timecodeReady : core_audio_smpte_time")
                    }
                }
            }
        }
    }
}
