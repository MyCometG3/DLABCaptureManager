## DLABCaptureManager.framework

Simple AV Capture Swift API for DLABridging (Objective-C API).

- __Requirement__: MacOS X 10.13 or later.
- __Capture Device__: Blackmagic Intensity Shuttle, or other DeckLink devices.
- __Restriction__: Only 8 or 10 bit yuv, or 8 bit rgb are supported.
- __Dependency__: DeckLinkAPI.framework from Blackmagic_Desktop_Video_Macintosh_11.4 or later.
- __Dependency__: DLABridging.framework

NOTE: This framework is under development.
NOTE: Compressed capture is not supported.

#### Basic usage (capture)

###### 1. Start capture session using DLABCaptureManager
    import Cocoa
    import DLABridging
    import DLABCapturemanager

    var manager :DLABCaptureManager? = nil

    if manager == nil {
      manager = DLABCaptureManager()
    }
    if let manager = manager {
      guard let _ = manager.findFirstDevice() else { return }

      // Capture setting
      manager.sampleTimescale = 30000
      #if true
        // HD-1080i, fieldDominance:upper, HDMI+RCA
        manager.displayMode = .modeHD1080i5994
        manager.pixelFormat = .format10BitYUV
        manager.videoStyle = .HD_1920_1080_Full
        manager.videoConnection = .HDMI
        manager.audioConnection = .analogRCA
        manager.fieldDetail = kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly
      #else
        // SD-NTSC, fieldDominance:lower, sVideo+RCA
        manager.displayMode = .modeNTSC
        manager.pixelFormat = .format8BitYUV
        manager.videoStyle = .SD_720_486_16_9
        manager.offset = NSPoint(x: 4, y: 0) // clean aperture offset
        manager.videoConnection = .sVideo
        manager.audioConnection = .analogRCA
        manager.fieldDetail = kCMFormatDescriptionFieldDetail_SpatialFirstLineLate
      #endif

      // Convert pixelFormat of CMSampleBuffer
      // manager.cvPixelFormat = kCVPixelFormatType_32BGRA

      // Specify codec on recording
      manager.encodeProRes422 = false
      manager.encodeVideoCodecType = kCMVideoCodecType_AppleProRes422LT
      // manager.encodeVideoCodecType = kCMVideoCodecType_H264

      // Preview CALayer
      manager.parentView = parentView

      // Start capture
      manager.captureStart()
    }

###### 2. Toggle recording
    if let manager = manager, manager.running {
      manager.recordToggle()        
    }

###### 3. Stop Capture
    if let manager = manager, manager.running {
      if manager.recording {
        manager.recordToggle
      }
      manager.captureStop()
    }
    manager = nil

#### Development environment
- MacOS X 10.15.6 Catalina
- Xcode 12.0.1
- Swift 5.3

#### License
    - The MIT License

Copyright © 2017-2020年 MyCometG3. All rights reserved.
