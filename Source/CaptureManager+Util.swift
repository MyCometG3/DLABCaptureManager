//
//  CaptureManager+Util.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2025/07/06.
//  Copyright © 2025 MyCometG3. All rights reserved.
//

import Cocoa
@preconcurrency import DLABridging

extension CaptureManager {
    
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
