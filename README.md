## DLABCaptureManager.framework

Simple AV Capture Swift API for DLABridging (Objective-C API).

- __Requirement__: macOS 13.x, 12.x, 11.x, 10.15, 10.14.
- __Capture Device__: Blackmagic DeckLink devices/UltraStudio devices.
- __Restriction__: Compressed/Synchronized captures are not supported.
- __Dependency__: DeckLinkAPI.framework from Blackmagic_Desktop_Video_Macintosh (11.4-11.7, 12.0-12.7)
- __Dependency__: DLABridging.framework
- __Architecture__: Universal binary (x86_64 + arm64)

NOTE: This framework is under development.

#### Basic usage (capture)

###### 1. Start capture session using DLABCaptureManager
    import Cocoa
    import DLABridging
    import DLABCapturemanager

    var manager :DLABCaptureManager? = nil
    var flag32BGRA :Bool = false
    var flagHDMIAudioLayout :Bool = true

    if manager == nil {
      manager = DLABCaptureManager()
    }
    if let manager = manager {
      guard let _ = manager.findFirstDevice() else { return }

      // Capture setting
      manager.sampleTimescale = 30000
      #if true
        // HD-1080i, fieldDominance:upper, HDMI+embedded
        manager.displayMode = .modeHD1080i5994
        manager.pixelFormat = .format10BitYUV
        manager.videoStyle = .HD_1920_1080_Full
        manager.videoConnection = .HDMI
        manager.audioConnection = .embedded
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
      if flag32BGRA {
        manager.cvPixelFormat = kCVPixelFormatType_32BGRA
      }

      // Specify codec on recording
      manager.encodeProRes422 = false
      // manager.encodeVideoCodecType = kCMVideoCodecType_AppleProRes422LT
      manager.encodeVideoCodecType = kCMVideoCodecType_H264
      manager.encodeAudio = true

      // Preview CALayer
      // manager.videoPreview = myCaptureVideoPreview

      // Preview CocoaScreenPreview
      manager.parentView = myCocoaScreenPreview

      // Support HDMI audio channel layout
      if manager.videoConnection == .HDMI,
         manager.audioConnection == .embedded,
         flagHDMIAudioLayout {
          manager.audioChannels = 8     // Should be 8ch input
          manager.hdmiAudioChannels = 6 // HDMI 5.1ch surround
          manager.reverseCh3Ch4 = true  // For source that (ch3, ch4) == (LFE, C)
      } else {
          manager.hdmiAudioChannels = 0
      }

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
- macOS 13.6 Ventura
- Xcode 15.0
- Swift 5.9

#### License
- The MIT License

Copyright © 2017-2023年 MyCometG3. All rights reserved.
