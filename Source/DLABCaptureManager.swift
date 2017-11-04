//
//  DLABCaptureManager.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2017/10/09.
//  Copyright © 2017年 MyCometG3. All rights reserved.
//

import Cocoa
import DLABridging

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
    
    /// Capture audio channels
    public var audioChannels :UInt32 = 2
    
    /// Capture audio bit rate (See DLABConstants.h)
    public var audioRate :DLABAudioSampleRate = .rate48kHz
    
    /// Volume of audio preview (NOT IMPLEMENTED YET)
    public var volume :Float = 1.0 {
        didSet {
            volume = max(0.0, min(1.0, volume))
            
            if let audioPreview = audioPreview {
                audioPreview.volume = Float32(volume)
            }
        }
    }
    
    /* ============================================ */
    // MARK: - properties - Capturing video
    /* ============================================ */
    
    /// Capture video DLABDisplayMode. (See DLABConstants.h)
    public var displayMode :DLABDisplayMode = .modeNTSC
    
    /// Capture video pixelFormat (See DLABConstants.h)
    public var pixelFormat :DLABPixelFormat = .format8BitYUV
    
    /// Capture video DLABVideoInputFlag (See DLABConstants.h)
    public var inputFlag :DLABVideoInputFlag = []
    
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
    
    /// Set CaptureVideoPreview view here - based on AVSampleBufferDisplayLayer
    public weak var videoPreview :CaptureVideoPreview? = nil
    
    /// AudioPreview object
    private var audioPreview :CaptureAudioPreview? = nil
    
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
    
    /// Set encoded audio target bitrate. Default is 256 * 1024 bps.
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
    
    /// Set true to use timecode VANC
    public var supportTimecodeVANC :Bool = true
    
    /// Set true to use timecode CoreAudio
    public var supportTimecodeCoreAudio :Bool = true
    
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
    // MARK: - private method
    /* ============================================ */
    
    public func captureStart() {
        if currentDevice == nil {
            _ = findFirstDevice()
        }
        
        if let device = currentDevice, running == false {
            // support for timecode
            timecodeReady = false
            prepTimecodeHelper()
            
            do {
                if let parentView = parentView {
                    try device.setInputScreenPreviewTo(parentView)
                }
                
                if let videoPreview = videoPreview {
                    videoPreview.prepare()
                }
                
                var displayModeSupportFlag:DLABDisplayModeSupportFlag = .notSupported
                var vSetting:DLABVideoSetting? = nil
                var aSetting:DLABAudioSetting? = nil
                try vSetting = device.createInputVideoSetting(of: displayMode,
                                                              pixelFormat: pixelFormat,
                                                              inputFlag: inputFlag,
                                                              supportedAs: &displayModeSupportFlag)
                try aSetting = device.createInputAudioSetting(of: audioDepth,
                                                              channelCount: audioChannels,
                                                              sampleRate: audioRate)
                
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
                
                if let vSetting = vSetting, let aSetting = aSetting, displayModeSupportFlag != .notSupported {
                    if let audioFormatDescription = aSetting.audioFormatDescription {
                        audioPreview = CaptureAudioPreview(audioFormatDescription)
                        if let audioPreview = audioPreview {
                            audioPreview.volume = Float32(volume)
                        }
                    }
                    
                    device.inputDelegate = self
                    try device.enableVideoInput(with: vSetting)
                    try device.enableAudioInput(with: aSetting)
                    try device.startStreams()
                    
                    running = true
                }
            } catch let error as NSError {
                print("ERROR:\(error.domain)(\(error.code)): \(error.localizedFailureReason ?? "unknown reason")")
            }
        }
    }
    
    public func captureStop() {
        if let device = currentDevice {
            do {
                if running {
                    try device.stopStreams()
                    try device.disableVideoInput()
                    try device.disableAudioInput()
                    device.inputDelegate = nil
                    
                    if let videoPreview = videoPreview {
                        videoPreview.shutdown()
                    }
                    
                    if let _ = parentView {
                        try device.setInputScreenPreviewTo(nil)
                    }
                    
                    if let audioPreview = audioPreview {
                        try audioPreview.aqDispose()
                        self.audioPreview = nil
                    }
                }
            } catch let error as NSError {
                print("ERROR:\(error.domain)(\(error.code)): \(error.localizedFailureReason ?? "unknown reason")")
            }
            
            running = false
            currentDevice = nil
            
            // support for timecode
            timecodeReady = false
            timecodeHelper = nil
        }
    }
    
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
                
                // prepare writer
                writer = CaptureWriter()
                
                // start recording
                if let writer = writer {
                    writer.movieURL = movieURL
                    writer.prefix = prefix
                    writer.sampleTimescale = sampleTimescale
                    
                    writer.encodeAudio = encodeAudio
                    writer.encodeAudioBitrate = encodeAudioBitrate
                    writer.updateAudioSettings = updateAudioSettings
                    
                    writer.videoStyle = videoStyle
                    writer.clapHOffset = Int(offset.x)
                    writer.clapVOffset = Int(offset.y)
                    writer.encodeVideo = encodeVideo
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
    // MARK: - callback
    /* ============================================ */
    
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
    
    public func processCapturedVideoSample(_ sampleBuffer: CMSampleBuffer,
                                           of sender:DLABDevice) {
        if let writer = writer {
            writer.appendVideoSampleBuffer(sampleBuffer: sampleBuffer)
        }
        
        if let videoPreview = videoPreview {
            _ = videoPreview.queueSampleBuffer(sampleBuffer)
        }
        
        // support for core_audio_smpte_time
        if supportTimecodeCoreAudio, let timecodeHelper = timecodeHelper {
            let timecodeSampleBuffer = timecodeHelper.createTimeCodeSample(from: sampleBuffer)
            if let timecodeSampleBuffer = timecodeSampleBuffer {
                if let writer = writer {
                    writer.appendTimecodeSampleBuffer(sampleBuffer: timecodeSampleBuffer)
                }
                
                // source provides timecode
                if timecodeReady == false {
                    timecodeReady = true
                    // print("NOTICE: timecodeReady : core_audio_smpte_time")
                }
            }
        }
    }
    
    public func processCapturedVideoSample(_ sampleBuffer: CMSampleBuffer,
                                           timecodeSetting setting: DLABTimecodeSetting,
                                           of sender:DLABDevice) {
        if let writer = writer {
            writer.appendVideoSampleBuffer(sampleBuffer: sampleBuffer)
        }
        
        if let videoPreview = videoPreview {
            _ = videoPreview.queueSampleBuffer(sampleBuffer)
        }
        
        // support for VANC timecode
        if supportTimecodeVANC {
            let timecodeSampleBuffer = setting.createTimecodeSample(in: timecodeFormatType,
                                                                    videoSample: sampleBuffer)
            if let timecodeSampleBuffer = timecodeSampleBuffer {
                if let writer = writer {
                    writer.appendTimecodeSampleBuffer(sampleBuffer: timecodeSampleBuffer)
                }
                
                // source provides timecode
                if timecodeReady == false {
                    timecodeReady = true
                    // print("NOTICE: timecodeReady : VANC")
                }
            }
        }
    }
    
    /* ============================================ */
    // MARK: - utility
    /* ============================================ */
    
    public func findFirstDevice() -> DLABDevice? {
        if currentDevice == nil {
            let deviceArray = deviceList()
            if let deviceArray = deviceArray, deviceArray.count > 0 {
                currentDevice = deviceArray.first!
            }
        }
        return currentDevice
    }
    
    private func prepTimecodeHelper() {
        if supportTimecodeCoreAudio {
            if let timecodeHelper = timecodeHelper {
                timecodeHelper.timeCodeFormatType = timecodeFormatType
            } else {
                timecodeHelper = CaptureTimecodeHelper(formatType: timecodeFormatType)
            }
        }
    }
    
    public func deviceList() -> [DLABDevice]? {
        let browser = DLABBrowser()
        _ = browser.registerDevicesForInput()
        let devciceList = browser.allDevices
        return devciceList
    }
    
    public func inputVideoSettingList(device :DLABDevice) -> [DLABVideoSetting]? {
        let settingList = device.inputVideoSettingArray
        return settingList
    }
    
    public func outputVideoSettingList(device :DLABDevice) -> [DLABVideoSetting]? {
        let settingList = device.outputVideoSettingArray
        return settingList
    }
    
    public func deviceInfo(device :DLABDevice) -> [String:Any] {
        var info :[String:Any] = [:]
        do {
            info["modelName"] = device.modelName // NSString* -> String
            info["displayName"] = device.displayName // NSString* -> String
            info["persistentID"] = device.persistentID // int64_t -> Int64
            info["topologicalID"] = device.topologicalID // int64_t -> Int64
            info["supportFlag"] = device.supportFlag // uint32_t -> UInt32
            info["supportCapture"] = device.supportCapture // BOOL
            info["supportPlayback"] = device.supportPlayback // BOOL
            info["supportKeying"] = device.supportKeying // BOOL
            info["supportInputFormatDetection"] = device.supportInputFormatDetection // BOOL
        }
        return info
    }
    
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
            info["useVITC"] = setting.useVITC // BOOL
            info["useRP188"] = setting.useRP188 // BOOL
            
            info["pixelFormat"] = NSFileTypeForHFSTypeCode(setting.pixelFormat.rawValue) // uint32_t -> UInt32
            info["inputFlag"] = setting.inputFlag.rawValue // uint32_t -> UInt32
            info["outputFlag"] = setting.outputFlag.rawValue // uint32_t -> UInt32
            info["displayModeSupport"] = setting.displayModeSupport.rawValue // uint32_t -> UInt32
            info["rowBytes"] = setting.rowBytes // long -> int64_t -> Int64
            info["videoFormatDescription"] = setting.videoFormatDescription.debugDescription // String
        }
        return info
    }
}
