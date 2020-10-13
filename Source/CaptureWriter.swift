//
//  CaptureWriter.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2017/09/16.
//  Copyright © 2017-2020年 MyCometG3. All rights reserved.
//

import Foundation
import AVFoundation
import VideoToolbox

class CaptureWriter: NSObject {
    /* ============================================ */
    // MARK: - readonly property
    /* ============================================ */
    
    /// True while recoding is running.
    public private(set) var isRecording : Bool = false
    /// Recording duration in sec.
    public private(set) var duration : Float64 = 0.0
    /// CMTime for start time.
    public private(set) var startTime : CMTime = CMTime.zero
    /// CMTime for end time.
    public private(set) var endTime : CMTime = CMTime.zero
    /// Flag if starting CMTime is valid or not
    public private(set) var isInitialTSReady : Bool = false
    
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
    public var updateVideoSettings : (([String:Any]) -> [String:Any])? = nil
    /// Optional: customise audio encode settings of AVAssetWriterInput.
    public var updateAudioSettings : (([String:Any]) -> [String:Any])? = nil
    
    /* ============================================ */
    // MARK: - output encoding setting
    /* ============================================ */
    
    /// Set YES to encode audio.
    public var encodeAudio : Bool = false
    /// Set AudioCodec ID as kAudioFormatXXX.
    public var encodeAudioFormatID : AudioFormatID = kAudioFormatMPEG4AAC
    /// Set Audio target bitrate. default is 256 * 1024 bps.
    public var encodeAudioBitrate : UInt = 256 * 1024
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
    
    /* ============================================ */
    // MARK: - private variable
    /* ============================================ */
    
    /// Backend AVAssetWriter for QuickTime movie file
    private var avAssetWriter : AVAssetWriter? = nil
    /// Backend AVAssetWriterInput for video media
    private var avAssetWriterInputVideo : AVAssetWriterInput? = nil
    /// Backend AVAssetWriterInput for audio media
    private var avAssetWriterInputAudio : AVAssetWriterInput? = nil
    /// Backend AVAssetWriterInput for timecode media
    private var avAssetWriterInputTimecode : AVAssetWriterInput? = nil
    
    /// Processing dispatch queue
    private var processingQueue :DispatchQueue? = nil
    /// Processing dispatch queue label
    private let processingQueueLabel = "writer"
    /// Processing dispatch queue key
    private let processingQueueSpecificKey = DispatchSpecificKey<Void>()
    
    /* ============================================ */
    // MARK: - public init/deinit
    /* ============================================ */
    
    override init() {
        super.init()
        
        // print("Writer.init")
    }
    
    deinit {
        // print("Writer.deinit")
        
        closeSession()
    }
    
    /* ============================================ */
    // MARK: - serial queued public func
    /* ============================================ */
    
    /// Start writing session
    public func openSession() {
        if isRecording {
            closeSession()
        }
        
        // Prepare Processing DispatchQueue
        if processingQueue == nil {
            let queue = DispatchQueue(label:processingQueueLabel)
            queue.setSpecific(key: processingQueueSpecificKey, value: ())
            processingQueue = queue
        }
        
        queueSync {
            isRecording = startRecording()
        }
    }
    
    /// Stop writing session
    public func closeSession() {
        queueSync {
            if isRecording {
                stopRecording()
            }
            
            isRecording = false
        }
    }
    
    /// Append Video SampleBuffer
    public func appendVideoSampleBuffer(sampleBuffer :CMSampleBuffer) {
        queueAsync {
            self.writeVideoSampleBuffer(sampleBuffer)
        }
    }
    
    /// Append Audio SampleBuffer
    public func appendAudioSampleBuffer(sampleBuffer :CMSampleBuffer) {
        queueAsync {
            self.writeAudioSampleBuffer(sampleBuffer)
        }
    }
    
    /// Append Timecode SampleBuffer
    public func appendTimecodeSampleBuffer(sampleBuffer :CMSampleBuffer) {
        queueAsync {
            self.writeTimecodeSampleBuffer(sampleBuffer)
        }
    }
    
    /* ============================================ */
    // MARK: - Internal/Private func
    /* ============================================ */
    
    /// Process block in sync
    ///
    /// - Parameter block: block to process
    private func queueSync(_ block :(()->Void)) {
        guard let queue = processingQueue else { return }
        
        if nil != DispatchQueue.getSpecific(key: processingQueueSpecificKey) {
            block()
        } else {
            queue.sync(execute: block)
        }
    }
    
    /// Process block in async
    ///
    /// - Parameter block: block to process
    private func queueAsync(_ block :@escaping ()->Void) {
        guard let queue = processingQueue else { return }
        
        if nil != DispatchQueue.getSpecific(key: processingQueueSpecificKey) {
            queue.async(execute: block)
            //block()
        } else {
            queue.async(execute: block)
        }
    }
    
    private func startRecording() -> Bool {
        if movieURL == nil {
            var movieFolders : [String]? = nil
            do {
                let moviesPathDirectory = FileManager.SearchPathDirectory.moviesDirectory
                let userDomainMask = FileManager.SearchPathDomainMask.userDomainMask
                movieFolders = NSSearchPathForDirectoriesInDomains(moviesPathDirectory, userDomainMask, true)
            }
            
            if let movieFolder = movieFolders?.first {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMddHHmmss"
                var movieName = formatter.string(from: Date()) + ".mov"
                if let prefix = prefix {
                    movieName = prefix + movieName
                }
                movieURL = URL.init(fileURLWithPath: movieFolder).appendingPathComponent(movieName)
            }
        }
        if let movieURL = movieURL {
            return startRecording(to: movieURL)
        }
        print("ERROR: Invalid movieURL")
        return false
    }
    
    private func startRecording(to url:URL) -> Bool {
        // Remove existing file at URL first
        do {
            let fileManager = FileManager()
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(atPath: url.path)
            }
        } catch {
            print("ERROR: Failed to start recording")
            return false
        }
        
        // unref AVAssetWriter
        avAssetWriterInputTimecode = nil
        avAssetWriterInputVideo = nil
        avAssetWriterInputAudio = nil
        avAssetWriter = nil
        
        // reset TS variables and duration
        initializeTimeStamp()
        
        // Create AVAssetWriter for QuickTime Movie
        avAssetWriter = try? AVAssetWriter.init(outputURL: url, fileType: AVFileType.mov)
        
        if let avAssetWriter = avAssetWriter {
            avAssetWriter.movieTimeScale = sampleTimescale
            
            // Prepare AVAssetWriterInput(s)
            let result = prepareInputMedia()
            if result {
                // Register AVAssetWriterInput(s)
                var videoReady = false
                var audioReady = false
                var timecodeReady = false
                registerInputMedia(&videoReady, &audioReady, &timecodeReady)
                
                if videoReady || audioReady || timecodeReady {
                    let valid = avAssetWriter.startWriting()
                    return valid
                }
            }
        }
        
        print("ERROR: Failed to start recording")
        return false
    }
    
    private func stopRecording() {
        if let avAssetWriter = avAssetWriter {
            // Finish writing
            if let avAssetWriterInputTimeCode = avAssetWriterInputTimecode {
                avAssetWriterInputTimeCode.markAsFinished()
            }
            if let avAssetWriterInputVideo = avAssetWriterInputVideo {
                avAssetWriterInputVideo.markAsFinished()
            }
            if let avAssetWriterInputAudio = avAssetWriterInputAudio {
                avAssetWriterInputAudio.markAsFinished()
            }
            
            if duration > 0.0 {
                avAssetWriter.endSession(atSourceTime: endTime)
            }
            
            let semaphore = DispatchSemaphore(value: 0)
            
            avAssetWriter.finishWriting(completionHandler: { () -> Void in
                //
                if let avAssetWriter = self.avAssetWriter {
                    // Check if completed
                    if avAssetWriter.status != .completed {
                        // In case of faulty state
                        let statusStr = self.descriptionForStatus(avAssetWriter.status)
                        print("ERROR: AVAssetWriter.finishWriting(completionHandler:) = \(statusStr)")
                        print("ERROR: \(avAssetWriter.error as Optional)")
                    }
                    
                    // Finalize TS variables and duration
                    self.finalizeTimeStamp()
                    
                    // unref AVAssetWriter
                    self.avAssetWriterInputTimecode = nil
                    self.avAssetWriterInputVideo = nil
                    self.avAssetWriterInputAudio = nil
                    self.avAssetWriter = nil
                    
                    semaphore.signal()
                }
            })
            semaphore.wait()
        }
    }
    
    /* ============================================ */
    // MARK: -
    /* ============================================ */
    
    private func initializeTimeStamp() {
        objc_sync_enter(self)
        do {
            // reset TS variables and duration
            isInitialTSReady = false
            startTime = CMTime.zero
            endTime = CMTime.zero
            duration = 0.0
        }
        objc_sync_exit(self)
    }
    
    private func updateTimeStamp(_ sampleBuffer: CMSampleBuffer) {
        objc_sync_enter(self)
        do {
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
        objc_sync_exit(self)
    }
    
    private func finalizeTimeStamp() {
        objc_sync_enter(self)
        do {
            // Calc duration and Reset CMTime values
            if isInitialTSReady == true {
                //print("### Reset InitialTS for session")
                duration = CMTimeGetSeconds(CMTimeSubtract(endTime, startTime))
            } else {
                duration = 0.0
            }
            isInitialTSReady = false
            startTime = CMTime.zero
            endTime = CMTime.zero
        }
        objc_sync_exit(self)
    }
    
    /* ============================================ */
    // MARK: -
    /* ============================================ */
    
    private func writeAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if let avAssetWriterInputAudio = avAssetWriterInputAudio {
            if avAssetWriterInputAudio.isReadyForMoreMediaData {
                //
                updateTimeStamp(sampleBuffer)
                let result = avAssetWriterInputAudio.append(sampleBuffer)
                
                if result == false {
                    let statusStr : String = descriptionForStatus(avAssetWriter!.status)
                    print("ERROR: Could not write audio sample buffer.(\(statusStr))")
                    //print("ERROR: \(avAssetWriter!.error)")
                }
            } else {
                //print("ERROR: AVAssetWriterInputAudio is not ready to append.")
            }
        }
    }
    
    private func writeVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if let avAssetWriterInputVideo = avAssetWriterInputVideo {
            if avAssetWriterInputVideo.isReadyForMoreMediaData {
                //
                updateTimeStamp(sampleBuffer)
                let result = avAssetWriterInputVideo.append(sampleBuffer)
                
                if result == false {
                    let statusStr : String = descriptionForStatus(avAssetWriter!.status)
                    print("ERROR: Could not write video sample buffer.(\(statusStr))")
                    //print("ERROR: \(avAssetWriter!.error)")
                }
            } else {
                //print("ERROR: AVAssetWriterInputVideo is not ready to append.")
            }
        }
    }
    
    private func writeTimecodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if let avAssetWriterInputTimeCode = avAssetWriterInputTimecode {
            if avAssetWriterInputTimeCode.isReadyForMoreMediaData {
                //
                updateTimeStamp(sampleBuffer)
                let result = avAssetWriterInputTimeCode.append(sampleBuffer)
                
                if result == false {
                    let statusStr : String = descriptionForStatus(avAssetWriter!.status)
                    print("ERROR: Could not write timecode sample buffer.(\(statusStr))")
                    //print("ERROR: \(avAssetWriter!.error)")
                }
            } else {
                //print("ERROR: AVAssetWriterInputTimecode is not ready to append.")
            }
        }
    }
    
    /* ============================================ */
    // MARK: -
    /* ============================================ */
    
    private func prepareInputMedia() -> Bool {
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
                    print("ERROR: videoOutputSettings is not OK")
                    return false
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
                if avAssetWriter.canApply(outputSettings: audioOutputSettings, forMediaType: AVMediaType.audio) {
                    avAssetWriterInputAudio = AVAssetWriterInput(mediaType: AVMediaType.audio,
                                                                 outputSettings: audioOutputSettings,
                                                                 sourceFormatHint: sourceAudioFormatDescription)
                } else {
                    print("ERROR: audioOutputSettings is not OK")
                    return false
                }
            }
        }
        if useTimecode {
            do {
                // Create AVAssetWriterInput for Timecode (SMPTE)
                avAssetWriterInputTimecode = AVAssetWriterInput(mediaType: AVMediaType.timecode,
                                                                outputSettings: nil)
                
                if let inputVideo = avAssetWriterInputVideo, let inputTimeCode = avAssetWriterInputTimecode {
                    inputVideo.addTrackAssociation(withTrackOf: inputTimeCode,
                                                   type: AVAssetTrack.AssociationType.timecode.rawValue)
                }
            }
            
            // Apply preferred timecode media timescale
            if sampleTimescale > 0, let avAssetWriterInputTimecode = avAssetWriterInputTimecode {
                avAssetWriterInputTimecode.mediaTimeScale = sampleTimescale
            }
        }
        
        return true
    }
    
    private func registerInputMedia(_ videoReady: inout Bool, _ audioReady: inout Bool, _ timecodeReady: inout Bool) {
        if useVideo, let avAssetWriter = avAssetWriter {
            // Register AVAssetWriterInput for Video to AVAssetWriter
            if let avAssetWriterInputVideo = avAssetWriterInputVideo {
                if avAssetWriter.canAdd(avAssetWriterInputVideo) {
                    avAssetWriterInputVideo.expectsMediaDataInRealTime = true
                    avAssetWriter.add(avAssetWriterInputVideo)
                    videoReady = true
                } else {
                    print("ERROR: avAssetWriter.addInput(avAssetWriterInputVideo)")
                }
            }
        }
        if useAudio, let avAssetWriter = avAssetWriter {
            // Register AVAssetWriterInput for Audio to AVAssetWriter
            if let avAssetWriterInputAudio = avAssetWriterInputAudio {
                if avAssetWriter.canAdd(avAssetWriterInputAudio) {
                    avAssetWriterInputAudio.expectsMediaDataInRealTime = true
                    avAssetWriter.add(avAssetWriterInputAudio)
                    audioReady = true
                } else {
                    print("ERROR: avAssetWriter.addInput(avAssetWriterInputAudio)")
                }
            }
        }
        if useTimecode, let avAssetWriter = avAssetWriter {
            // Register AVAssetWriterInput for Timecode to AVAssetWriter
            if let avAssetWriterInputTimeCode = avAssetWriterInputTimecode {
                if avAssetWriter.canAdd(avAssetWriterInputTimeCode) {
                    avAssetWriterInputTimeCode.expectsMediaDataInRealTime = true
                    avAssetWriter.add(avAssetWriterInputTimeCode)
                    timecodeReady = true
                } else {
                    print("ERROR: avAssetWriter.add(avAssetWriterInputTimeCode)")
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
        
        let codecString = videoOutputSettings[AVVideoCodecKey] as! String
        do {
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
        }
        
        #if false
        // For H264 encoder (using Main 3.1 maximum bitrate)
        compressionProperties[AVVideoAverageBitRateKey] = 14*1000*1000
        compressionProperties[AVVideoMaxKeyFrameIntervalKey] = 29
        compressionProperties[AVVideoMaxKeyFrameIntervalDurationKey] = 1.0
        compressionProperties[AVVideoAllowFrameReorderingKey] = true
        compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264Main31
        compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        compressionProperties[AVVideoExpectedSourceFrameRateKey] = 30
        compressionProperties[AVVideoAverageNonDroppableFrameRateKey] = 10
        #endif
        
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
        
        // Use specified audio codec and bitrate
        // Keep SampleRate/ChannelCount/ChannelLayout from CMFormatDescription of source audio
        if let sourceAudioFormatDescription = sourceAudioFormatDescription {
            var avaf : AVAudioFormat? = nil
            var aclData : NSData? = nil
            do {
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
            }
            
            if let avaf = avaf {
                audioOutputSettings[AVFormatIDKey] = Int(encodeAudioFormatID)
                audioOutputSettings[AVSampleRateKey] = Float(avaf.sampleRate)
                audioOutputSettings[AVNumberOfChannelsKey] = Int(avaf.channelCount)
                if encodeAudioBitrate > 0 {
                    audioOutputSettings[AVEncoderBitRateKey] = Int(encodeAudioBitrate)
                    audioOutputSettings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
                }
                if let aclData = aclData {
                    audioOutputSettings[AVChannelLayoutKey] = aclData
                }
            }
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
        
        #if false
        // Clipping for kAudioFormatMPEG4AAC
        if (audioOutputSettings[AVSampleRateKey] as! Float) > 48000.0 {
            // kAudioFormatMPEG4AAC runs up to 48KHz
            audioOutputSettings[AVSampleRateKey] = 48000
        }
        if (audioOutputSettings[AVEncoderBitRateKey] as! Int) > 320*1024 {
            // kAudioFormatMPEG4AAC runs up to 320Kbps
            audioOutputSettings[AVSampleRateKey] = 320*1024
        }
        #endif
        
        return audioOutputSettings
    }
    
    /* ============================================ */
    // MARK: -
    /* ============================================ */
    
    private func descriptionForStatus(_ status :AVAssetWriter.Status) -> String {
        // In case of faulty state
        let statusArray : [AVAssetWriter.Status : String] = [
            .unknown    : "AVAssetWriterStatus.Unknown",
            .writing    : "AVAssetWriterStatus.Writing",
            .completed  : "AVAssetWriterStatus.Completed",
            .failed     : "AVAssetWriterStatus.Failed",
            .cancelled  : "AVAssetWriterStatus.Cancelled"
        ]
        let statusStr :String = statusArray[status]!
        
        return statusStr
    }
    
    private func fourCharString(_ type :OSType) -> String {
        let c1 : UInt32 = (type >> 24) & 0xFF
        let c2 : UInt32 = (type >> 16) & 0xFF
        let c3 : UInt32 = (type >>  8) & 0xFF
        let c4 : UInt32 = (type      ) & 0xFF
        let bytes: [CChar] = [
            CChar( c1 == 0x00 ? 0x20 : c1),
            CChar( c2 == 0x00 ? 0x20 : c2),
            CChar( c3 == 0x00 ? 0x20 : c3),
            CChar( c4 == 0x00 ? 0x20 : c4),
            CChar(0x00)
        ]
        
        return String(cString: bytes)
    }
}
