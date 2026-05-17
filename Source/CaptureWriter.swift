//
//  CaptureWriter.swift
//  DLABCapture
//
//  Created by Takashi Mochizuki on 2017/09/16.
//  Copyright © 2017-2026 MyCometG3. All rights reserved.
//

import Foundation
import AVFoundation
import VideoToolbox
import os.lock

final class UnfairLockBox: @unchecked Sendable {
    private var rawLock = os_unfair_lock_s()
    
    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&rawLock)
        defer { os_unfair_lock_unlock(&rawLock) }
        return try body()
    }
}

enum CaptureWriterError: Swift.Error, LocalizedError {
    case unsupportedMediaType(String)
    case assetWriterIsNotAvailable(String)
    case finishWritingTimedOut(String)
    case invalidAudioOutputSettings
    case invalidVideoOutputSettings
    case invalidTimecodeOutputSettings
    case audioSampleBufferAppendFailed(String)
    case videoSampleBufferAppendFailed(String)
    case timecodeSampleBufferAppendFailed(String)
    case unexpectedErrorWhileOpeningSession(String)
    case unexpectedErrorWhileClosingSession(String)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedMediaType(let reason):
            return "Unsupported media type: \(reason)."
        case .assetWriterIsNotAvailable(let reason):
            return "Invalid AVAssetWriter: \(reason)."
        case .finishWritingTimedOut(let reason):
            return "Timed out while finalizing movie file: \(reason)."
        case .invalidAudioOutputSettings:
            return "Invalid audio output settings provided."
        case .invalidVideoOutputSettings:
            return "Invalid video output settings provided."
        case .invalidTimecodeOutputSettings:
            return "Invalid timecode output settings provided."
        case .audioSampleBufferAppendFailed(let reason):
            return "Failed to append audio sample buffer: \(reason)."
        case .videoSampleBufferAppendFailed(let reason):
            return "Failed to append video sample buffer: \(reason)."
        case .timecodeSampleBufferAppendFailed(let reason):
            return "Failed to append timecode sample buffer: \(reason)."
        case .unexpectedErrorWhileOpeningSession(let reason):
            return "Unexpected error while opening session: \(reason)."
        case .unexpectedErrorWhileClosingSession(let reason):
            return "Unexpected error while closing session: \(reason)."
        }
    }
}

public enum CaptureWriterDiagnostic: Sendable, Equatable {
    case deinitWhileRecording
    case finishWritingTimedOut(timeoutSeconds: Double)
}

/// Thread safe backing store - works with deinit and nonisolated func.
fileprivate final class CaptureWriterCache: @unchecked Sendable {
    private final class RetainedAssetWriterBox: @unchecked Sendable {
        let writer: AVAssetWriter
        init(writer: AVAssetWriter) {
            self.writer = writer
        }
    }
    
    private let lock = UnfairLockBox()
    private func withLock<T>(_ block: () -> T) -> T {
        lock.withLock(block)
    }
    
    private var isRecordingValue: Bool = false
    var isRecording: Bool {
        get { withLock { isRecordingValue } }
        set { withLock { isRecordingValue = newValue } }
    }
    
    private var durationValue: Float64 = 0.0
    var duration: Float64 {
        get { withLock { durationValue } }
        set { withLock { durationValue = newValue } }
    }
    
    private var avAssetWriterValue: AVAssetWriter? = nil
    var assetWriter: AVAssetWriter? {
        get { withLock { avAssetWriterValue } }
        set { withLock { avAssetWriterValue = newValue } }
    }
    private var avAssetWriterInputVideoValue: AVAssetWriterInput? = nil
    var assetWriterInputVideo: AVAssetWriterInput? {
        get { withLock { avAssetWriterInputVideoValue } }
        set { withLock { avAssetWriterInputVideoValue = newValue } }
    }
    private var avAssetWriterInputAudioValue: AVAssetWriterInput? = nil
    var assetWriterInputAudio: AVAssetWriterInput? {
        get { withLock { avAssetWriterInputAudioValue } }
        set { withLock { avAssetWriterInputAudioValue = newValue } }
    }
    private var avAssetWriterInputTimecodeValue: AVAssetWriterInput? = nil
    var assetWriterInputTimecode: AVAssetWriterInput? {
        get { withLock { avAssetWriterInputTimecodeValue } }
        set { withLock { avAssetWriterInputTimecodeValue = newValue } }
    }
    
    private var diagnosticHandlerValue: (@Sendable (CaptureWriterDiagnostic) -> Void)? = nil
    var diagnosticHandler: (@Sendable (CaptureWriterDiagnostic) -> Void)? {
        get { withLock { diagnosticHandlerValue } }
        set { withLock { diagnosticHandlerValue = newValue } }
    }
    
    private var finishWritingTimeoutSecondsValue: TimeInterval = CaptureWriter.defaultFinishWritingTimeoutSeconds
    var finishWritingTimeoutSeconds: TimeInterval {
        get { withLock { finishWritingTimeoutSecondsValue } }
        set { withLock { finishWritingTimeoutSecondsValue = newValue } }
    }
    
    private var retainedAssetWritersValue: [ObjectIdentifier: RetainedAssetWriterBox] = [:]
    func retainAssetWriter(_ writer: AVAssetWriter) {
        withLock { () -> Void in
            retainedAssetWritersValue[ObjectIdentifier(writer)] = RetainedAssetWriterBox(writer: writer)
        }
    }
    func releaseAssetWriter(forKey key: ObjectIdentifier) {
        withLock { () -> Void in
            retainedAssetWritersValue.removeValue(forKey: key)
        }
    }
    func cancelWriting(forKey key: ObjectIdentifier) {
        let writer = withLock {
            retainedAssetWritersValue[key]?.writer
        }
        writer?.cancelWriting()
    }
}

private final class FinishWritingResumeState: @unchecked Sendable {
    let lock = UnfairLockBox()
    var resumed = false
}

private final class DispatchWorkItemBox: @unchecked Sendable {
    let workItem: DispatchWorkItem
    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }
}

/// Movie writer used by `CaptureManager` and other callers that need explicit
/// start/stop control over `AVAssetWriter`.
///
/// Callers should await `closeSession()` before releasing the writer.
/// Cleanup performed from `deinit` is a fallback path only, and it waits for
/// `finishWriting` for a bounded amount of time before giving up.
actor CaptureWriter {
    typealias AssetWriterFactory = @Sendable (URL, AVFileType) throws -> AVAssetWriter
    public typealias DiagnosticHandler = @Sendable (CaptureWriterDiagnostic) -> Void
    public static let defaultFinishWritingTimeoutSeconds: TimeInterval = 5.0
    private static let minimumFinishWritingTimeoutSeconds: TimeInterval = 0.001
    public static let defaultEncodeAudioBitrate: UInt = 256 * 1000
    
    private static let defaultAssetWriterFactory: AssetWriterFactory = { url, fileType in
        try AVAssetWriter(outputURL: url, fileType: fileType)
    }
    
    /* ============================================ */
    // MARK: - readonly property
    /* ============================================ */
    
    /// True while recoding is running.
    public private(set) var isRecording : Bool = false {
        didSet {
            cache.isRecording = isRecording
        }
    }
    /// Recording duration in sec.
    public private(set) var duration : Float64 = 0.0 {
        didSet {
            cache.duration = duration
        }
    }
    /// CMTime for start time.
    public private(set) var startTime : CMTime = CMTime.zero
    /// CMTime for end time.
    public private(set) var endTime : CMTime = CMTime.zero
    /// Flag if starting CMTime is valid or not
    public private(set) var isInitialTSReady : Bool = false
    /// Internal error if any error occurs.
    public private(set) var internalError: Error? = nil
    
    /* ============================================ */
    // MARK: - prepare specified media track
    /* ============================================ */
    
    /// Record audio media.
    public var useAudio : Bool = true
    /// Record video media.
    public var useVideo : Bool = true
    /// Record timecode media.
    public var useTimecode : Bool = false
    
    /* ============================================ */
    // MARK: - Optional parameter
    /* ============================================ */
    
    /// Optional. Set preferred output URL.
    public var movieURL : URL? = nil
    /// Optional. Auto-generated movide name prefix.
    public var prefix : String? = nil
    /// Optional. Set source video formatDescription for hint.
    public var sourceVideoFormatDescription : CMFormatDescription? = nil
    /// Optional. Set source audio formatDescription for hint.
    public var sourceAudioFormatDescription : CMFormatDescription? = nil
    /// Optional. Set preferred timeScale for video/timecode. 0 for default value.
    public var sampleTimescale : CMTimeScale = 0
    /// Optional: For interlaced encoding. Set kCMFormatDescriptionFieldDetail_XXX.
    public var fieldDetail : CFString? = nil
    /// Optional: customise video encode settings of AVAssetWriterInput.
    public var updateVideoSettings : (@Sendable ([String:Any]) -> [String:Any])? = nil
    /// Optional: customise audio encode settings of AVAssetWriterInput.
    public var updateAudioSettings : (@Sendable ([String:Any]) -> [String:Any])? = nil
    
    /* ============================================ */
    // MARK: - output encoding setting
    /* ============================================ */
    
    /// Set YES to encode audio.
    public var encodeAudio : Bool = false
    /// Set AudioCodec ID as kAudioFormatXXX.
    public var encodeAudioFormatID : AudioFormatID = kAudioFormatMPEG4AAC
    /// Set Audio target bitrate. default is 256 * 1000 bps.
    public var encodeAudioBitrate : UInt = CaptureWriter.defaultEncodeAudioBitrate
    /// Set YES to encode video.
    public var encodeVideo : Bool = true
    /// Set YES to use ProRes422 for video. No to use other codec like Apple H.264.
    public var encodeProRes422 : Bool = true
    /// Set VideoCodec type as kCMVideoCodecType_XXX. Should be compatible w/ videoStyle.
    public var encodeVideoCodecType : CMVideoCodecType? = kCMVideoCodecType_H264
    /// Set Video target bitrate. default is 0 bps = Undefined.
    public var encodeVideoBitrate : UInt = 0
    /// Set Video source frame rate per second.
    public var encodeVideoFrameRate : Float = 30/1.001
    /// Set output videoStyle template.
    public var videoStyle : VideoStyle = .SD_720_486_16_9
    /// Set preferred clean-aperture horizontal offset. 0 stands center(default).
    public var clapHOffset : Int = 0
    /// Set preferred clean-aperture vertical offset. 0 stands center(default).
    public var clapVOffset : Int = 0
    /// Enable startup phase timing logs for diagnostics.
    public var traceStartupTiming: Bool = false
    /// Optional callback for non-fatal diagnostics that can occur during fallback cleanup.
    public var diagnosticHandler: DiagnosticHandler? = nil {
        didSet {
            cache.diagnosticHandler = diagnosticHandler
        }
    }
    /// Bounded wait used by `finishWriting` before giving up in normal close and fallback `deinit` cleanup paths.
    private var finishWritingTimeoutSecondsStorage: TimeInterval = CaptureWriter.defaultFinishWritingTimeoutSeconds
    public var finishWritingTimeoutSeconds: TimeInterval {
        get {
            finishWritingTimeoutSecondsStorage
        }
        set {
            let sanitizedValue = newValue.isFinite ? newValue : CaptureWriter.defaultFinishWritingTimeoutSeconds
            let clampedValue = max(CaptureWriter.minimumFinishWritingTimeoutSeconds, sanitizedValue)
            finishWritingTimeoutSecondsStorage = clampedValue
            cache.finishWritingTimeoutSeconds = clampedValue
        }
    }
    
    /* ============================================ */
    // MARK: - private variable
    /* ============================================ */
    
    /// Backend AVAssetWriter for QuickTime movie file
    private var avAssetWriter : AVAssetWriter? = nil {
        didSet {
            cache.assetWriter = avAssetWriter
        }
    }
    /// Backend AVAssetWriterInput for video media
    private var avAssetWriterInputVideo : AVAssetWriterInput? = nil {
        didSet {
            cache.assetWriterInputVideo = avAssetWriterInputVideo
        }
    }
    /// Backend AVAssetWriterInput for audio media
    private var avAssetWriterInputAudio : AVAssetWriterInput? = nil {
        didSet {
            cache.assetWriterInputAudio = avAssetWriterInputAudio
        }
    }
    /// Backend AVAssetWriterInput for timecode media
    private var avAssetWriterInputTimecode : AVAssetWriterInput? = nil {
        didSet {
            cache.assetWriterInputTimecode = avAssetWriterInputTimecode
        }
    }
    
    /// The determined output type for audio channel layout, used for remapping.
    private var audioChannelLayoutOutputType: AudioChannelLayoutOutputType = .descriptions8Ch
    /// Timestamp used to measure first append latency from openSession start.
    private var openSessionStartedAt: CFAbsoluteTime = 0
    /// Guard to emit first video append timing only once per recording session.
    private var loggedFirstVideoAppend: Bool = false
    private var assetWriterFactory: AssetWriterFactory = CaptureWriter.defaultAssetWriterFactory
    
    /// CaptureWriter cache w/ nonisolated func support
    nonisolated private let cache = CaptureWriterCache()
    
    /// Nonisolated, lock-protected snapshot of recording duration.
    nonisolated var cachedDuration: Float64 {
        cache.duration
    }
    
    /* ============================================ */
    // MARK: - public init/deinit
    /* ============================================ */
    
    init() {
        cache.finishWritingTimeoutSeconds = finishWritingTimeoutSecondsStorage
        
        // print("Writer.init")
    }
    
    internal func testingSetAssetWriterFactory(_ factory: AssetWriterFactory?) {
        assetWriterFactory = factory ?? CaptureWriter.defaultAssetWriterFactory
    }
    
    internal func testingSetDiagnosticHandler(_ handler: DiagnosticHandler?) {
        diagnosticHandler = handler
    }
    
    nonisolated internal func testingEmitDeinitDiagnostics(didTimeout: Bool = false) {
        cache.diagnosticHandler?(.deinitWhileRecording)
        if didTimeout {
            let timeoutSeconds = cache.finishWritingTimeoutSeconds
            cache.diagnosticHandler?(.finishWritingTimedOut(timeoutSeconds: timeoutSeconds))
        }
    }
    
    nonisolated internal func testingInvokeDeinitTimeoutPath() {
        let timeoutSeconds = cache.finishWritingTimeoutSeconds
        cache.diagnosticHandler?(.deinitWhileRecording)
        cache.diagnosticHandler?(.finishWritingTimedOut(timeoutSeconds: timeoutSeconds))
    }
    
    deinit {
        // print("Writer.deinit")
        
        deinitHelper()
    }
    
    /// Nonisolated deinit helper function.
    ///
    /// This fallback path exists to give `AVAssetWriter.finishWriting` one last
    /// bounded chance to complete file finalization when the writer is released
    /// while recording is still active.
    nonisolated private func deinitHelper() {
        if let avAssetWriter = cache.assetWriter, cache.isRecording == true {
            let cache = self.cache
            let avAssetWriterInputVideo = cache.assetWriterInputVideo
            let avAssetWriterInputAudio = cache.assetWriterInputAudio
            let avAssetWriterInputTimecode = cache.assetWriterInputTimecode
            let timeoutSeconds = cache.finishWritingTimeoutSeconds
            let writerKey = ObjectIdentifier(avAssetWriter)
            
            cache.diagnosticHandler?(.deinitWhileRecording)
            cache.retainAssetWriter(avAssetWriter)
            
            avAssetWriterInputVideo?.markAsFinished()
            avAssetWriterInputAudio?.markAsFinished()
            avAssetWriterInputTimecode?.markAsFinished()
            
            let semaphore = DispatchSemaphore(value: 0)
            avAssetWriter.finishWriting {
                cache.releaseAssetWriter(forKey: writerKey)
                semaphore.signal()
            }
            let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)
            if waitResult == .timedOut {
                cache.diagnosticHandler?(.finishWritingTimedOut(timeoutSeconds: timeoutSeconds))
                avAssetWriter.cancelWriting()
                cache.releaseAssetWriter(forKey: writerKey)
            }
        }
    }
    
    /* ============================================ */
    // MARK: - public functions
    /* ============================================ */
    
    /// Start writing session
    /// - Note: If any error occurs, it will be stored in `internalError`.
    public func openSession() async {
        openSessionStartedAt = CFAbsoluteTimeGetCurrent()
        loggedFirstVideoAppend = false
        
        if isRecording {
            await closeSession()
        }
        
        if movieURL == nil {
            movieURL = prepareDefaultURL()
        }
        
        //
        internalError = nil
        if let fileURL = movieURL {
            do {
                // Remove existing file at URL first
                let fileManager = FileManager()
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(atPath: fileURL.path)
                }
                
                // Start recording
                try startRecording(fileURL)
                isRecording = true
            } catch {
                if internalError == nil {
                    internalError = error
                }
                isRecording = false
            }
        } else {
            let reason = "Invalid movie URL provided."
            internalError = CaptureWriterError.assetWriterIsNotAvailable(reason)
            isRecording = false
        }
    }
    
    /// Stop writing session
    /// - Note: If any error occurs, it will be stored in `internalError`.
    public func closeSession() async {
        //
        internalError = nil
        if isRecording {
            do {
                // Stop recording
                try await stopRecording()
                isRecording = false
            } catch {
                if internalError == nil {
                    internalError = error
                }
                isRecording = false
            }
        } else {
            let reason = "No recording session is in progress."
            internalError = CaptureWriterError.assetWriterIsNotAvailable(reason)
        }
    }
    
    public func resolvedMovieURL() -> URL? {
        movieURL
    }
    
    /// Append SampleBuffer with UnsafeSampleBufferWrapper
    /// - Parameter wrapper: UnsafeSampleBufferWrapper instance containing the sample buffer.
    /// - Parameter mediaType: The media type of the sample buffer (video, audio, timecode).
    public func appendSampleBuffer(wrapper: UnsafeSampleBufferWrapper, mediaType: AVMediaType) throws {
        switch mediaType {
        case .video:
            try writeVideoSampleBuffer(wrapper.sampleBuffer)
        case .audio:
            try writeAudioSampleBuffer(wrapper.sampleBuffer)
        case .timecode:
            try writeTimecodeSampleBuffer(wrapper.sampleBuffer)
        default:
            throw CaptureWriterError.unsupportedMediaType(mediaType.rawValue)
        }
    }
    
    /* ============================================ */
    // MARK: - Internal/Private func
    /* ============================================ */
    
    private func prepareDefaultURL() -> URL? {
        var movieFolders : [String]? = nil
        let moviesPathDirectory = FileManager.SearchPathDirectory.moviesDirectory
        let userDomainMask = FileManager.SearchPathDomainMask.userDomainMask
        movieFolders = NSSearchPathForDirectoriesInDomains(moviesPathDirectory, userDomainMask, true)
        
        if let movieFolder = movieFolders?.first {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMddHHmmss"
            var movieName = formatter.string(from: Date()) + ".mov"
            if let prefix = prefix {
                movieName = prefix + movieName
            }
            return URL.init(fileURLWithPath: movieFolder).appendingPathComponent(movieName)
        }
        return nil
    }
    
    private func startRecording(_ fileURL: URL) throws {
        let startAt = CFAbsoluteTimeGetCurrent()
        
        // reset TS variables and duration
        initializeTimeStamp()
        
        // Create AVAssetWriter for QuickTime Movie
        let createWriterStart = CFAbsoluteTimeGetCurrent()
        do {
            avAssetWriter = try assetWriterFactory(fileURL, AVFileType.mov)
        } catch {
            traceStartup("create-writer \(elapsedMS(from: createWriterStart))ms")
            let reason = "AVAssetWriter initialization failed: \(error.localizedDescription)"
            throw CaptureWriterError.assetWriterIsNotAvailable(reason)
        }
        traceStartup("create-writer \(elapsedMS(from: createWriterStart))ms")
        
        if let avAssetWriter = avAssetWriter {
            // Apply movieTimeScale
            avAssetWriter.movieTimeScale = sampleTimescale
            
            // Prepare AVAssetWriterInput(s)
            let prepareInputStart = CFAbsoluteTimeGetCurrent()
            try prepareInputMedia()
            traceStartup("prepare-input-media \(elapsedMS(from: prepareInputStart))ms")
            
            // Register AVAssetWriterInput(s)
            let registerInputStart = CFAbsoluteTimeGetCurrent()
            try registerInputMedia()
            traceStartup("register-input-media \(elapsedMS(from: registerInputStart))ms")
            
            // Start writing session
            let startWritingStart = CFAbsoluteTimeGetCurrent()
            let valid = avAssetWriter.startWriting()
            traceStartup("start-writing \(elapsedMS(from: startWritingStart))ms")
            if !valid {
                if let error = avAssetWriter.error {
                    let reason = error.localizedDescription
                    throw CaptureWriterError.unexpectedErrorWhileOpeningSession(reason)
                } else {
                    let statusStr = self.descriptionForStatus(avAssetWriter.status)
                    let reason = "AVAssetWriter did not start successfully. (\(statusStr))"
                    throw CaptureWriterError.unexpectedErrorWhileOpeningSession(reason)
                }
            }
            traceStartup("open-session-total \(elapsedMS(from: startAt))ms")
        } else {
            let reason = "AVAssetWriter is not available."
            throw CaptureWriterError.assetWriterIsNotAvailable(reason)
        }
    }
    
    private func stopRecording() async throws {
        if let avAssetWriter = avAssetWriter {
            // Finish writing
            avAssetWriterInputTimecode?.markAsFinished()
            avAssetWriterInputVideo?.markAsFinished()
            avAssetWriterInputAudio?.markAsFinished()
            
            if duration > 0.0 {
                avAssetWriter.endSession(atSourceTime: endTime)
            }
            let timeoutSeconds = finishWritingTimeoutSeconds
            let didFinish = await waitForFinishWriting(avAssetWriter, timeoutSeconds: timeoutSeconds)
            defer {
                // unref AVAssetWriter
                cleanUp()
            }
            
            if didFinish == false {
                diagnosticHandler?(.finishWritingTimedOut(timeoutSeconds: timeoutSeconds))
                throw CaptureWriterError.finishWritingTimedOut("AVAssetWriter.finishWriting did not complete within \(timeoutSeconds) seconds")
            }
            
            // Finalize TS variables and duration
            self.finalizeTimeStamp()
            
            // Check if completed
            if avAssetWriter.status != .completed {
                if let error = avAssetWriter.error {
                    let reason = error.localizedDescription
                    throw CaptureWriterError.unexpectedErrorWhileClosingSession(reason)
                } else {
                    let statusStr = self.descriptionForStatus(avAssetWriter.status)
                    let reason = "AVAssetWriter did not complete successfully. (\(statusStr))"
                    throw CaptureWriterError.unexpectedErrorWhileClosingSession(reason)
                }
            }
        } else {
            let reason = "AVAssetWriter is not available."
            throw CaptureWriterError.assetWriterIsNotAvailable(reason)
        }
    }
    
    private func waitForFinishWriting(_ avAssetWriter: AVAssetWriter, timeoutSeconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let state = FinishWritingResumeState()
            let cache = self.cache
            let writerKey = ObjectIdentifier(avAssetWriter)
            cache.retainAssetWriter(avAssetWriter)
            
            let settle: @Sendable (Bool, Bool) -> Void = { didFinish, shouldCancelWriting in
                let shouldResume = state.lock.withLock {
                    if state.resumed {
                        return false
                    }
                    state.resumed = true
                    return true
                }
                if shouldResume {
                    if shouldCancelWriting {
                        cache.cancelWriting(forKey: writerKey)
                    }
                    cache.releaseAssetWriter(forKey: writerKey)
                    continuation.resume(returning: didFinish)
                }
            }
            
            let timeoutWorkItem = DispatchWorkItem {
                settle(false, true)
            }
            let timeoutWorkItemBox = DispatchWorkItemBox(workItem: timeoutWorkItem)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)
            
            avAssetWriter.finishWriting {
                timeoutWorkItemBox.workItem.cancel()
                settle(true, false)
            }
        }
    }
    
    private func cleanUp() {
        // unref AVAssetWriter
        self.avAssetWriterInputTimecode = nil
        self.avAssetWriterInputVideo = nil
        self.avAssetWriterInputAudio = nil
        self.avAssetWriter = nil
        self.openSessionStartedAt = 0
        self.loggedFirstVideoAppend = false
    }
    
    /* ============================================ */
    // MARK: -
    /* ============================================ */
    
    private func initializeTimeStamp() {
        // reset TS variables and duration
        isInitialTSReady = false
        startTime = CMTime.zero
        endTime = CMTime.zero
        duration = 0.0
    }
    
    private func updateTimeStamp(_ sampleBuffer: CMSampleBuffer) {
        // Update InitialTimeStamp and EndTimeStamp
        let sbPresentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sbDuration = CMSampleBufferGetDuration(sampleBuffer)
        
        // Set startTime CMTime value
        if let avAssetWriter = avAssetWriter, isInitialTSReady == false {
            // Set initial SourceTime value for AVAssetWriter
            avAssetWriter.startSession(atSourceTime: sbPresentation)
            
            // Set initial time stamp for session
            isInitialTSReady = true
            startTime = sbPresentation
        }
        
        // Update endTime/duration CMTime value
        endTime = CMTimeAdd(sbPresentation, sbDuration)
        duration = CMTimeGetSeconds(CMTimeSubtract(endTime, startTime))
    }
    
    private func finalizeTimeStamp() {
        // Calc duration and Reset CMTime values
        if isInitialTSReady == true {
            duration = CMTimeGetSeconds(CMTimeSubtract(endTime, startTime))
        } else {
            duration = 0.0
        }
        isInitialTSReady = false
        startTime = CMTime.zero
        endTime = CMTime.zero
    }
    
    /* ============================================ */
    // MARK: -
    /* ============================================ */
    
    fileprivate func writeAudioSampleBufferCore(_ sampleBuffer: CMSampleBuffer) throws {
        guard let avAssetWriterInputAudio = avAssetWriterInputAudio else {
            let reason = "ERROR: AVAssetWriterInputAudio is not available."
            throw CaptureWriterError.unsupportedMediaType(reason)
        }
        guard avAssetWriterInputAudio.isReadyForMoreMediaData else {
            let reason = "ERROR: AVAssetWriterInputAudio is not ready to append."
            throw CaptureWriterError.audioSampleBufferAppendFailed(reason)
        }
        
        //
        updateTimeStamp(sampleBuffer)
        let result = avAssetWriterInputAudio.append(sampleBuffer)
        
        if !result {
            if let avAssetWriter = avAssetWriter, let error = avAssetWriter.error {
                let reason = error.localizedDescription
                throw CaptureWriterError.audioSampleBufferAppendFailed(reason)
            } else {
                let statusStr : String = descriptionForStatus(avAssetWriter?.status ?? .unknown)
                let reason = "ERROR: Could not write audio sample buffer.(\(statusStr))"
                throw CaptureWriterError.audioSampleBufferAppendFailed(reason)
            }
        }
    }
    
    private func writeAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) throws {
        // For MPEG4 AAC encoding, remap the channel order
        if encodeAudio, isAACFamily(encodeAudioFormatID) {
            guard let remappedBuffer = remapLPCMChannelOrderForAAC(sampleBuffer, self.audioChannelLayoutOutputType) else {
                let reason = "ERROR: Could not remap audio sample buffer."
                throw CaptureWriterError.audioSampleBufferAppendFailed(reason)
            }
            
            //
            try writeAudioSampleBufferCore(remappedBuffer)
        } else {
            //
            try writeAudioSampleBufferCore(sampleBuffer)
        }
    }
    
    private func writeVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) throws {
        if let avAssetWriterInputVideo = avAssetWriterInputVideo {
            if avAssetWriterInputVideo.isReadyForMoreMediaData {
                //
                updateTimeStamp(sampleBuffer)
                let result = avAssetWriterInputVideo.append(sampleBuffer)
                
                if !result {
                    if let avAssetWriter = avAssetWriter, let error = avAssetWriter.error {
                        let reason = error.localizedDescription
                        throw CaptureWriterError.videoSampleBufferAppendFailed(reason)
                    } else {
                        let statusStr : String = descriptionForStatus(avAssetWriter?.status ?? .unknown)
                        let reason = "ERROR: Could not write video sample buffer.(\(statusStr))"
                        throw CaptureWriterError.videoSampleBufferAppendFailed(reason)
                    }
                } else if traceStartupTiming, !loggedFirstVideoAppend, openSessionStartedAt > 0 {
                    loggedFirstVideoAppend = true
                    traceStartup("first-video-append \(elapsedMS(from: openSessionStartedAt))ms")
                }
            } else {
                let reason = "ERROR: AVAssetWriterInputVideo is not ready to append."
                throw CaptureWriterError.videoSampleBufferAppendFailed(reason)
            }
        } else {
            let reason = "ERROR: AVAssetWriterInputVideo is not available."
            throw CaptureWriterError.unsupportedMediaType(reason)
        }
    }
    
    private func writeTimecodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) throws {
        if let avAssetWriterInputTimeCode = avAssetWriterInputTimecode {
            if avAssetWriterInputTimeCode.isReadyForMoreMediaData {
                //
                updateTimeStamp(sampleBuffer)
                let result = avAssetWriterInputTimeCode.append(sampleBuffer)
                
                if !result {
                    if let avAssetWriter = avAssetWriter, let error = avAssetWriter.error {
                        let reason = error.localizedDescription
                        throw CaptureWriterError.timecodeSampleBufferAppendFailed(reason)
                    } else {
                        let statusStr : String = descriptionForStatus(avAssetWriter?.status ?? .unknown)
                        let reason = "ERROR: Could not write timecode sample buffer.(\(statusStr))"
                        throw CaptureWriterError.timecodeSampleBufferAppendFailed(reason)
                    }
                }
            } else {
                let reason = "ERROR: AVAssetWriterInputTimecode is not ready to append."
                throw CaptureWriterError.timecodeSampleBufferAppendFailed(reason)
            }
        } else {
            let reason = "ERROR: AVAssetWriterInputTimecode is not available."
            throw CaptureWriterError.unsupportedMediaType(reason)
        }
    }
    
    /* ============================================ */
    // MARK: -
    /* ============================================ */
    
    private func prepareInputMedia() throws {
        if useVideo, let avAssetWriter = avAssetWriter {
            if encodeVideo == false {
                // Create AVAssetWriterInput for Video (Passthru)
                avAssetWriterInputVideo = AVAssetWriterInput(mediaType: AVMediaType.video,
                                                             outputSettings: nil,
                                                             sourceFormatHint: sourceVideoFormatDescription)
            } else {
                // Create AVAssetWriterInput for Video (Compress)
                let videoOutputSettings : [String:Any] = createOutputSettingsVideo()
                if avAssetWriter.canApply(outputSettings: videoOutputSettings, forMediaType: AVMediaType.video) {
                    avAssetWriterInputVideo = AVAssetWriterInput(mediaType: AVMediaType.video,
                                                                 outputSettings: videoOutputSettings,
                                                                 sourceFormatHint: sourceVideoFormatDescription)
                } else {
                    throw CaptureWriterError.invalidVideoOutputSettings
                }
            }
            
            // Apply preferred video media timescale
            if sampleTimescale > 0, let avAssetWriterInputVideo = avAssetWriterInputVideo {
                avAssetWriterInputVideo.mediaTimeScale = sampleTimescale
            }
        }
        if useAudio, let avAssetWriter = avAssetWriter {
            if encodeAudio == false {
                // Create AVAssetWriterInput for Audio (Passthru)
                avAssetWriterInputAudio = AVAssetWriterInput(mediaType: AVMediaType.audio,
                                                             outputSettings: nil,
                                                             sourceFormatHint: sourceAudioFormatDescription)
            } else {
                // Create OutputSettings for Audio (Compress)
                let audioOutputSettings : [String:Any] = createOutputSettingsAudio()
                
                var finalSourceAudioFormatDescription = sourceAudioFormatDescription
                
                // For AAC encoding, the source format hint might need to be remapped
                // to match what remapLPCMChannelOrderForAAC will produce.
                if isAACFamily(encodeAudioFormatID), let sourceFD = sourceAudioFormatDescription {
                    // Use the new createRemappedFormatDescription function
                    if let remappedFormatDescription = createRemappedFormatDescription(from: sourceFD) {
                        finalSourceAudioFormatDescription = remappedFormatDescription
                        
                        // Update audioChannelLayoutOutputType based on the determined output type
                        if let outputType = determineOutputType(from: sourceFD, forAAC: true) {
                            self.audioChannelLayoutOutputType = outputType
                        } else {
                            self.audioChannelLayoutOutputType = .descriptions8Ch
                        }
                    } else {
                        // Fallback to original format description if remapping fails
                        self.audioChannelLayoutOutputType = .descriptions8Ch
                    }
                }
                
                if avAssetWriter.canApply(outputSettings: audioOutputSettings, forMediaType: AVMediaType.audio) {
                    avAssetWriterInputAudio = AVAssetWriterInput(mediaType: AVMediaType.audio,
                                                                 outputSettings: audioOutputSettings,
                                                                 sourceFormatHint: finalSourceAudioFormatDescription)
                } else {
                    throw CaptureWriterError.invalidAudioOutputSettings
                }
            }
        }
        if useTimecode {
            // Create AVAssetWriterInput for Timecode (SMPTE)
            avAssetWriterInputTimecode = AVAssetWriterInput(mediaType: AVMediaType.timecode,
                                                            outputSettings: nil)
            
            if let inputVideo = avAssetWriterInputVideo, let inputTimeCode = avAssetWriterInputTimecode {
                inputVideo.addTrackAssociation(withTrackOf: inputTimeCode,
                                               type: AVAssetTrack.AssociationType.timecode.rawValue)
            }
            
            // Apply preferred timecode media timescale
            if sampleTimescale > 0, let avAssetWriterInputTimecode = avAssetWriterInputTimecode {
                avAssetWriterInputTimecode.mediaTimeScale = sampleTimescale
            }
        }
    }
    
    private func registerInputMedia() throws {
        if useVideo, let avAssetWriter = avAssetWriter {
            // Register AVAssetWriterInput for Video to AVAssetWriter
            if let avAssetWriterInputVideo = avAssetWriterInputVideo {
                if avAssetWriter.canAdd(avAssetWriterInputVideo) {
                    avAssetWriterInputVideo.expectsMediaDataInRealTime = true
                    avAssetWriter.add(avAssetWriterInputVideo)
                } else {
                    let reason = "avAssetWriter.canAdd(avAssetWriterInputVideo) failed"
                    throw CaptureWriterError.unsupportedMediaType(reason)
                }
            }
        }
        if useAudio, let avAssetWriter = avAssetWriter {
            // Register AVAssetWriterInput for Audio to AVAssetWriter
            if let avAssetWriterInputAudio = avAssetWriterInputAudio {
                if avAssetWriter.canAdd(avAssetWriterInputAudio) {
                    avAssetWriterInputAudio.expectsMediaDataInRealTime = true
                    avAssetWriter.add(avAssetWriterInputAudio)
                } else {
                    let reason = "avAssetWriter.canAdd(avAssetWriterInputAudio) failed"
                    throw CaptureWriterError.unsupportedMediaType(reason)
                }
            }
        }
        if useTimecode, let avAssetWriter = avAssetWriter {
            // Register AVAssetWriterInput for Timecode to AVAssetWriter
            if let avAssetWriterInputTimeCode = avAssetWriterInputTimecode {
                if avAssetWriter.canAdd(avAssetWriterInputTimeCode) {
                    avAssetWriterInputTimeCode.expectsMediaDataInRealTime = true
                    avAssetWriter.add(avAssetWriterInputTimeCode)
                } else {
                    let reason = "avAssetWriter.canAdd(avAssetWriterInputTimeCode) failed"
                    throw CaptureWriterError.unsupportedMediaType(reason)
                }
            }
        }
    }
    
    /* ============================================ */
    // MARK: -
    /* ============================================ */
    
    private func createOutputSettingsVideo() -> [String:Any] {
        // Create OutputSettings for Video (Compress)
        var videoOutputSettings : [String:Any] = [:]
        
        // VidoStyle string and clap:hOffset value
        videoOutputSettings = videoStyle.settings(hOffset: clapHOffset, vOffset: clapVOffset)
        
        // video hardware encoder
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : kCFBooleanTrue!,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder : kCFBooleanFalse!
        ]
        videoOutputSettings[AVVideoEncoderSpecificationKey] = encoderSpecification
        
        // video output codec
        if encodeProRes422 {
            videoOutputSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        } else {
            if let encodeVideoCodecType = encodeVideoCodecType {
                let fourCC :String = fourCharString(encodeVideoCodecType)
                videoOutputSettings[AVVideoCodecKey] = fourCC
            } else {
                videoOutputSettings[AVVideoCodecKey] = AVVideoCodecType.h264
            }
        }
        
        // video output compression properties
        var compressionProperties : [String:Any] = [:]
        
        if encodeVideoBitrate > 0 {
            compressionProperties[AVVideoAverageBitRateKey] = encodeVideoBitrate
        }
        
        let codecString: String
        if let codecType = videoOutputSettings[AVVideoCodecKey] as? AVVideoCodecType {
            codecString = codecType.rawValue
        } else if let codec = videoOutputSettings[AVVideoCodecKey] as? String {
            codecString = codec
        } else {
            codecString = AVVideoCodecType.h264.rawValue
        }
        if codecString == "avc1" {
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            compressionProperties[AVVideoAllowFrameReorderingKey] = true
            compressionProperties[AVVideoMaxKeyFrameIntervalDurationKey] = 1.0
            compressionProperties[AVVideoExpectedSourceFrameRateKey] = encodeVideoFrameRate
        }
        if codecString == "hvc1" {
            compressionProperties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
            compressionProperties[AVVideoAllowFrameReorderingKey] = true
            compressionProperties[AVVideoMaxKeyFrameIntervalDurationKey] = 1.0
            compressionProperties[AVVideoExpectedSourceFrameRateKey] = encodeVideoFrameRate
        }
        
        if let fieldDetail = fieldDetail {
            // Use interlaced encoding
            let keyFieldCount = kVTCompressionPropertyKey_FieldCount as String
            let keyFieldDetail = kVTCompressionPropertyKey_FieldDetail as String
            compressionProperties[keyFieldCount] = 2
            compressionProperties[keyFieldDetail] = fieldDetail
        }
        
        if compressionProperties.count > 0 {
            videoOutputSettings[AVVideoCompressionPropertiesKey] = compressionProperties
        }
        
        // Check if user want to customize settings
        if let updateVideoSettings = updateVideoSettings {
            // Call optional updateVideoSettings block
            videoOutputSettings = updateVideoSettings(videoOutputSettings)
        }
        
        return videoOutputSettings
    }
    
    private func createOutputSettingsAudio() -> [String:Any] {
        // Create OutputSettings for Audio (Compress)
        var audioOutputSettings : [String:Any] = [:]
        // Channel count of AVAudioFormat
        var avafChannelCount: Int? = nil
        // Channel count of AudioChannelLayout
        var aclChannelCount: Int? = nil
        
        // Use specified audio codec and bitrate
        // Keep SampleRate/ChannelCount/ChannelLayout from CMFormatDescription of source audio
        if let sourceAudioFormatDescription = sourceAudioFormatDescription {
            var avaf : AVAudioFormat? = nil
            var aclData : NSData? = nil
            let asbd_p : UnsafePointer<AudioStreamBasicDescription>? =
                CMAudioFormatDescriptionGetStreamBasicDescription(sourceAudioFormatDescription)
            if let asbd_p = asbd_p {
                var layoutSize : Int = 0
                let acl_p : UnsafePointer<AudioChannelLayout>? =
                    CMAudioFormatDescriptionGetChannelLayout(sourceAudioFormatDescription, sizeOut: &layoutSize)
                if let acl_p = acl_p {
                    let avacl = AVAudioChannelLayout.init(layout: acl_p)
                    avaf = AVAudioFormat.init(streamDescription: asbd_p, channelLayout: avacl)
                    aclData = NSData.init(bytes: UnsafeRawPointer(acl_p), length: layoutSize)
                } else {
                    avaf = AVAudioFormat.init(streamDescription: asbd_p)
                    aclData = nil
                }
            }
            
            // Set output settings from source audio format
            if let avaf = avaf {
                // The framework supports 2, 8, or 16 channels only.
                avafChannelCount = Int(avaf.channelCount)
                
                //
                audioOutputSettings[AVFormatIDKey] = Int(encodeAudioFormatID)
                audioOutputSettings[AVSampleRateKey] = Float(avaf.sampleRate)
                audioOutputSettings[AVNumberOfChannelsKey] = Int(avaf.channelCount)
                if encodeAudioBitrate > 0 {
                    audioOutputSettings[AVEncoderBitRateKey] = Int(encodeAudioBitrate)
                    audioOutputSettings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
                }
            }
            if let aclData = aclData {
                // The framework provides actual channel layout in two ways:
                // (1) discrete (while avafChannelCount is 2/8/16)
                // (2) 2, 3, 5.1, 7.1 channels (while avafChannelCount is 8)
                let acl_p : UnsafePointer<AudioChannelLayout> = aclData.bytes
                    .bindMemory(to: AudioChannelLayout.self, capacity: 1)
                aclChannelCount = countValidChannels(layoutPtr: acl_p)
                
                //
                audioOutputSettings[AVChannelLayoutKey] = aclData
            }
            
            // print("Channel count AVAF:\(avafChannelCount ?? 0), ACL:\(aclChannelCount ?? 0)")
        }
        
        // Use specified audio codec and bitrate
        // Use default stereo 48KHz audio
        if audioOutputSettings.count == 0 {
            audioOutputSettings[AVFormatIDKey] = Int(encodeAudioFormatID)
            audioOutputSettings[AVSampleRateKey] = Float(48000)
            audioOutputSettings[AVNumberOfChannelsKey] = Int(2)
            if encodeAudioBitrate > 0 {
                audioOutputSettings[AVEncoderBitRateKey] = Int(encodeAudioBitrate)
                audioOutputSettings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
            }
        }
        
        // Check if user want to customize settings
        if let updateAudioSettings = updateAudioSettings {
            // Call optional updateAudioSettings block
            audioOutputSettings = updateAudioSettings(audioOutputSettings)
        }
        
        // Clipping for kAudioFormatMPEG4AAC
        let formatID = audioOutputSettings[AVFormatIDKey] as? Int
        if let formatID, isAACFamily(UInt32(formatID)) {
            let sampleRate = audioOutputSettings[AVSampleRateKey] as? Float
            let channelCount = audioOutputSettings[AVNumberOfChannelsKey] as? Int
            let bitRate = audioOutputSettings[AVEncoderBitRateKey] as? Int
            
            if let sampleRate, sampleRate > 48000.0 {
                // kAudioFormatMPEG4AAC runs up to 48KHz
                audioOutputSettings[AVSampleRateKey] = Float(48000)
            }
            if let channelCount, let bitRate {
                if channelCount <= 2 {
                    // kAudioFormatMPEG4AAC w/ 2ch runs up to 320Kbps
                    let clippedValue = bitRate.clipped(to: 32_000...320_000)
                    audioOutputSettings[AVEncoderBitRateKey] = clippedValue
                }
                if channelCount > 2 {
                    // Use channel count from AudioChannelLayout if available
                    let validCount = (aclChannelCount ?? (avafChannelCount ?? channelCount))
                    audioOutputSettings[AVNumberOfChannelsKey] = validCount
                    
                    // Apply bitrate clipping
                    if validCount <= 2 {
                        // AAC-LC, HE-AAC, or HE-AACv2
                        let clippedValue = bitRate.clipped(to: 32_000...320_000)
                        audioOutputSettings[AVEncoderBitRateKey] = clippedValue
                    }
                    if validCount > 2 {
                        // AAC-LC Only
                        let range = queryBitrateRange(channelCount: validCount)
                        let clippedValue = bitRate.clipped(to: range.min...range.max)
                        audioOutputSettings[AVEncoderBitRateKey] = clippedValue
                        
                        // Ensure AAC-LC
                        audioOutputSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
                    }
                    
                    // Remove source acl because of incompatibility w/ kAudioFormatMPEG4AAC
                    audioOutputSettings[AVChannelLayoutKey] = nil
                    
                    // Create appropriate AudioChannelLayout for AAC encoding
                    let layoutTag: AudioChannelLayoutTag
                    switch validCount {
                    case 2:
                        layoutTag = kAudioChannelLayoutTag_Stereo // L R
                    case 3:
                        layoutTag = kAudioChannelLayoutTag_MPEG_3_0_B // C L R
                    case 6: // 5.1ch
                        layoutTag = kAudioChannelLayoutTag_MPEG_5_1_D // C L R Ls Rs LFE
                    case 8: // 7.1ch
                        layoutTag = kAudioChannelLayoutTag_MPEG_7_1_B // C Lc Rc L R Ls Rs LFE
                    default:
                        layoutTag = kAudioChannelLayoutTag_DiscreteInOrder
                    }
                    
                    // Create AudioChannelLayout with the determined tag
                    var outLayout = AudioChannelLayout(
                        mChannelLayoutTag: layoutTag,
                        mChannelBitmap: AudioChannelBitmap(rawValue: 0),
                        mNumberChannelDescriptions: 0,
                        mChannelDescriptions: AudioChannelDescription()
                    )
                    
                    let layoutData = withUnsafePointer(to: &outLayout) { layoutPtr in
                        return NSData(bytes: layoutPtr, length: MemoryLayout<AudioChannelLayout>.size)
                    }
                    
                    audioOutputSettings[AVChannelLayoutKey] = layoutData
                }
            }
        }
        
        return audioOutputSettings
    }
    
    /* ============================================ */
    // MARK: -
    /* ============================================ */
    
    /// AAC encoder bitrate range
    private func queryBitrateRange<T: BinaryInteger>(channelCount: T) -> (min: T, max: T) {
        precondition(channelCount > 0, "Channel count must be positive")
        let channelCountWithoutLFE: T = (channelCount > 5) ? (channelCount - 1) : channelCount
        let minRate = 40_000 * channelCountWithoutLFE
        let maxRate = 160_000 * channelCountWithoutLFE
        return (min: minRate, max: maxRate)
    }
    
    private func elapsedMS(from start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000.0)
    }
    
    private func traceStartup(_ message: String) {
        guard traceStartupTiming else { return }
        print("TRACE:CaptureWriter.openSession - \(message)")
    }
    
    private func descriptionForStatus(_ status :AVAssetWriter.Status) -> String {
        // In case of faulty status
        let statusArray : [AVAssetWriter.Status : String] = [
            .unknown    : "AVAssetWriterStatus.Unknown",
            .writing    : "AVAssetWriterStatus.Writing",
            .completed  : "AVAssetWriterStatus.Completed",
            .failed     : "AVAssetWriterStatus.Failed",
            .cancelled  : "AVAssetWriterStatus.Cancelled"
        ]
        let statusStr = statusArray[status] ?? "Unknown(\(status.rawValue))"
        
        return statusStr
    }
    
    private func fourCharString(_ type :OSType) -> String {
        let c1 : UInt32 = (type >> 24) & 0xFF
        let c2 : UInt32 = (type >> 16) & 0xFF
        let c3 : UInt32 = (type >>  8) & 0xFF
        let c4 : UInt32 = (type      ) & 0xFF
        let bytes: [UInt8] = [
            UInt8( c1 == 0x00 ? 0x20 : c1),
            UInt8( c2 == 0x00 ? 0x20 : c2),
            UInt8( c3 == 0x00 ? 0x20 : c3),
            UInt8( c4 == 0x00 ? 0x20 : c4)
        ]
        let fourCCString = String(decoding: bytes, as: UTF8.self)
        return fourCCString
    }
}

extension CaptureWriter {
    // Definition of CaptureWriterConfig structure
    public struct CaptureWriterConfig: Sendable {
        // prepare specified media track
        public var useAudio: Bool = true
        public var useVideo: Bool = true
        public var useTimecode: Bool = false
        
        // Optional parameter
        public var movieURL: URL? = nil
        public var prefix: String? = nil
        public var sourceVideoFormatDescription: CMFormatDescription? = nil
        public var sourceAudioFormatDescription: CMFormatDescription? = nil
        public var sampleTimescale: CMTimeScale = 0
        public var fieldDetail: String? = nil // CFString? = nil
        public var updateVideoSettings: ((@Sendable ([String:Any]) -> [String:Any]))? = nil
        public var updateAudioSettings: ((@Sendable ([String:Any]) -> [String:Any]))? = nil
        
        // output encoding setting
        public var encodeAudio: Bool = false
        public var encodeAudioFormatID: AudioFormatID = kAudioFormatMPEG4AAC
        public var encodeAudioBitrate: UInt = CaptureWriter.defaultEncodeAudioBitrate
        public var encodeVideo: Bool = true
        public var encodeProRes422: Bool = true
        public var encodeVideoCodecType: CMVideoCodecType? = kCMVideoCodecType_H264
        public var encodeVideoBitrate: UInt = 0
        public var encodeVideoFrameRate: Float = 30/1.001
        public var videoStyle: VideoStyle = .SD_720_486_16_9
        public var clapHOffset: Int = 0
        public var clapVOffset: Int = 0
        public var traceStartupTiming: Bool = false
        public var diagnosticHandler: DiagnosticHandler? = nil
        public var finishWritingTimeoutSeconds: TimeInterval = CaptureWriter.defaultFinishWritingTimeoutSeconds
        
        public init() {}
    }
    
    /* ============================================ */
    // MARK: - Configuration API
    /* ============================================ */
    
    /// Get current configuration as CaptureWriterConfig
    public func getConfig() -> CaptureWriterConfig {
        var config = CaptureWriterConfig()
        
        // prepare specified media track
        config.useAudio = self.useAudio
        config.useVideo = self.useVideo
        config.useTimecode = self.useTimecode
        
        // Optional parameter
        config.movieURL = self.movieURL
        config.prefix = self.prefix
        config.sourceVideoFormatDescription = self.sourceVideoFormatDescription
        config.sourceAudioFormatDescription = self.sourceAudioFormatDescription
        config.sampleTimescale = self.sampleTimescale
        config.fieldDetail = self.fieldDetail as String?
        config.updateVideoSettings = self.updateVideoSettings
        config.updateAudioSettings = self.updateAudioSettings
        
        // output encoding setting
        config.encodeAudio = self.encodeAudio
        config.encodeAudioFormatID = self.encodeAudioFormatID
        config.encodeAudioBitrate = self.encodeAudioBitrate
        config.encodeVideo = self.encodeVideo
        config.encodeProRes422 = self.encodeProRes422
        config.encodeVideoCodecType = self.encodeVideoCodecType
        config.encodeVideoBitrate = self.encodeVideoBitrate
        config.encodeVideoFrameRate = self.encodeVideoFrameRate
        config.videoStyle = self.videoStyle
        config.clapHOffset = self.clapHOffset
        config.clapVOffset = self.clapVOffset
        config.traceStartupTiming = self.traceStartupTiming
        config.diagnosticHandler = self.diagnosticHandler
        config.finishWritingTimeoutSeconds = self.finishWritingTimeoutSeconds
        
        return config
    }
    
    /// Apply configuration from CaptureWriterConfig
    public func setConfig(_ config: CaptureWriterConfig) {
        // prepare specified media track
        self.useAudio = config.useAudio
        self.useVideo = config.useVideo
        self.useTimecode = config.useTimecode
        
        // Optional parameter
        self.movieURL = config.movieURL
        self.prefix = config.prefix
        self.sourceVideoFormatDescription = config.sourceVideoFormatDescription
        self.sourceAudioFormatDescription = config.sourceAudioFormatDescription
        self.sampleTimescale = config.sampleTimescale
        self.fieldDetail = config.fieldDetail as CFString?
        self.updateVideoSettings = config.updateVideoSettings
        self.updateAudioSettings = config.updateAudioSettings
        
        // output encoding setting
        self.encodeAudio = config.encodeAudio
        self.encodeAudioFormatID = config.encodeAudioFormatID
        self.encodeAudioBitrate = config.encodeAudioBitrate
        self.encodeVideo = config.encodeVideo
        self.encodeProRes422 = config.encodeProRes422
        self.encodeVideoCodecType = config.encodeVideoCodecType
        self.encodeVideoBitrate = config.encodeVideoBitrate
        self.encodeVideoFrameRate = config.encodeVideoFrameRate
        self.videoStyle = config.videoStyle
        self.clapHOffset = config.clapHOffset
        self.clapVOffset = config.clapVOffset
        self.traceStartupTiming = config.traceStartupTiming
        self.diagnosticHandler = config.diagnosticHandler
        self.finishWritingTimeoutSeconds = config.finishWritingTimeoutSeconds
    }
}
