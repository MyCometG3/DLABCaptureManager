//
//  CaptureVideoPreview.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2017/10/31.
//  Copyright © 2017年 MyCometG3. All rights reserved.
//

import Cocoa
import AVFoundation
import CoreVideo

private let enqueueImmediately = true
private let useDisplayLink = false // experimental
private let checkPresentationTime = false // experimental

public class CaptureVideoPreview: NSView, CALayerDelegate {
    /* ================================================ */
    // MARK: - public properties
    /* ================================================ */
    
    /// Backing layer of AVSampleBufferDisplayLayer
    public private(set) var videoLayer :AVSampleBufferDisplayLayer? = nil
    
    /// User preferred pixel aspect ratio. (1.0 = square pixel)
    public var customPixelAspectRatio :CGFloat? = nil
    /// sampleBuffer native pixel aspect ratio (pasp ImageDescription Extension)
    public private(set) var sampleAspectRatio :CGFloat? = nil
    /// image size of encoded rect
    public private(set) var sampleEncodedSize :CGSize? = nil
    /// image size of clean aperture (aspect ratio applied)
    public private(set) var sampleCleanSize : CGSize? = nil
    /// image size of encoded rect (aspect ratio applied)
    public private(set) var sampleProductionSize :CGSize? = nil
    
    /// Verbose mode (debugging purpose)
    public var verbose :Bool = false
    
    /* ================================================ */
    // MARK: - private properties
    /* ================================================ */
    
    /// Processing dispatch queue
    private var processingQueue :DispatchQueue? = nil
    /// Processing dispatch queue label
    private let processingQueueLabel = "videoPreview"
    /// Processing dispatch queue key
    private let processingQueueSpecificKey = DispatchSpecificKey<Void>()
    
    /// Initial value of hostTime - used for media timebase
    private var baseHostTime :UInt64 = 0
    /// Initial value of hostTime offset in sec - used for media timebase
    private var baseOffsetInSec :Float64 = 0.0
    /// Enqueued hostTime
    private var lastQueuedHostTime :UInt64 = 0
    /// last SampleBuffer's Presentation endTime
    private var prevEndTime = CMTime.zero

    /// CoreVideo DisplayLink
    private var displayLink :CVDisplayLink? = nil
    /// Idle monitor limitation in seconds
    private let FREEWHEELING_PERIOD_IN_SECONDS :Float64 = 0.20
    /// Requested hostTime in CVDisplayLinkOutputHandler
    private var lastRequestedHostTime :UInt64 = 0
    /// VideoSampleBuffer to enqueue on Output Handler
    private var newSampleBuffer :CMSampleBuffer? = nil
    
    /* ================================================ */
    // MARK: - General NSView methods
    /* ================================================ */
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        
        setup()
    }
    
    required public init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
        
        // setup() moved to awakeFromNib()
    }
    
    override public func awakeFromNib() {
        super.awakeFromNib()
        
        setup()
    }
    
    deinit {
        shutdown()
        
        videoLayer = nil
        processingQueue = nil
    }
    
    override public func viewWillMove(toSuperview newSuperview: NSView?) {
        if (newSuperview == nil) {
            shutdown()
        } else {
            if useDisplayLink {
                updateDisplayLink()
            }
        }
    }
    
    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        if useDisplayLink {
            _ = activateDisplayLink()
        }
    }
    
    override public var wantsUpdateLayer: Bool {
        if useDisplayLink {
            return false
        }
        return true
    }
    
    override public func updateLayer() {
        layoutSublayers(of: self.layer!)
    }
    
    /* ================================================ */
    // MARK: - public functions
    /* ================================================ */
    
    /// Prepare videoPreview and CVDisplayLink.
    public func prepare() {
        queueSync {
            // Clean up first
            shutdown()
            
            // Add CMSampleBufferDisplayLayer to SubLayer
            if let parentLayer = self.layer, let videoLayer = self.videoLayer {
                if videoLayer.superlayer == nil {
                    // print("addSubLayer")
                    parentLayer.addSublayer(videoLayer)
                }
            }
            
            if useDisplayLink {
                // Create CVDisplayLink
                var newDisplayLink :CVDisplayLink? = nil
                _ = CVDisplayLinkCreateWithActiveCGDisplays(&newDisplayLink)
                
                if let displayLink = newDisplayLink {
                    // Define OutputHandler
                    let outputHandler :CVDisplayLinkOutputHandler = {
                        (inDL :CVDisplayLink, inNowTS :UnsafePointer<CVTimeStamp>,
                        inOutTS :UnsafePointer<CVTimeStamp>, inFlags :CVOptionFlags,
                        outFlags :UnsafeMutablePointer<CVOptionFlags>
                        ) -> CVReturn in
                        
                        // Enqueue request
                        let outHostTime = inOutTS.pointee.hostTime
                        let result = self.requestSampleAt(outHostTime)
                        
                        // Return success if sample is queued now
                        return result ? kCVReturnSuccess : kCVReturnError
                    }
                    _ = CVDisplayLinkSetOutputHandler(displayLink, outputHandler)
                    
                    // Set displayLink
                    self.displayLink = displayLink
                    
                    // Set displayID
                    updateDisplayLink()
                }
                
                // Register observer
                let selector = #selector(CaptureVideoPreview.updateDisplayLink)
                let notification = NSWindow.didChangeScreenNotification
                NotificationCenter.default.addObserver(self,
                                                       selector: selector,
                                                       name: notification,
                                                       object: nil)
            }
        }
    }
    
    /// Shutdown videoPreview and CVDisplayLink.
    public func shutdown() {
        queueSync {
            // Remove CMSampleBufferDisplayLayer from SubLayer
            if let videoLayer = videoLayer, videoLayer.superlayer != nil {
                // print("removeSubLayer")
                videoLayer.removeFromSuperlayer()
            }
            
            if useDisplayLink {
                // Unregister observer
                NotificationCenter.default.removeObserver(self)
                
                // Stop and release CVDisplayLink
                _ = suspendDisplayLink()
                self.displayLink = nil
                
                //
                self.lastRequestedHostTime = 0
            }
            
            //
            resetTimebase(nil)

            //
            self.lastQueuedHostTime = 0
            self.newSampleBuffer = nil
            
            if let videoLayer = self.videoLayer {
                videoLayer.flushAndRemoveImage()
            }
            
            //
            sampleAspectRatio = nil
            sampleEncodedSize = nil
            sampleCleanSize = nil
            sampleProductionSize = nil
        }
    }
    
    /// Enqueue new Video CMSampleBuffer
    ///
    /// - Parameter sampleBuffer: Video CMSampleBuffer
    /// - Returns: False if failed to enqueue
    public func queueSampleBuffer(_ sb :CMSampleBuffer) {
        // Force layout videoLayer if required
        self.updateLayout(sb)
        
        guard let sampleBuffer = deeperCopyVideoSampleBuffer(sbIn: sb)
            else { return }
        
        var result :Bool = false
        queueAsync {
            let startTime :CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration :CMTime = CMSampleBufferGetDuration(sampleBuffer)
            let endTime :CMTime = CMTimeAdd(startTime, duration)
            let startInSec :Float64 = CMTimeGetSeconds(startTime)
            let durationInSec :Float64 = CMTimeGetSeconds(duration)
            let endInSec :Float64 = CMTimeGetSeconds(endTime)
            #if false
                // Dump timing information
                print(startInSec, endInSec, durationInSec)
            #endif
            
            if useDisplayLink {
                // Check/Activate displayLink
                result = self.activateDisplayLink()
                if !result {
                    print("ERROR: DisplayLink is not ready.")
                    return
                }
            } else {
                result = true
            }
            
            #if false
                // Experimental
                self.checkGAP(startTime)
                self.checkDelayed(startTime, startInSec, sampleBuffer)
            #endif
            
            if self.baseHostTime == 0 {
                // Initialize Timebase if this is first sampleBuffer
                self.resetTimebase(sampleBuffer)
            }
            
            if enqueueImmediately {
                // Enqueue immediately if ready
                if result, let videoLayer = self.videoLayer {
                    let statusOK :Bool = (videoLayer.status != .failed)
                    let ready :Bool = videoLayer.isReadyForMoreMediaData
                    if statusOK && ready {
                        // Enqueue samplebuffer
                        videoLayer.enqueue(sampleBuffer)
                        self.lastQueuedHostTime = CVGetCurrentHostTime()
                        
                        // Release enqueued CMSampleBuffer
                        self.newSampleBuffer = nil
                        
                        //
                        self.prevEndTime = endTime
                    } else if self.verbose {
                        var eStr = ""
                        if !statusOK { eStr += "StatusFailed " }
                        if !ready { eStr += "NotReady " }
                        print("NOTICE: videoLayer is not ready to enqueue. \(eStr)")
                    }
                }
                else { print("!!!\(#line)") }
            } else {
                // Retain new sampleBuffer
                self.newSampleBuffer = sampleBuffer
            }
            
            #if false
                // Experimental
                self.adjustTimebase(startTime, duration)
            #endif
        }
    }
    
    /* ================================================ */
    // MARK: - private functions
    /* ================================================ */
    
    /// Reset timebase using SampleBuffer presentation time
    ///
    /// - Parameter sampleBuffer: timebase source sampleBuffer. Set nil to reset to shutdown.
    private func resetTimebase(_ sampleBuffer :CMSampleBuffer?) {
        do {
            if let sampleBuffer = sampleBuffer {
                // start Media Time from sampleBuffer's presentation time
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if let layer = self.videoLayer, let timebase = layer.controlTimebase {
                    _ = CMTimebaseSetTime(timebase, time: time)
                    _ = CMTimebaseSetRate(timebase, rate: 1.0)
                }
                
                // Record base HostTime value as video timebase
                self.baseHostTime = CVGetCurrentHostTime()
                self.baseOffsetInSec = CMTimeGetSeconds(time)
            } else {
                // reset Media Time to Zero
                if let layer = self.videoLayer, let timebase = layer.controlTimebase {
                    _ = CMTimebaseSetRate(timebase, rate: 0.0)
                    _ = CMTimebaseSetTime(timebase, time: CMTime.zero)
                }
                
                // Clear base HostTime value
                self.baseHostTime = 0
                self.baseOffsetInSec = 0.0
            }
        }
    }
    
    /// Common initialization func
    private func setup() {
        // Prepare DispatchQueue for sequencial processing
        processingQueue = DispatchQueue.init(label: processingQueueLabel)
        if let processingQueue = processingQueue {
            processingQueue.setSpecific(key: processingQueueSpecificKey, value: ())
        }
        
        // Prepare backing VideoLayer
        videoLayer = AVSampleBufferDisplayLayer()
        self.wantsLayer = true
        if let videoLayer = videoLayer, let parentLayer = self.layer {
            videoLayer.videoGravity = .resize
            videoLayer.delegate = self
            parentLayer.backgroundColor = NSColor.gray.cgColor

            // Create new CMTimebase using HostTimeClock
            let clock :CMClock = CMClockGetHostTimeClock()
            var timebase :CMTimebase? = nil
            let status :OSStatus = CMTimebaseCreateWithMasterClock(allocator: kCFAllocatorDefault, masterClock: clock, timebaseOut: &timebase)
            
            // Set controlTimebase
            if status == noErr, let timebase = timebase {
                _ = CMTimebaseSetRate(timebase, rate: 0.0)
                _ = CMTimebaseSetTime(timebase, time: CMTime.zero)
                videoLayer.controlTimebase = timebase
            } else {
                print("ERROR: Failed to setup videoLayer's controlTimebase")
            }
        } else {
            print("ERROR: Failed to setup videoLayer.")
        }
    }
    
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
        guard let queue = self.processingQueue else { return }
        
        if nil != DispatchQueue.getSpecific(key: processingQueueSpecificKey) {
            queue.async(execute: block)
            //block()
        } else {
            queue.async(execute: block)
        }
    }
    
    private func deeperCopyVideoSampleBuffer(sbIn :CMSampleBuffer) -> CMSampleBuffer? {
        var fdOut :CMFormatDescription? = nil
        var pbOut :CVPixelBuffer? = nil
        var sbOut :CMSampleBuffer? = nil
        
        // Duplicate CMFormatDescription
        let fd :CMFormatDescription? = CMSampleBufferGetFormatDescription(sbIn)
        if let fd = fd {
            let dim :CMVideoDimensions = CMVideoFormatDescriptionGetDimensions(fd)
            let subType :CMVideoCodecType = CMFormatDescriptionGetMediaSubType(fd)
            var ext :CFDictionary? = CMFormatDescriptionGetExtensions(fd)
            #if false
            if let ext1 = ext { // remove cleanaperture extension if available
                let clap :UnsafeRawPointer = unsafeBitCast(kCMFormatDescriptionExtension_CleanAperture,
                                                           to: UnsafeRawPointer.self)
                if CFDictionaryContainsKey(ext1, clap) {
                    let count :CFIndex = CFDictionaryGetCount(ext1)
                    let ext2 :CFMutableDictionary = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, count, ext1)
                    CFDictionaryRemoveValue(ext2, clap)
                    ext = CFDictionaryCreateCopy(kCFAllocatorDefault, ext2)
                }
            }
            #endif
            CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                           codecType: subType, width: dim.width, height: dim.height, extensions: ext,
                                           formatDescriptionOut: &fdOut)
        }
        
        // Duplicate CVPixelBuffer
        let pb :CVPixelBuffer? = CMSampleBufferGetImageBuffer(sbIn)
        if let pb = pb {
            let width :Int = CVPixelBufferGetWidth(pb)
            let height :Int = CVPixelBufferGetHeight(pb)
            let format :OSType = CVPixelBufferGetPixelFormatType(pb)
            let stride :Int = CVPixelBufferGetBytesPerRow(pb)
            let dict = [
                kCVPixelBufferPixelFormatTypeKey: NSFileTypeForHFSTypeCode(format) as CFString,
                kCVPixelBufferWidthKey: width as CFNumber,
                kCVPixelBufferHeightKey: height as CFNumber,
                kCVPixelBufferBytesPerRowAlignmentKey: stride as CFNumber
            ] as CFDictionary
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, dict, &pbOut)
            
            if let pbOut = pbOut {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                CVPixelBufferLockBaseAddress(pbOut, [])
                if CVPixelBufferIsPlanar(pbOut) {
                    let numPlane = CVPixelBufferGetPlaneCount(pbOut)
                    for plane in 0..<numPlane {
                        let src = CVPixelBufferGetBaseAddressOfPlane(pb, plane)
                        let dst = CVPixelBufferGetBaseAddressOfPlane(pbOut, plane)
                        let height = CVPixelBufferGetHeightOfPlane(pb, plane)
                        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                        memcpy(dst, src, height*stride)
                    }
                } else {
                    let src = CVPixelBufferGetBaseAddress(pb)
                    let dst = CVPixelBufferGetBaseAddress(pbOut)
                    let height = CVPixelBufferGetHeight(pb)
                    let stride = CVPixelBufferGetBytesPerRow(pb)
                    memcpy(dst, src, height*stride)
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                CVPixelBufferUnlockBaseAddress(pbOut, [])
            }
        }
        
        // Create new CMSampleBuffer
        if let fd = fdOut, let pb = pbOut {
            let dict = CMFormatDescriptionGetExtensions(fd)
            CVBufferSetAttachments(pb, dict!, .shouldPropagate)
            
            var timeInfo = CMSampleTimingInfo()
            CMSampleBufferGetSampleTimingInfo(sbIn, at: 0, timingInfoOut: &timeInfo)
            
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pb,
                                                     formatDescription: fd,
                                                     sampleTiming: &timeInfo,
                                                     sampleBufferOut: &sbOut)
        }
        
        return sbOut
    }
    
    /* ================================================ */
    // MARK: -
    /* ================================================ */

    /// Parse ImageBuffer properties of CMSampleBuffer
    ///
    /// - Parameter sampleBuffer: CMSampleBuffer to parse
    private func extractSampleRect(_ sampleBuffer :CMSampleBuffer) {
        let pixelBuffer :CVImageBuffer? = CMSampleBufferGetImageBuffer(sampleBuffer)
        if let pixelBuffer = pixelBuffer {
            let encodedSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                     height: CVPixelBufferGetHeight(pixelBuffer))
            
            var sampleAspect : CGFloat = 1.0
            if let dict = extractCFDictionary(pixelBuffer, kCVImageBufferPixelAspectRatioKey) {
                let aspect = extractCGSize(dict,
                                           kCVImageBufferPixelAspectRatioHorizontalSpacingKey,
                                           kCVImageBufferPixelAspectRatioVerticalSpacingKey)
                if aspect != CGSize.zero {
                    sampleAspect = aspect.width / aspect.height
                }
            }
            
            var cleanSize : CGSize = encodedSize // Initial value is full size (= no clean aperture)
            if let dict = extractCFDictionary(pixelBuffer, kCVImageBufferCleanApertureKey) {
                let clapWidth = extractRational(dict, kCMFormatDescriptionKey_CleanApertureWidthRational)
                let clapHeight = extractRational(dict, kCMFormatDescriptionKey_CleanApertureHeightRational)
                if clapWidth != CGFloat.nan && clapHeight != CGFloat.nan {
                    let clapSize = CGSize(width: clapWidth, height: clapHeight)
                    cleanSize = CGSize(width: clapSize.width * sampleAspect,
                                       height: clapSize.height)
                }
            }
            
            let productionSize = CGSize(width: encodedSize.width * sampleAspect,
                                        height: encodedSize.height)
            
            self.sampleAspectRatio = sampleAspect
            self.sampleEncodedSize = encodedSize
            self.sampleCleanSize = cleanSize
            self.sampleProductionSize = productionSize
        }
    }
    
    /// Extract CFDictionary attachment of specified key from CVPixelBuffer
    ///
    /// - Parameters:
    ///   - pixelBuffer: source CVPixelBuffer
    ///   - key: Attachment Key
    /// - Returns: Attachment Value (CFDictionary)
    private func extractCFDictionary(_ pixelBuffer :CVImageBuffer, _ key :CFString) -> CFDictionary? {
        var dict :CFDictionary? = nil
        if let umCF = CVBufferGetAttachment(pixelBuffer, key, nil) {
            // umCF :Unmanaged<CFTypeRef>
            dict = (umCF.takeUnretainedValue() as! CFDictionary)
        }
        return dict
    }
    
    /// Extract CFNumber value of specified key from CFDictionary
    ///
    /// - Parameters:
    ///   - dict: source CFDictionary
    ///   - key: Key
    /// - Returns: value (CFNumber)
    private func extractCFNumber(_ dict :CFDictionary, _ key :CFString) -> CFNumber? {
        var num :CFNumber? = nil
        let keyOpaque = Unmanaged.passUnretained(key).toOpaque()
        if let ptr = CFDictionaryGetValue(dict, keyOpaque) {
            num = Unmanaged<CFNumber>.fromOpaque(ptr).takeUnretainedValue()
        }
        return num
    }
    
    /// Extract CFArray value of specified key from CFDictionary
    ///
    /// - Parameters:
    ///   - dict: source CFDictionary
    ///   - key: Key
    /// - Returns: value (CFArray)
    private func extractCFArray(_ dict :CFDictionary, _ key :CFString) -> CFArray? {
        var array :CFArray? = nil
        let keyOpaque = Unmanaged.passUnretained(key).toOpaque()
        if let ptr = CFDictionaryGetValue(dict, keyOpaque) {
            array = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue()
        }
        return array
    }
    
    /// Extract CGFloat value of specified key from CFDictionary
    ///
    /// - Parameters:
    ///   - dict: source CFDictionary
    ///   - key: Key
    /// - Returns: value (CGFloat)
    private func extractCGFloat(_ dict :CFDictionary, _ key :CFString) -> CGFloat {
        var val :CGFloat = CGFloat.nan
        if let num = extractCFNumber(dict, key) {
            if CFNumberGetValue(num, .cgFloatType, &val) == false {
                val = CGFloat.nan
            }
        }
        return val
    }
    
    /// Extract CGSize value of specified key pair from CFDictionary
    ///
    /// - Parameters:
    ///   - dict: source CFDictionary
    ///   - key1: Key 1 for size.width
    ///   - key2: Key 2 for size.height
    /// - Returns: value (CGSize)
    private func extractCGSize(_ dict :CFDictionary, _ key1 :CFString, _ key2 :CFString) -> CGSize {
        var size :CGSize = CGSize.zero
        let val1 = extractCGFloat(dict, key1)
        let val2 = extractCGFloat(dict, key2)
        if val1 != CGFloat.nan && val2 != CGFloat.nan {
            size = CGSize(width: val1, height: val2)
        }
        return size
    }

    /// Extract CGFloat value of specified rational key from CFDictionary
    ///
    /// - Parameters:
    ///   - dict: source CFDictionary
    ///   - key: Key for CFArray of 2 CFNumbers: numerator, denominator
    /// - Returns: ratio value calculated from Rational (CGFloat)
    private func extractRational(_ dict :CFDictionary, _ key :CFString) -> CGFloat {
        var val :CGFloat = CGFloat.nan
        let numArray :CFArray? = extractCFArray(dict, key)
        if let numArray = numArray, CFArrayGetCount(numArray) == 2 {
            guard let ptr0 = CFArrayGetValueAtIndex(numArray, 0) else { return val }
            guard let ptr1 = CFArrayGetValueAtIndex(numArray, 1) else { return val }
            let num0 = Unmanaged<CFNumber>.fromOpaque(ptr0).takeUnretainedValue()
            let num1 = Unmanaged<CFNumber>.fromOpaque(ptr1).takeUnretainedValue()
            var val0 :CGFloat = 1.0
            var val1 :CGFloat = 1.0
            if (CFNumberGetValue(num0, .cgFloatType, &val0) && CFNumberGetValue(num1, .cgFloatType, &val1)) {
                val = (val0 / val1)
            }
        }
        return val
    }
    
    /* ================================================ */
    // MARK: -
    /* ================================================ */

    /// Force layout videoLayer if required
    ///
    /// - Parameter sampleBuffer: CMSampleBuffer
    private func updateLayout(_ sampleBuffer :CMSampleBuffer) {
        // initial layout check
        let initialLayout :Bool = (self.sampleAspectRatio == nil)
        if initialLayout {
            DispatchQueue.main.async {
                if let parentLayer = self.layer {
                    self.extractSampleRect(sampleBuffer)
                    self.layoutSublayers(of: parentLayer)
                }
            }
        } else {
            // self.extractSampleRect(sampleBuffer)
        }
    }
    
    /// Experimental : Check Time GAP
    ///
    /// - Parameter startTime: CMTime
    private func checkGAP(_ startTime :CMTime) {
        // Validate samplebuffer if time gap (lost sample) is detected
        var isGAP = false
        do {
            let compResult :Int32 = CMTimeCompare(startTime, self.prevEndTime)
            if startTime.value > 0 && compResult != 0 {
                if self.verbose {
                    print("NOTICE: GAP DETECTED!")
                }
                
                isGAP = true
            }
        }
        
        if isGAP {
            if let layer = self.videoLayer {
                layer.flushAndRemoveImage()
            }
            else { print("!!!\(#line)") }
        }
    }
    
    /// Experimental : Check late arrival
    ///
    /// - Parameters:
    ///   - startTime: CMTime
    ///   - startInSec: Float64
    ///   - sampleBuffer: CMSampleBuffer
    private func checkDelayed(_ startTime :CMTime, _ startInSec :Float64, _ sampleBuffer :CMSampleBuffer) {
        // if sampleBuffer is delayed, mark it as "_DisplayImmediately".
        var isLate = false
        if let layer = self.videoLayer, let timebase = layer.controlTimebase {
            let tbTime = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            if tbTime >= startInSec {
                if self.verbose {
                    print("NOTICE: DELAY DETECTED!")
                }
                
                isLate = true
            }
        }
        else { print("!!!\(#line)") }
        
        if isLate {
            if let attachments :CFArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
                let ptr :UnsafeRawPointer = CFArrayGetValueAtIndex(attachments, 0)
                let dict :CFMutableDictionary = unsafeBitCast(ptr, to: CFMutableDictionary.self)
                let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
                let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                CFDictionaryAddValue(dict, key, value)
            }
            else { print("!!!\(#line)") }
        }
    }
    
    /// Experimental : Adjust timebase
    ///
    /// - Parameters:
    ///   - startTime: CMTime
    ///   - duration: CMTime
    private func adjustTimebase(_ startTime :CMTime, _ duration :CMTime) {
        // Adjust TimebaseTime if required (enqueue may hog time)
        if let layer = self.videoLayer, let timebase = layer.controlTimebase {
            let tbTime = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            let time2 = CMTimeSubtract(startTime, CMTimeMultiplyByFloat64(duration, multiplier: Float64(0.5)))
            let time2InSec = CMTimeGetSeconds(time2)
            if tbTime > time2InSec {
                if self.verbose {
                    print("NOTICE: ADJUST! " + String(format:"%0.6f", (time2InSec - tbTime)))
                }
                
                // roll back timebase to make some delay for a half of sample duration
                _ = CMTimebaseSetTime(timebase, time: time2)
                _ = CMTimebaseSetRate(timebase, rate: 1.0)
            }
        }
        else { print("!!!\(#line)") }
    }

    /* ================================================ */
    // MARK: - CALayerDelegate and more
    /* ================================================ */
    
    public func layoutSublayers(of layer: CALayer) {
        if let parentLayer = self.layer, let videoLayer = videoLayer {
            if layer == parentLayer {
                let viewSize = self.bounds.size
                let layerSize = preferredSize(of: videoLayer)
                
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                videoLayer.frame = CGRect(x: (viewSize.width-layerSize.width)/2,
                                          y: (viewSize.height-layerSize.height)/2,
                                          width: layerSize.width,
                                          height: layerSize.height)
                videoLayer.videoGravity = .resize
                CATransaction.commit()
                
                //print (#function, layerSize)
            }
        }
    }
    
    public func preferredSize(of layer :CALayer) -> CGSize {
        if layer == videoLayer {
            var layerSize = self.bounds.size
            let viewSize :CGSize = self.bounds.size
            let viewAspect :CGFloat = viewSize.width / viewSize.height
            
            var requestAspect :CGFloat = viewAspect
            if let encSize = sampleEncodedSize, let proSize = sampleProductionSize {
                if let aspect = customPixelAspectRatio {
                    requestAspect = (encSize.width / encSize.height) * aspect
                } else {
                    requestAspect = (proSize.width / proSize.height)
                }
            }
            
            let adjustRatio :CGFloat = requestAspect / viewAspect
            
            if viewAspect < requestAspect {
                // Shrink vertically
                layerSize = CGSize(width:viewSize.width,
                                   height: viewSize.height / adjustRatio)
            } else {
                // Shrink horizontally
                layerSize = CGSize(width: viewSize.width * adjustRatio,
                                   height: viewSize.height )
            }
            return layerSize
        } else {
            return self.bounds.size
        }
    }
    
    /* ================================================ */
    // MARK: - private functions (DisplayLink)
    /* ================================================ */
    
    /// Start displayLink with current CGDirectDisplayID.
    ///
    /// - Returns: True if displayLink is running.
    private func activateDisplayLink() -> Bool {
        var result = false;
        queueSync {
            if self.displayLink == nil {
                prepare()
            }
    
            if let displayLink = self.displayLink {
                if !CVDisplayLinkIsRunning(displayLink) {
                    _ = CVDisplayLinkStart(displayLink)
                }
                
                result = CVDisplayLinkIsRunning(displayLink)
            }
        }
        return result
    }
    
    /// Stop displayLink with current CGDirectDisplayID.
    ///
    /// - Returns: True if displayLink is not running.
    private func suspendDisplayLink() -> Bool {
        var result = false;
        queueSync {
            if let displayLink = self.displayLink {
                if CVDisplayLinkIsRunning(displayLink) {
                    _ = CVDisplayLinkStop(displayLink)
                }
                
                result = !CVDisplayLinkIsRunning(displayLink)
            }
        }
        return result
    }
    
    /// Update linked CGDirectDisplayID with current view's displayID.
    @objc private func updateDisplayLink() {
        queueSync {
            if let displayLink = self.displayLink {
                let linkedDisplayID = CVDisplayLinkGetCurrentCGDisplay(displayLink)
                
                var viewDisplayID :CGDirectDisplayID = CGMainDisplayID()
                if let window = self.window, let screen = window.screen {
                    let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
                    if let viewScreenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber {
                        viewDisplayID = viewScreenNumber.uint32Value
                    }
                }
                
                if linkedDisplayID != viewDisplayID {
                    if CVDisplayLinkIsRunning(displayLink) {
                        _ = CVDisplayLinkStop(displayLink)
                        _ = CVDisplayLinkSetCurrentCGDisplay(displayLink, viewDisplayID)
                        _ = CVDisplayLinkStart(displayLink)
                    } else {
                        _ = CVDisplayLinkSetCurrentCGDisplay(displayLink, viewDisplayID)
                    }
                }
            }
        }
    }
    
    /// Request sampleBuffer for specified future HostTime
    ///
    /// - Parameter outHostTime: future target hostTime (beamsync/video refresh scheduled)
    /// - Returns: False if failed to enqueue
    private func requestSampleAt(_ outHostTime :UInt64) -> Bool {
        var result :Bool = false
        do {
            self.lastRequestedHostTime = outHostTime
    
            // Check if no sampleBuffer is queued yet
            if self.baseHostTime == 0 {
                print("ERROR: No video sample is queued yet.")
                return false
            }
    
            // Try delayed enqueue
            if let sampleBuffer = self.newSampleBuffer, let videoLayer = self.videoLayer {
                let statusOK :Bool = (videoLayer.status != .failed)
                let ready :Bool = videoLayer.isReadyForMoreMediaData
                if statusOK && ready {
                    if checkPresentationTime {
                        // Validate sampleBuffer presentation time
                        result = validateSample(outHostTime, sampleBuffer)
                    } else {
                        result = true
                    }
                    
                    if result {
                        // Enqueue samplebuffer
                        videoLayer.enqueue(sampleBuffer)
                        self.lastQueuedHostTime = CVGetCurrentHostTime()
    
                        // Release captured CMSampleBuffer
                        self.newSampleBuffer = nil
                    } else {
                        print("ERROR: No video sample is available for specified HostTime.")
                    }
                } else if verbose {
                    var eStr = ""
                    if !statusOK { eStr += "StatusFailed " }
                    if !ready { eStr += "NotReady " }
                    print("NOTICE: videoLayer is not ready to enqueue. \(eStr)")
                }
            }
    
            // Stop CVDisplayLink if no update for a while
            if !result {
                // Check idle duration
                let idleInUnits :UInt64 = outHostTime - self.lastQueuedHostTime
                let idleInSec :Float64 = hostTimeUnitsToSec(idleInUnits)
                if idleInSec > self.FREEWHEELING_PERIOD_IN_SECONDS {
                    _ = suspendDisplayLink()
                }
    
                // Release captured CMSampleBuffer
                self.newSampleBuffer = nil
            }
        }
        return result
    }
    
    /// validate if sampleBuffer has presentation time range on next Video Refresh HostTime
    ///
    /// - Parameters:
    ///   - outHostTime: future target HostTime (beamsync)
    ///   - sampleBuffer: target samplebuffer
    /// - Returns: True if ready to enqueue
    private func validateSample(_ outHostTime :UInt64, _ sampleBuffer: CMSampleBuffer) -> Bool {
        var result :Bool = false
        do {
            // Get target timestamp offset (beamSync)
            let offsetInUnits :UInt64 = outHostTime - baseHostTime
            let offsetInSec :Float64 = hostTimeUnitsToSec(offsetInUnits) + baseOffsetInSec
    
            // Get presentation timestamp (start and end)
            let startTime :CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration :CMTime = CMSampleBufferGetDuration(sampleBuffer)
            let endTime :CMTime = CMTimeAdd(startTime, duration)
            let startInSec :Float64 = CMTimeGetSeconds(startTime)
            let endInSec :Float64 = CMTimeGetSeconds(endTime)
    
            // Check if the beamSync is within the presentation time
            let startBefore :Bool = startInSec <= offsetInSec
            let endAfter :Bool = offsetInSec <= endInSec
            result = (startBefore && endAfter)
        }
        return result
    }
    
    /// Convert hostTime(UInt64) to second (Float64)
    ///
    /// - Parameter hostTime: UInt64 value as HostTime
    /// - Returns: Float64 value in seconds
    private func hostTimeUnitsToSec(_ hostTime :UInt64) -> Float64 {
        let valueInTime : CMTime = CMClockMakeHostTimeFromSystemUnits(hostTime)
        let valueInSec :Float64 = CMTimeGetSeconds(valueInTime)
        return valueInSec
    }
}
