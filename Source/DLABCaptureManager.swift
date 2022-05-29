//
//  DLABCaptureManager.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2017/10/09.
//  Copyright © 2017-2022 MyCometG3. All rights reserved.
//

import Cocoa
import DLABridging

/// Specify preferred timecodeSource.
public enum TimecodeType :Int {
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

public class DLABCaptureManager: NSObject, DLABInputCaptureDelegate {
    /* ============================================ */
    // MARK: - properties - Capturing
    /* ============================================ */
    
    /// True while capture is running
    public private(set) var running :Bool = false
    
    /// Capture device as DLABDevice object
    public var currentDevice :DLABDevice? = nil
    
    /* ============================================ */
    // MARK: - properties - Capturing audio
    /* ============================================ */
    
    /// Capture audio bit depth (See DLABConstants.h)
    public var audioDepth :DLABAudioSampleType = .type16bitInteger
    
    /// Capture audio channels. 2 for Stereo. 8 or 16 for discrete.
    ///
    /// Set 0 to disable audioCapture and audioPreview.
    public var audioChannels :UInt32 = 2
    
    /// Capture audio bit rate (See DLABConstants.h)
    public var audioRate :DLABAudioSampleRate = .rate48kHz
    
    /// Audio Input Connection
    public var audioConnection :DLABAudioConnection = .init()
    
    /// Volume of audio preview
    public var volume :Float = 1.0 {
        didSet {
            volume = max(0.0, min(1.0, volume))
            
            if let audioPreview = audioPreview {
                audioPreview.volume = Float32(volume)
            }
        }
    }
    
    /// True while audio capture is enabled
    public private(set) var audioCaptureEnabled :Bool = false
    
    /// AudioPreview object
    private var audioPreview :CaptureAudioPreview? = nil
    
    /* ============================================ */
    // MARK: - properties - Capturing video
    /* ============================================ */
    
    /// Capture video DLABDisplayMode. (See DLABConstants.h)
    public var displayMode :DLABDisplayMode = .modeNTSC
    
    /// Capture video pixelFormat (See DLABConstants.h)
    public var pixelFormat :DLABPixelFormat = .format8BitYUV
    
    /// Override specific CoreVideoPixelFormat (with conversion)
    ///
    /// Set 0 to use Default CVPixelFormat
    public var cvPixelFormat : OSType = 0
    
    /// Capture video DLABVideoInputFlag (See DLABConstants.h)
    public var inputFlag :DLABVideoInputFlag = []
    
    /// Video Input Connection
    public var videoConnection :DLABVideoConnection = .init()
    
    /// True while video capture is enabled
    public private(set) var videoCaptureEnabled :Bool = false
    
    /// Set CaptureVideoPreview view here - based on AVSampleBufferDisplayLayer
    public weak var videoPreview :CaptureVideoPreview? = nil
    
    /// Parent NSView for video preview - based on CreateCocoaScreenPreview()
    public weak var parentView :NSView? = nil {
        didSet {
            guard let device = currentDevice else { return }
            do {
                if let parentView = parentView {
                    try device.setInputScreenPreviewTo(parentView)
                } else {
                    try device.setInputScreenPreviewTo(nil)
                }
            } catch let error as NSError {
                print("ERROR:\(error.domain)(\(error.code)): \(error.localizedFailureReason ?? "unknown reason")")
            }
        }
    }
    
    /* ============================================ */
    // MARK: - properties - Recording
    /* ============================================ */
    
    /// True while recording
    public private(set) var recording :Bool = false
    
    /// Writer object for recording
    private var writer :CaptureWriter? = nil
    
    /// Optional. Set preferred output URL.
    public var movieURL : URL? = nil
    
    /// Optional. Auto-generated movide name prefix.
    public var prefix : String? = "DL-"
    
    /// Optional. Set preferred timeScale for video/timecode. 0 for default value.
    public var sampleTimescale :CMTimeScale = 0
    
    /// Duration in sec of last recording
    private var lastDuration :Float64 = 0.0
    
    /// Duration in sec of recording
    public var duration :Float64 {
        if let writer = writer {
            return writer.duration
        } else {
            return lastDuration
        }
    }
    
    /* ============================================ */
    // MARK: - properties - Recording audio
    /* ============================================ */
    
    /// Set YES to encode audio in AAC. No to use LPCM.
    public var encodeAudio :Bool = false
    
    /// Set audioFormatID as kAudioFormatXXXX.
    public var encodeAudioFormatID : AudioFormatID = kAudioFormatMPEG4AAC
    
    /// Set encoded audio target bitrate. Default is 256 * 1024 bps.
    /// Recommends AAC-LC:64k~/ch, HE-AAC:24k~/ch, HE-AACv2: 12k~/ch.
    public var encodeAudioBitrate :UInt = 256*1024
    
    /// Optional: customise audio encode settings of AVAssetWriterInput.
    public var updateAudioSettings : (([String:Any]) -> [String:Any])? = nil
    
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
    public var updateVideoSettings : (([String:Any]) -> [String:Any])? = nil
    
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
        
        // print("DLABCaptureManager.init")
    }
    
    deinit {
        // print("DLABCaptureManager.deinit")
        
        captureStop()
    }
    
    /* ============================================ */
    // MARK: - public method
    /* ============================================ */
    
    /// Start Capture session
    public func captureStart() {
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
                        try device.setInputScreenPreviewTo(parentView)
                    }
                    if let videoPreview = videoPreview {
                        videoPreview.prepare()
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
            } catch let error as NSError {
                print("ERROR:\(error.domain)(\(error.code)): \(error.localizedFailureReason ?? "unknown reason")")
            }
        }
    }
    
    /// Stop capture session
    public func captureStop() {
        if let device = currentDevice, running == true {
            if recording {
                recordToggle()
            }
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
                    videoPreview.shutdown()
                }
                if let _ = parentView {
                    try device.setInputScreenPreviewTo(nil)
                }
                if let audioPreview = audioPreview {
                    try audioPreview.aqStop()
                    try audioPreview.aqDispose()
                    self.audioPreview = nil
                }
            } catch let error as NSError {
                print("ERROR:\(error.domain)(\(error.code)): \(error.localizedFailureReason ?? "unknown reason")")
            }
            
            do {
                // support for timecode
                timecodeReady = false
                timecodeHelper = nil
            }
        }
    }
    
    /// Toggle recording using current session
    public func recordToggle() {
        if running {
            if let writer = writer {
                // stop recording
                writer.closeSession()
                
                // keep last duration
                lastDuration = writer.duration
                
                // unref writer
                self.writer = nil
                
                if recording {
                    recording = false
                    // print("NOTICE: Recording stopped")
                }
            } else {
                // support for timecode
                prepTimecodeHelper()
                
                // Update inputVideoSetting
                applyTimecodeSetting()
                
                // prepare writer
                writer = CaptureWriter()
                
                // start recording
                if let writer = writer {
                    writer.movieURL = movieURL
                    writer.prefix = prefix
                    writer.sampleTimescale = (sampleTimescale > 0 ? sampleTimescale : calcTimescale())
                    
                    writer.encodeAudio = encodeAudio
                    writer.encodeAudioFormatID = encodeAudioFormatID
                    writer.encodeAudioBitrate = encodeAudioBitrate
                    writer.updateAudioSettings = updateAudioSettings
                    
                    writer.videoStyle = videoStyle
                    writer.clapHOffset = Int(offset.x)
                    writer.clapVOffset = Int(offset.y)
                    writer.encodeVideo = encodeVideo
                    writer.encodeVideoBitrate = encodeVideoBitrate
                    writer.encodeVideoFrameRate = calcFPS()
                    writer.encodeProRes422 = encodeProRes422
                    writer.encodeVideoCodecType = encodeVideoCodecType
                    writer.fieldDetail = fieldDetail
                    writer.updateVideoSettings = updateVideoSettings
                    
                    writer.useTimecode = timecodeReady
                    
                    writer.sourceVideoFormatDescription =
                        currentDevice?.inputVideoSetting?.videoFormatDescription
                    writer.sourceAudioFormatDescription =
                        currentDevice?.inputAudioSetting?.audioFormatDescription
                    writer.openSession()
                    
                    if writer.isRecording {
                        recording = true
                        // print("NOTICE: Recording started")
                    } else {
                        print("ERROR: Failed to start recording")
                    }
                } else {
                    print("ERROR: Writer is not available")
                }
            }
        } else {
            print("ERROR: device is not ready")
        }
    }
    
    /* ============================================ */
    // MARK: - private method
    /* ============================================ */
    
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
    
    /* ============================================ */
    // MARK: - callback
    /* ============================================ */
    
    /// Callback method implementation - DLABInputCaptureDelegate
    /// - Parameters:
    ///   - sampleBuffer: CMSampleBuffer
    ///   - sender: DLABDevice
    public func processCapturedAudioSample(_ sampleBuffer: CMSampleBuffer,
                                           of sender:DLABDevice) {
        if let writer = writer {
            writer.appendAudioSampleBuffer(sampleBuffer: sampleBuffer)
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
    
    /// Callback method implementation - DLABInputCaptureDelegate
    /// - Parameters:
    ///   - sampleBuffer: CMSampleBuffer
    ///   - sender: DLABDevice
    public func processCapturedVideoSample(_ sampleBuffer: CMSampleBuffer,
                                           of sender:DLABDevice) {
        if let writer = writer {
            writer.appendVideoSampleBuffer(sampleBuffer: sampleBuffer)
        }
        
        if let videoPreview = videoPreview {
            videoPreview.queueSampleBuffer(sampleBuffer)
        }
        
        // support for core_audio_smpte_time
        if let timecodeSource = timecodeSource, timecodeSource == .CoreAudio, let timecodeHelper = timecodeHelper {
            let timecodeSampleBuffer = timecodeHelper.createTimeCodeSample(from: sampleBuffer)
            if let timecodeSampleBuffer = timecodeSampleBuffer {
                if let writer = writer {
                    writer.appendTimecodeSampleBuffer(sampleBuffer: timecodeSampleBuffer)
                }
                
                // source provides timecode
                if timecodeReady == false {
                    timecodeReady = true
                    print("NOTICE: timecodeReady : core_audio_smpte_time")
                }
            }
        }
    }
    
    /// Callback method implementation - DLABInputCaptureDelegate
    /// - Parameters:
    ///   - sampleBuffer: CMSampleBuffer
    ///   - setting: DLABTimecodeSetting
    ///   - sender: DLABDevice
    public func processCapturedVideoSample(_ sampleBuffer: CMSampleBuffer,
                                           timecodeSetting setting: DLABTimecodeSetting,
                                           of sender:DLABDevice) {
        if let writer = writer {
            writer.appendVideoSampleBuffer(sampleBuffer: sampleBuffer)
        }
        
        if let videoPreview = videoPreview {
            videoPreview.queueSampleBuffer(sampleBuffer)
        }
        
        // support for Device timecode
        if let timecodeSource = timecodeSource, timecodeSource.byDevice() {
            let timecodeSampleBuffer = setting.createTimecodeSample(in: timecodeFormatType,
                                                                    videoSample: sampleBuffer)
            if let timecodeSampleBuffer = timecodeSampleBuffer {
                if let writer = writer {
                    writer.appendTimecodeSampleBuffer(sampleBuffer: timecodeSampleBuffer)
                }
                
                // source provides timecode
                if timecodeReady == false {
                    timecodeReady = true
                    print("NOTICE: timecodeReady : \(timecodeSource)")
                }
            }
        }
    }
    
    /* ============================================ */
    // MARK: - public utility
    /* ============================================ */
    
    /// Select first DeckLink Device for Capture
    /// - Returns: DLABDevice
    public func findFirstDevice() -> DLABDevice? {
        if currentDevice == nil {
            let deviceArray = deviceList()
            if let deviceArray = deviceArray, deviceArray.count > 0 {
                currentDevice = deviceArray.first!
            }
        }
        return currentDevice
    }
    
    /// Detected DeckLink Devices
    /// - Returns: Array of DLABDevice
    public func deviceList() -> [DLABDevice]? {
        let browser = DLABBrowser()
        _ = browser.registerDevicesForInput()
        let devciceList = browser.allDevices
        return devciceList
    }
    
    /// Supported Input VideoSettings for DLABDevice
    /// - Parameter device: DLABDevice
    /// - Returns: Array of DLABVideoSetting
    public func inputVideoSettingList(device :DLABDevice) -> [DLABVideoSetting]? {
        let settingList = device.inputVideoSettingArray
        return settingList
    }
    
    /// Supported Output VideoSettings for DLABDevice
    /// - Parameter device: DLABDevice
    /// - Returns: Array of DLABVideoSetting
    public func outputVideoSettingList(device :DLABDevice) -> [DLABVideoSetting]? {
        let settingList = device.outputVideoSettingArray
        return settingList
    }
    
    /// Dictionary of DLABDeviceInfo
    /// - Parameter device: DLABDevice
    /// - Returns: Dictionary
    public func deviceInfo(device :DLABDevice) -> [String:Any] {
        var info :[String:Any] = [:]
        do {
            info["modelName"] = device.modelName // NSString* -> String
            info["displayName"] = device.displayName // NSString* -> String
            info["persistentID"] = device.persistentID // int64_t -> Int64
            info["deviceGroupID"] = device.deviceGroupID // int64_t -> Int64
            info["topologicalID"] = device.topologicalID // int64_t -> Int64
            info["numberOfSubDevices"] = device.numberOfSubDevices // int64_t -> Int64
            info["subDeviceIndex"] = device.subDeviceIndex // int64_t -> Int64
            info["profileID"] = device.profileID // int64_t -> Int64
            info["duplex"] = device.duplex // int64_t -> Int64
            info["supportFlag"] = device.supportFlag // uint32_t -> UInt32
            info["supportCapture"] = device.supportCapture // BOOL
            info["supportPlayback"] = device.supportPlayback // BOOL
            info["supportKeying"] = device.supportKeying // BOOL
            info["supportInputFormatDetection"] = device.supportInputFormatDetection // BOOL
            info["supportHDRMetadata"] = device.supportHDRMetadata // BOOL
        }
        return info
    }
    
    /// Dictionary of AudioSettingInfo
    /// - Parameter setting: DLABAudioSetting
    /// - Returns: Dictionary
    public func audioSettingInfo(setting :DLABAudioSetting) -> [String:Any] {
        var info :[String:Any] = [:]
        do {
            info["sampleSize"] = setting.sampleSize // uint32_t -> UInt32
            info["channelCount"] = setting.channelCount // uint32_t -> UInt32
            info["sampleType"] = setting.sampleType // uint32_t -> UInt32
            info["sampleRate"] = setting.sampleRate // uint32_t -> UInt32
            
            info["audioFormatDescription"] = setting.audioFormatDescription.debugDescription // String
        }
        return info
    }
    
    /// Dictionary of VideoSettingInfo
    /// - Parameter setting: DLABVideoSetting
    /// - Returns: Dictionary
    public func videoSettingInfo(setting :DLABVideoSetting) -> [String:Any] {
        var info :[String:Any] = [:]
        do {
            info["name"] = setting.name // NSString* -> String
            info["width"] = setting.width // long -> int64_t -> Int64
            info["height"] = setting.height // long -> int64_t -> Int64
            
            info["duration"] = setting.duration // int64_t -> Int64
            info["timeScale"] = setting.timeScale // int64_t -> Int64
            info["displayMode"] = NSFileTypeForHFSTypeCode(setting.displayMode.rawValue) // Sting
            info["fieldDominance"] = NSFileTypeForHFSTypeCode(setting.fieldDominance.rawValue) // String
            info["displayModeFlag"] = setting.displayModeFlag.rawValue // uint32_t -> UInt32
            info["isHD"] = setting.isHD // BOOL
            info["useSERIAL"] = setting.useSERIAL // BOOL
            info["useVITC"] = setting.useVITC // BOOL
            info["useRP188"] = setting.useRP188 // BOOL
            
            info["pixelFormat"] = NSFileTypeForHFSTypeCode(setting.pixelFormat.rawValue) // uint32_t -> UInt32
            info["inputFlag"] = setting.inputFlag.rawValue // uint32_t -> UInt32
            info["outputFlag"] = setting.outputFlag.rawValue // uint32_t -> UInt32
            info["rowBytes"] = setting.rowBytes // long -> int64_t -> Int64
            info["videoFormatDescription"] = setting.videoFormatDescription.debugDescription // String
            
            info["cvPixelFormatType"] = setting.cvPixelFormatType; // UInt32
            info["cvRowBytes"]  = setting.cvRowBytes; // size_t -> Int -> Int64
        }
        return info
    }
    
    /// Native Timescale for DisplayMode
    /// - Parameter targetDisplayMode: DLABDisplayMode
    /// - Returns: CMTimeScale
    public func nativeTimescaleFor(_ targetDisplayMode:DLABDisplayMode) -> CMTimeScale? {
        let mode2scale :[DLABDisplayMode:CMTimeScale] = [
            .modeNTSC           :30000,
            .modeNTSC2398       :24000,
            .modeNTSCp          :60000,
            .modePAL            :25000,
            .modePALp           :50000,
            
            .modeHD720p50       :50000,
            .modeHD720p5994     :60000,
            .modeHD720p60       :60000,
            
            .modeHD1080p2398    :24000,
            .modeHD1080p24      :24000,
            
            .modeHD1080p25      :25000,
            .modeHD1080p2997    :30000,
            .modeHD1080p30      :30000,
            
            .modeHD1080p4795    :48000,
            .modeHD1080p48      :48000,
            
            .modeHD1080i50      :25000,
            .modeHD1080i5994    :30000,
            .modeHD1080i6000    :30000,
            
            .modeHD1080p50      :50000,
            .modeHD1080p5994    :60000,
            .modeHD1080p6000    :60000,
            
            .modeHD1080p9590    :96000,
            .modeHD1080p96      :96000,
            .modeHD1080p100     :100000,
            .modeHD1080p11988   :120000,
            .modeHD1080p120     :120000,
            
            .mode2k2398         :24000,
            .mode2k24           :24000,
            .mode2k25           :25000,
            
            .mode2kDCI2398      :24000,
            .mode2kDCI24        :24000,
            .mode2kDCI25        :25000,
            .mode2kDCI2997      :30000,
            .mode2kDCI30        :30000,
            .mode2kDCI4795      :48000,
            .mode2kDCI48        :48000,
            .mode2kDCI50        :50000,
            .mode2kDCI5994      :60000,
            .mode2kDCI60        :60000,
            .mode2kDCI9590      :96000,
            .mode2kDCI96        :96000,
            .mode2kDCI100       :100000,
            .mode2kDCI11988     :120000,
            .mode2kDCI120       :120000,
            
            .mode4K2160p2398    :24000,
            .mode4K2160p24      :24000,
            .mode4K2160p25      :25000,
            .mode4K2160p2997    :30000,
            .mode4K2160p30      :30000,
            .mode4K2160p4795    :48000,
            .mode4K2160p48      :48000,
            .mode4K2160p50      :50000,
            .mode4K2160p5994    :60000,
            .mode4K2160p60      :60000,
            .mode4K2160p9590    :96000,
            .mode4K2160p96      :96000,
            .mode4K2160p100     :100000,
            .mode4K2160p11988   :120000,
            .mode4K2160p120     :120000,
            
            .mode4kDCI2398      :24000,
            .mode4kDCI24        :24000,
            .mode4kDCI25        :25000,
            .mode4kDCI2997      :30000,
            .mode4kDCI30        :30000,
            .mode4kDCI4795      :48000,
            .mode4kDCI48        :48000,
            .mode4kDCI50        :50000,
            .mode4kDCI5994      :60000,
            .mode4kDCI60        :60000,
            .mode4kDCI9590      :96000,
            .mode4kDCI96        :96000,
            .mode4kDCI100       :100000,
            .mode4kDCI11988     :120000,
            .mode4kDCI120       :120000,
            
            // TODO .mode8K...
        ]
        
        if let timeScale = mode2scale[targetDisplayMode] {
            return timeScale
        }
        return nil
    }
    
    /// Native video frame rate for DisplayMode
    /// - Parameter targetDisplayMode: DLABDisplayMode
    /// - Returns: FPS in Float
    public func nativeFPSFor(_ targetDisplayMode:DLABDisplayMode) -> Float? {
        let mode2fps :[DLABDisplayMode:Float] = [
            .modeNTSC           :30.0/1.001,
            .modeNTSC2398       :30.0/1.001,
            .modeNTSCp          :60.0/1.001,
            .modePAL            :25.0,
            .modePALp           :50.0,
            
            .modeHD720p50       :50.0,
            .modeHD720p5994     :60.0/1.001,
            .modeHD720p60       :60.0,
            
            .modeHD1080p2398    :24.0/1.001,
            .modeHD1080p24      :24.0,
            
            .modeHD1080p25      :25.0,
            .modeHD1080p2997    :30.0/1.001,
            .modeHD1080p30      :30.0,
            
            .modeHD1080p4795    :48.0/1.001,
            .modeHD1080p48      :48.0,
            
            .modeHD1080i50      :25.0,
            .modeHD1080i5994    :30.0/1.001,
            .modeHD1080i6000    :30.0,
            
            .modeHD1080p50      :50.0,
            .modeHD1080p5994    :60.0/1.001,
            .modeHD1080p6000    :60.0,
            
            .modeHD1080p9590    :96.0/1.001,
            .modeHD1080p96      :96.0,
            .modeHD1080p100     :100.0,
            .modeHD1080p11988   :120.0/1.001,
            .modeHD1080p120     :120.0,
            
            .mode2k2398         :24.0/1.001,
            .mode2k24           :24.0,
            .mode2k25           :25.0,
            
            .mode2kDCI2398      :24.0/1.001,
            .mode2kDCI24        :24.0,
            .mode2kDCI25        :25.0,
            .mode2kDCI2997      :30.0/1.001,
            .mode2kDCI30        :30.0,
            .mode2kDCI4795      :48.0/1.001,
            .mode2kDCI48        :48.0,
            .mode2kDCI50        :50.0,
            .mode2kDCI5994      :60.0/1.001,
            .mode2kDCI60        :60.0,
            .mode2kDCI9590      :96.0/1.001,
            .mode2kDCI96        :96.0,
            .mode2kDCI100       :100.0,
            .mode2kDCI11988     :120.0/1.001,
            .mode2kDCI120       :120.0,
            
            .mode4K2160p2398    :24.0/1.001,
            .mode4K2160p24      :24.0,
            .mode4K2160p25      :25.0,
            .mode4K2160p2997    :30.0/1.001,
            .mode4K2160p30      :30.0,
            .mode4K2160p4795    :48.0/1.001,
            .mode4K2160p48      :48.0,
            .mode4K2160p50      :50.0,
            .mode4K2160p5994    :60.0/1.001,
            .mode4K2160p60      :60.0,
            .mode4K2160p9590    :96.0/1.001,
            .mode4K2160p96      :96.0,
            .mode4K2160p100     :100.0,
            .mode4K2160p11988   :120.0/1.001,
            .mode4K2160p120     :120.0,
            
            .mode4kDCI2398      :24.0/1.001,
            .mode4kDCI24        :24.0,
            .mode4kDCI25        :25.0,
            .mode4kDCI2997      :30.0/1.001,
            .mode4kDCI30        :30.0,
            .mode4kDCI4795      :48.0/1.001,
            .mode4kDCI48        :48.0,
            .mode4kDCI50        :50.0,
            .mode4kDCI5994      :60.0/1.001,
            .mode4kDCI60        :60.0,
            .mode4kDCI9590      :96.0/1.001,
            .mode4kDCI96        :96.0,
            .mode4kDCI100       :100.0,
            .mode4kDCI11988     :120.0/1.001,
            .mode4kDCI120       :120.0,
            
            // TODO .mode8K...
        ]
        
        if let fps = mode2fps[targetDisplayMode] {
            return fps
        }
        return nil
    }
    
    /// Supported DLABDisplayMode list
    /// - Returns:array of DLABDisplayMode
    public func displayModeList() -> [DLABDisplayMode] {
        // limited to: NTSC, PAL, HD1080, HD720
        // Same order as in DeckLinkAPIModes.h
        let list:[DLABDisplayMode] = [
            // SD Modes
            .modeNTSC, .modeNTSC2398, .modePAL, .modeNTSCp, .modePALp,
            // HD 1080 Modes
            .modeHD1080p2398, .modeHD1080p24, .modeHD1080p25, .modeHD1080p2997, .modeHD1080p30,
            .modeHD1080p4795, .modeHD1080p48, .modeHD1080p50, .modeHD1080p5994, .modeHD1080p6000,
            .modeHD1080p9590, .modeHD1080p96, .modeHD1080p100, .modeHD1080p11988, .modeHD1080p120,
            .modeHD1080i50, .modeHD1080i5994, .modeHD1080i6000,
            // HD 720 Modes
            .modeHD720p50, .modeHD720p5994, .modeHD720p60,
            // 2k 2048x1556 Modes
            .mode2k2398, .mode2k24, .mode2k25,
            // 2k DCI 2048x1080 Modes
            .mode2kDCI2398, .mode2kDCI24, .mode2kDCI25, .mode2kDCI2997, .mode2kDCI30,
            .mode2kDCI4795, .mode2kDCI48, .mode2kDCI50, .mode2kDCI5994, .mode2kDCI60,
            .mode2kDCI9590, .mode2kDCI96, .mode2kDCI100, .mode2kDCI11988, .mode2kDCI120,
            // 4k UHD 3840x2160 Modes
            .mode4K2160p2398, .mode4K2160p24, .mode4K2160p25, .mode4K2160p2997, .mode4K2160p30,
            .mode4K2160p4795, .mode4K2160p48, .mode4K2160p50, .mode4K2160p5994, .mode4K2160p60,
            .mode4K2160p9590, .mode4K2160p96, .mode4K2160p100, .mode4K2160p11988, .mode4K2160p120,
            // 4k DCI 4096x2160 Modes
            .mode4kDCI2398, .mode4kDCI24, .mode4kDCI25, .mode4kDCI2997, .mode4kDCI30,
            .mode4kDCI4795, .mode4kDCI48, .mode4kDCI50, .mode4kDCI5994, .mode4kDCI60,
            .mode4kDCI9590, .mode4kDCI96, .mode4kDCI100, .mode4kDCI11988, .mode4kDCI120,
            // TODO .mode8K...
        ]
        return list
    }
    
    /// Supported VideoStyle for pixelSize
    /// - Parameter size: NSSize
    /// - Returns: array of VideoStyle
    public func videoStyleListOf(_ size:NSSize) -> [VideoStyle]? {
        var list:[VideoStyle] = [];
        
        // DCI 4k
        if NSEqualSizes(size, NSSize(width: 4096, height: 2160)) {
            list = [.DCI4k_4096_2160_Full,
                    .DCI4k_4096_2160_239, .DCI4k_4096_2160_185]
        }
        
        // UHD 4k
        if NSEqualSizes(size, NSSize(width: 3840, height: 2160)) {
            list = [.UHD4k_3840_2160_Full]
        }
        
        // CAM 2k
        if NSEqualSizes(size, NSSize(width: 2048, height: 1556)) {
            list = [.CAM2k_2048_1556_Full,
                    .CAM2k_2048_1556_239, .CAM2k_2048_1556_235,
                    .CAM2k_2048_1556_185, .CAM2k_2048_1556_178]
        }
        // DCI 2k
        if NSEqualSizes(size, NSSize(width: 2048, height: 1080)) {
            list = [.DCI2k_2048_1080_Full,
                    .DCI2k_2048_1080_239, .DCI2k_2048_1080_185]
        }
        
        // HD-1080
        if NSEqualSizes(size, NSSize(width: 1920, height: 1080)) {
            list = [.HD_1920_1080_Full, .HD_1920_1080_16_9]
        }
        if NSEqualSizes(size, NSSize(width: 1440, height: 1080)) {
            list = [.HDV_HDCAM]
        }
        // HD-720
        if NSEqualSizes(size, NSSize(width: 1280, height: 720)) {
            list = [.HD_1280_720_Full, .HD_1280_720_16_9]
        }
        // SD-625/576
        if NSEqualSizes(size, NSSize(width: 720, height: 576)) {
            list = [.SD_720_576_16_9, .SD_720_576_4_3,
                    .SD_625_13_5MHz_16_9, .SD_625_13_5MHz_4_3]
        }
        if NSEqualSizes(size, NSSize(width: 768, height: 576)) {
            list = [.SD_768_576_Full]
        }
        // SD-525/486
        if NSEqualSizes(size, NSSize(width: 720, height: 486)) {
            list = [.SD_720_486_16_9, .SD_720_486_4_3,
                    .SD_525_13_5MHz_16_9, .SD_525_13_5MHz_4_3]
        }
        if NSEqualSizes(size, NSSize(width: 640, height: 486)) {
            list = [.SD_640_486_Full]
        }
        // SD-525/480
        if NSEqualSizes(size, NSSize(width: 720, height: 480)) {
            list = [.SD_720_480_16_9, .SD_720_480_4_3]
        }
        if NSEqualSizes(size, NSSize(width: 640, height: 480)) {
            list = [.SD_640_480_Full]
        }
        
        return (list.count > 0 ? list : nil)
    }
}
