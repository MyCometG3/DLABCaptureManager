//
//  CaptureManager.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2017/10/09.
//  Copyright © 2017-2024 MyCometG3. All rights reserved.
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
    var sender: DLABDevice
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

/// Extension to make CaptureManager conform to Sendable for cross-actor usage.
/// Note: This is marked as @unchecked because CaptureManager contains non-Sendable
/// properties, but the class is designed to be used safely across actor boundaries
/// through careful state management and synchronization.
extension CaptureManager: @unchecked Sendable {
    /// Executes an asynchronous, throwing operation synchronously using a detached task.
    /// - Parameter block: A closure that performs asynchronous work and may throw.
    /// - Returns: The result produced by the closure.
    /// - Note: This method blocks the calling thread until the asynchronous work completes.
    ///         It can be used from the main thread only if the operation does not rely on main-thread execution.
    nonisolated func performAsync<T: Sendable>(_ block: @Sendable @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = DispatchQueue(label: "ResultLock")
        var result: Result<T, Error>?
        Task.detached(priority: .high) {
            let taskResult: Result<T, Error>
            do {
                taskResult = .success(try await block())
            } catch {
                taskResult = .failure(error)
            }
            lock.sync {
                result = taskResult
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try lock.sync { try result!.get() }
    }
    
    /// Executes an asynchronous, non-throwing operation synchronously using a detached task.
    /// - Parameter block: A closure that performs asynchronous work.
    /// - Returns: The result produced by the closure.
    /// - Note: This method blocks the calling thread until the asynchronous work completes.
    ///         It can be used from the main thread only if the operation does not rely on main-thread execution.
    nonisolated func performAsync<T: Sendable>(_ block: @Sendable @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = DispatchQueue(label: "ResultLock")
        var result: T?
        Task.detached(priority: .high) {
            let taskResult = await block()
            lock.sync {
                result = taskResult
            }
            semaphore.signal()
        }
        semaphore.wait()
        return lock.sync { result! }
    }
}

public class CaptureManager: NSObject, DLABInputCaptureDelegate {
    /// Verbose mode (debugging purpose)
    public var verbose: Bool = false
    
    /* ============================================ */
    // MARK: - properties - Capturing
    /* ============================================ */
    
    /// True while capture is running
    public private(set) var running: Bool = false
    
    /// Capture device as DLABDevice object
    public var currentDevice :DLABDevice? = nil
    
    /* ============================================ */
    // MARK: - properties - Capturing audio
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
            
            if let audioPreview = audioPreview {
                audioPreview.volume = Float32(volume)
            }
        }
    }
    
    /// Use HDMI audio channel order (L R C LFE Ls Rs Rls Rrs), instead of descrete. audioChannels should be 8.
    public var hdmiAudioChannels: UInt32 = 0
    
    /// For HDMI audio channel order. Set true if (ch3,ch4) == (LFE, C), as reveresed order.
    public var reverseCh3Ch4: Bool = false
    
    /// True while audio capture is enabled
    public private(set) var audioCaptureEnabled: Bool = false
    
    /// AudioPreview object
    private var audioPreview: CaptureAudioPreview? = nil
    
    /* ============================================ */
    // MARK: - properties - Capturing video
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
    public private(set) var videoCaptureEnabled: Bool = false
    
    /// Set CaptureVideoPreview view here - based on AVSampleBufferDisplayLayer
    public weak var videoPreview: CaptureVideoPreview? = nil
    
    /// Parent NSView for video preview - based on CreateCocoaScreenPreview()
    public weak var parentView: NSView? = nil {
        didSet {
            Task { @MainActor in
                guard let device = currentDevice else { return }
                do {
                    if let parentView = parentView {
                        try device.setInputScreenPreviewTo(parentView)
                    } else {
                        try device.setInputScreenPreviewTo(nil)
                    }
                } catch let error as NSError {
                    printVerbose("ERROR:\(error.domain)(\(error.code)): \(error.localizedFailureReason ?? "unknown reason")")
                }
            }
        }
    }
    
    /* ============================================ */
    // MARK: - properties - Recording
    /* ============================================ */
    
    /// True while recording
    public private(set) var recording: Bool = false
    
    /// Writer object for recording
    private var writer: CaptureWriter? = nil
    
    /// Optional. Set preferred output URL.
    public var movieURL: URL? = nil
    
    /// Optional. Auto-generated movie name prefix.
    public var prefix: String? = "DL-"
    
    /// Optional. Set preferred timeScale for video/timecode. 0 for default value.
    public var sampleTimescale :CMTimeScale = 0
    
    /// Duration in sec of last recording
    private var lastDuration :Float64 = 0.0
    
    /// Duration in sec of recording
    public var duration :Float64 {
        get {
            if let writer = writer {
                return performAsync {
                    await writer.duration
                }
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
    public var encodeAudioBitrate :UInt = 256_000
    
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
    // MARK: - properties - Recording timecode
    /* ============================================ */
    
    /// True if input provides timecode data
    public private(set) var timecodeReady :Bool = false
    
    /// Timecode helper object
    private var timecodeHelper :CaptureTimecodeHelper? = nil
    
    /// Timecode format type (timecode
    public var timecodeFormatType : CMTimeCodeFormatType = kCMTimeCodeFormatType_TimeCode32
    
    /// Validate if source provides timecode of specified type. Set before captureStart().
    public var timecodeSource :TimecodeType? = nil
    
    /* ============================================ */
    // MARK: - public init/deinit
    /* ============================================ */
    
    public override init() {
        super.init()
        
        // print("CaptureManager.\(#function)")
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
                        audioPreview = CaptureAudioPreview(audioFormatDescription)
                        if let audioPreview = audioPreview {
                            audioPreview.volume = Float32(volume)
                        }
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
                running = false
                try device.stopStreams()
                device.inputDelegate = nil
                
                // Disable Capture
                if videoCaptureEnabled {
                    videoCaptureEnabled = false
                    try device.disableVideoInput()
                }
                if audioCaptureEnabled {
                    audioCaptureEnabled = false
                    try device.disableAudioInput()
                }
                
                // Disable Preview
                if let videoPreview = videoPreview {
                    await videoPreview.shutdown() // @MainActor
                }
                if let _ = parentView {
                    try await attachInputScreenPreview(to: nil) // @MainActor
                }
                if let audioPreview = audioPreview {
                    try audioPreview.aqStop()
                    try audioPreview.aqDispose()
                    self.audioPreview = nil
                }
            } catch let error as NSError {
                printVerbose("ERROR:CaptureManager.\(#function) - \(error.domain)(\(error.code)): \(error.localizedFailureReason ?? "unknown reason")")
            }
            
            do {
                // support for timecode
                timecodeReady = false
                timecodeHelper = nil
            }
            
            if !running {
                printVerbose("CaptureManager.\(#function) - Stop capture session completed")
                return true
            }
        } else {
            printVerbose("ERROR:CaptureManager.\(#function) - device is not ready")
        }
        
        return false
    }
    
    /// Toggle recording using current session
    public func recordToggleAsync() async {
        if running {
            if let writer = writer {
                printVerbose("CaptureManager.\(#function) - Stop recording...")
                
                // stop recording
                await writer.closeSession()
                
                // keep last duration
                lastDuration = await writer.duration
                
                // unref writer
                self.writer = nil
                
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
                writer = CaptureWriter()
                
                // start recording
                if let writer = writer {
                    printVerbose("CaptureManager.\(#function) - Start recording...")
                    
                    // prepare CaptureWriterConfig
                    var config = await writer.getConfig()
                    
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
                    
                    config.sourceVideoFormatDescription = currentDevice?.inputVideoSetting?.videoFormatDescription
                    config.sourceAudioFormatDescription = currentDevice?.inputAudioSetting?.audioFormatDescription
                    
                    // apply CaptureWriterConfig
                    await writer.setConfig(config)
                    await writer.openSession()
                    
                    if await writer.isRecording {
                        recording = true
                        // print("NOTICE: Recording started")
                        
                        printVerbose("CaptureManager.\(#function) - Start recording completed")
                    } else {
                        printVerbose("ERROR: Failed to start recording")
                    }
                } else {
                    printVerbose("ERROR: Writer is not available")
                }
            }
        } else {
            printVerbose("ERROR: device is not ready")
        }
    }
    
    /* ============================================ */
    // MARK: - private method
    /* ============================================ */
    
    /// deinit helper method for cleanup.
    private func detachedCleanup() {
        // Copy actor isolated properties to nonisolated variables
        let verbose = self.verbose
        
        let device = self.currentDevice
        let writer = self.writer
        let videoPreview = self.videoPreview
        let parentView = self.parentView
        let audioPreview = self.audioPreview
        
        let isRunning = self.running
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
                try? device.stopStreams()
                device.inputDelegate = nil
                
                if isVideoCaptureEnabled {
                    try? device.disableVideoInput()
                }
                if isAudioCaptureEnabled {
                    try? device.disableAudioInput()
                }
                if let videoPreview = videoPreview {
                    await videoPreview.shutdown() // @MainActor
                }
                if parentView != nil {
                    DispatchQueue.main.async {
                        try? device.setInputScreenPreviewTo(nil) // DLABDevice/captureQueue
                    }
                }
                if let audioPreview = audioPreview {
                    try? audioPreview.aqStop()
                    try? audioPreview.aqDispose()
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
    
    private func createError(_ status :OSStatus, _ description :String?, _ failureReason :String?) -> NSError {
        let domain = "com.MyCometG3.DLABCaptureManager.ErrorDomain"
        let code = NSInteger(status)
        let desc = description ?? "unknown description"
        let reason = failureReason ?? "unknown failureReason"
        let userInfo :[String:Any] = [NSLocalizedDescriptionKey:desc,
                                      NSLocalizedFailureReasonErrorKey:reason]
        return NSError(domain: domain, code: code, userInfo: userInfo)
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
    
    private func prepTimecodeHelper() {
        if let timecodeSource = timecodeSource, timecodeSource == .CoreAudio {
            if let timecodeHelper = timecodeHelper {
                timecodeHelper.timeCodeFormatType = timecodeFormatType
            } else {
                timecodeHelper = CaptureTimecodeHelper(formatType: timecodeFormatType)
            }
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
    
    /* ============================================ */
    // MARK: - callback
    /* ============================================ */
    
    /// Callback method implementation - DLABInputCaptureDelegate
    /// - Parameters:
    ///   - sampleBuffer: CMSampleBuffer
    ///   - sender: DLABDevice
    public nonisolated func processCapturedAudioSample(_ sampleBuffer: CMSampleBuffer,
                                                       of sender:DLABDevice) {
        let info = UnsafeSampleBufferInfo(sampleBuffer: sampleBuffer, setting: nil, sender: sender)
        Task(priority: .high) {
            await processCapturedAudioSampleAsync(info)
        }
    }
    
    /// Callback method implementation - DLABInputCaptureDelegate
    /// - Parameters:
    ///   - sampleBuffer: CMSampleBuffer
    ///   - sender: DLABDevice
    public nonisolated func processCapturedVideoSample(_ sampleBuffer: CMSampleBuffer,
                                                       of sender:DLABDevice) {
        let info = UnsafeSampleBufferInfo(sampleBuffer: sampleBuffer, setting: nil, sender: sender)
        Task(priority: .high) {
            await processCapturedVideoSampleAsync(info)
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
        let info = UnsafeSampleBufferInfo(sampleBuffer: sampleBuffer, setting: setting, sender: sender)
        Task(priority: .high) {
            await processCapturedVideoSampleAsync(info)
        }
    }
    
    /// Audio SampleBuffer callback - Enqueue immediately
    /// - Parameter info: A wrapper for sampleBuffer and sender
    private func processCapturedAudioSampleAsync(_ info: UnsafeSampleBufferInfo) async {
        let sampleBuffer = info.sampleBuffer
        
        if let writer = writer {
            let wrapper = UnsafeSampleBufferWrapper(sampleBuffer: sampleBuffer)
            do {
                try? await writer.appendSampleBuffer(wrapper: wrapper, mediaType: .audio)
            }
        }
        if let audioPreview = audioPreview {
            if audioPreview.running == true {
                try? audioPreview.enqueue(sampleBuffer)
            } else {
                try? audioPreview.enqueue(sampleBuffer)
                try? audioPreview.aqPrime()
                try? audioPreview.aqStart()
            }
        }
    }
    
    /// Video SampleBuffer callback - Enqueue immediately Or using DisplayLink
    /// - Parameter info: Video SampleBuffer wrapper
    private func processCapturedVideoSampleAsync(_ info: UnsafeSampleBufferInfo) async {
        let sampleBuffer = info.sampleBuffer
        let setting = info.setting
        
        if let writer = writer {
            let wrapper = UnsafeSampleBufferWrapper(sampleBuffer: sampleBuffer)
            do {
                try? await writer.appendSampleBuffer(wrapper: wrapper, mediaType: .video)
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
                    if let writer = writer {
                        let wrapper = UnsafeSampleBufferWrapper(sampleBuffer: timecodeSampleBuffer)
                        do {
                            try? await writer.appendSampleBuffer(wrapper: wrapper, mediaType: .timecode)
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
            if let timecodeSource = timecodeSource, timecodeSource == .CoreAudio, let timecodeHelper = timecodeHelper {
                let timecodeSampleBuffer = timecodeHelper.createTimeCodeSample(from: sampleBuffer)
                if let timecodeSampleBuffer = timecodeSampleBuffer {
                    if let writer = writer {
                        let wrapper = UnsafeSampleBufferWrapper(sampleBuffer: timecodeSampleBuffer)
                        do {
                            try? await writer.appendSampleBuffer(wrapper: wrapper, mediaType: .timecode)
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
