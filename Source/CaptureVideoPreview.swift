//
//  CaptureVideoPreview.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2017/10/31.
//  Copyright © 2017-2023 MyCometG3. All rights reserved.
//

import Cocoa
import AVFoundation
import CoreVideo

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
    
    /// Prepared or not
    private var prepared :Bool = false
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
    
    /// CVPixelBufferPool
    private var pixelBufferPool :CVPixelBufferPool? = nil
    
    /* ================================================ */
    // MARK: - private properties (displayLink)
    /* ================================================ */
    
    /// Debug mode
    private let debugLog = false
    
    /// Debug DisplayLink
    private let useDisplayLink = false // experimental
    /// Debug Non-Delayed queueing
    private let enqueueImmediately = true // experimental
    /// Debug Timestamp Strict checking
    private let checkPresentationTime = false // experimental
    
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
        cleanup()
    }
    
    override public var wantsUpdateLayer: Bool {
        return true
    }
    
    override public func updateLayer() {
        if useDisplayLink {
            _ = activateDisplayLink()
        }
        layoutSublayers(of: layer!)
    }
    
    /* ================================================ */
    // MARK: - public functions
    /* ================================================ */
    
    /// Prepare videoPreview and CVDisplayLink.
    public func prepare() {
        queueSync {
            guard prepared == false else { return }
            
            prepared = true
            
            // Add CMSampleBufferDisplayLayer to SubLayer
            if let baseLayer = layer, let vLayer = videoLayer {
                if vLayer.superlayer == nil {
                    // NSLog("addSubLayer")
                    DispatchQueue.main.async {
                        baseLayer.addSublayer(vLayer)
                    }
                }
            }
            
            if useDisplayLink {
                prepareDisplayLink()
            }
        }
    }
    
    /// Shutdown videoPreview and CVDisplayLink.
    public func shutdown() {
        queueSync {
            guard prepared == true else { return }
            
            prepared = false
            
            if useDisplayLink {
                shutdownDisplayLink()
            }
            
            // Remove CMSampleBufferDisplayLayer from SubLayer
            if let vLayer = videoLayer, vLayer.superlayer != nil {
                // NSLog("removeSubLayer")
                vLayer.removeFromSuperlayer()
            }
            
            //
            resetTimebase(nil)
            
            if let vLayer = videoLayer {
                vLayer.flushAndRemoveImage()
            }
            
            if let pixelBufferPool = pixelBufferPool {
                CVPixelBufferPoolFlush(pixelBufferPool, .excessBuffers)
                self.pixelBufferPool = nil
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
        guard let sampleBuffer = deeperCopyVideoSampleBuffer(sbIn: sb)
            else { return }
        
        extractSampleRect(sampleBuffer)
        
        if useDisplayLink {
            queueSampleBufferUsingDisplayLink(sampleBuffer)
        } else {
            queueSync {
                if baseHostTime == 0 {
                    // Initialize Timebase if this is first sampleBuffer
                    resetTimebase(sampleBuffer)
                }
                
                if let vLayer = videoLayer {
                    let statusOK :Bool = (vLayer.status != .failed)
                    let ready :Bool = vLayer.isReadyForMoreMediaData
                    if statusOK && ready {
                        // Enqueue samplebuffer
                        vLayer.enqueue(sampleBuffer)
                    } else if self.verbose {
                        var eStr = ""
                        if !statusOK { eStr += "StatusFailed " }
                        if !ready { eStr += "NotReady " }
                        NSLog("NOTICE: videoLayer is not ready to enqueue. \(eStr)")
                    }
                }
            }
        }
    }
    
    /* ================================================ */
    // MARK: - private functions
    /* ================================================ */
    
    /// Common initialization func
    private func setup() {
        // Prepare DispatchQueue for sequencial processing
        processingQueue = DispatchQueue.init(label: processingQueueLabel)
        if let processingQueue = processingQueue {
            processingQueue.setSpecific(key: processingQueueSpecificKey, value: ())
        }
        
        // Prepare backing VideoLayer
        videoLayer = AVSampleBufferDisplayLayer()
        wantsLayer = true
        layerContentsRedrawPolicy = NSView.LayerContentsRedrawPolicy.duringViewResize
        if let vLayer = videoLayer, let baseLayer = layer {
            vLayer.videoGravity = .resize
            vLayer.delegate = self
            baseLayer.backgroundColor = NSColor.gray.cgColor
            
            // Create new CMTimebase using HostTimeClock
            let clock :CMClock = CMClockGetHostTimeClock()
            var timebase :CMTimebase? = nil
            let status :OSStatus = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: clock, timebaseOut: &timebase)
            
            // Set controlTimebase
            if status == noErr, let timebase = timebase {
                _ = CMTimebaseSetRate(timebase, rate: 0.0)
                _ = CMTimebaseSetTime(timebase, time: CMTime.zero)
                vLayer.controlTimebase = timebase
            } else {
                NSLog("ERROR: Failed to setup videoLayer's controlTimebase")
            }
        } else {
            NSLog("ERROR: Failed to setup videoLayer.")
        }
    }
    
    /// clean up func
    private func cleanup() {
        shutdown()
        
        videoLayer = nil
        processingQueue = nil
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
        guard let queue = processingQueue else { return }
        
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
            let ext :CFDictionary? = CMFormatDescriptionGetExtensions(fd)
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
            let alignment :Int = CVPixelBufferGetBytesPerRow(pb)
            let dict = [
                kCVPixelBufferPixelFormatTypeKey: format as CFNumber,
                kCVPixelBufferWidthKey: width as CFNumber,
                kCVPixelBufferHeightKey: height as CFNumber,
                kCVPixelBufferBytesPerRowAlignmentKey: alignment as CFNumber,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString : Any],
                ] as [CFString : Any] as CFDictionary
            if let pool = pixelBufferPool, let pbAttr = CVPixelBufferPoolGetPixelBufferAttributes(pool) {
                // Check if pixelBufferPool is compatible or not
                let typeOK = equalCFNumberInDictionary(dict, pbAttr, kCVPixelBufferPixelFormatTypeKey)
                let widthOK = equalCFNumberInDictionary(dict, pbAttr, kCVPixelBufferWidthKey)
                let heightOK = equalCFNumberInDictionary(dict, pbAttr, kCVPixelBufferHeightKey)
                let strideOK = equalCFNumberInDictionary(dict, pbAttr, kCVPixelBufferBytesPerRowAlignmentKey)
                if !(typeOK && widthOK && heightOK && strideOK) {
                    CVPixelBufferPoolFlush(pool, .excessBuffers)
                    self.pixelBufferPool = nil
                }
            }
            if pixelBufferPool == nil {
                let poolAttr = [
                    kCVPixelBufferPoolMinimumBufferCountKey: 4 as CFNumber
                    ] as CFDictionary
                let err = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttr, dict, &pixelBufferPool)
                if err != kCVReturnSuccess {
                    NSLog("ERROR: Failed to create CVPixelBufferPool")
                    return nil
                }
            }
            if let pixelBufferPool = pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pbOut)
            }
            
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
                var clapWidth = extractRational(dict, kCMFormatDescriptionKey_CleanApertureWidthRational)
                if clapWidth.isNaN {
                    clapWidth = extractCGFloat(dict, kCVImageBufferCleanApertureWidthKey)
                }
                var clapHeight = extractRational(dict, kCMFormatDescriptionKey_CleanApertureHeightRational)
                if clapHeight.isNaN {
                    clapHeight = extractCGFloat(dict, kCVImageBufferCleanApertureHeightKey)
                }
                if !clapWidth.isNaN && !clapHeight.isNaN {
                    let clapSize = CGSize(width: clapWidth, height: clapHeight)
                    cleanSize = CGSize(width: clapSize.width * sampleAspect,
                                       height: clapSize.height)
                }
            }
            
            let productionSize = CGSize(width: encodedSize.width * sampleAspect,
                                        height: encodedSize.height)
            
            if (sampleAspectRatio    != sampleAspect ||
                sampleEncodedSize    != encodedSize  ||
                sampleCleanSize      != cleanSize    ||
                sampleProductionSize != productionSize)
            {
                sampleAspectRatio    = sampleAspect
                sampleEncodedSize    = encodedSize
                sampleCleanSize      = cleanSize
                sampleProductionSize = productionSize
                
                NSLog("INFO: Update video sample property.")
                
                // Apply new aspect ratio to sublayer
                DispatchQueue.main.async {
                    self.needsDisplay = true
                }
            }
        }
    }
    
    private var useCast :Bool = true
    private func toOpaque(_ obj :AnyObject) -> UnsafeRawPointer {
        if useCast {
            let ptr = unsafeBitCast(obj, to: UnsafeRawPointer.self)
            return ptr
        } else {
            let mutablePtr :UnsafeMutableRawPointer = Unmanaged.passUnretained(obj).toOpaque()
            let ptr :UnsafeRawPointer = UnsafeRawPointer(mutablePtr)
            return ptr
        }
    }
    
    private func fromOpaque<T :AnyObject>(_ ptr :UnsafeRawPointer, _ type :T.Type) -> T {
        let val = Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
        return val
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
        let keyOpaque = toOpaque(key)
        if let ptr = CFDictionaryGetValue(dict, keyOpaque) {
            num = fromOpaque(ptr, CFNumber.self)
        }
        return num
    }
    
    /// Check if two values for single key in different dictionary are equal or not.
    /// - Parameters:
    ///   - d1: CFDictionary
    ///   - d2: CFDictionary
    ///   - key: CFString
    /// - Returns: true if equal, false if different
    private func equalCFNumberInDictionary(_ d1 :CFDictionary, _ d2 :CFDictionary, _ key :CFString) -> Bool {
        let val1 = extractCFNumber(d1, key)
        let val2 = extractCFNumber(d2, key)
        let comp = CFNumberCompare(val1, val2, nil)
        return (comp == CFComparisonResult.compareEqualTo)
    }
    
    /// Extract CFArray value of specified key from CFDictionary
    ///
    /// - Parameters:
    ///   - dict: source CFDictionary
    ///   - key: Key
    /// - Returns: value (CFArray)
    private func extractCFArray(_ dict :CFDictionary, _ key :CFString) -> CFArray? {
        var array :CFArray? = nil
        let keyOpaque = toOpaque(key)
        if let ptr = CFDictionaryGetValue(dict, keyOpaque) {
            array = fromOpaque(ptr, CFArray.self)
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
        if !val1.isNaN && !val2.isNaN {
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
            let num0 = fromOpaque(ptr0, CFNumber.self)
            let num1 = fromOpaque(ptr1, CFNumber.self)
            var val0 :CGFloat = 1.0
            var val1 :CGFloat = 1.0
            if (CFNumberGetValue(num0, .cgFloatType, &val0) && CFNumberGetValue(num1, .cgFloatType, &val1)) {
                val = (val0 / val1)
            }
        }
        return val
    }
    
    /* ================================================ */
    // MARK: - CALayerDelegate and more
    /* ================================================ */
    
    public func layoutSublayers(of targetLayer: CALayer) {
        if let baseLayer = layer, let vLayer = videoLayer {
            if targetLayer == baseLayer {
                let viewSize = bounds.size
                let layerSize = preferredSize(of: vLayer)
                let vLayerRect = vLayer.frame
                let targetRect = CGRect(x: (viewSize.width-layerSize.width)/2,
                                        y: (viewSize.height-layerSize.height)/2,
                                        width: layerSize.width,
                                        height: layerSize.height)
                if (vLayerRect != targetRect) {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    vLayer.frame = targetRect
                    vLayer.videoGravity = .resize
                    CATransaction.commit()
                }
                
                //NSLog("%@ %@", #function, layerSize.debugDescription)
            }
        }
    }
    
    public func preferredSize(of vLayer :CALayer) -> CGSize {
        if vLayer == videoLayer {
            var layerSize = bounds.size
            let viewSize :CGSize = bounds.size
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
            return bounds.size
        }
    }
    
    /* ================================================ */
    // MARK: - private functions (Timebase)
    /* ================================================ */
    
    /// Reset timebase using SampleBuffer presentation time
    ///
    /// - Parameter sampleBuffer: timebase source sampleBuffer. Set nil to reset to shutdown.
    private func resetTimebase(_ sampleBuffer :CMSampleBuffer?) {
        do {
            if let sampleBuffer = sampleBuffer {
                // start Media Time from sampleBuffer's presentation time
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if let vLayer = videoLayer, let timebase = vLayer.controlTimebase {
                    _ = CMTimebaseSetTime(timebase, time: time)
                    _ = CMTimebaseSetRate(timebase, rate: 1.0)
                }
                
                // Record base HostTime value as video timebase
                baseHostTime = CVGetCurrentHostTime()
                baseOffsetInSec = CMTimeGetSeconds(time)
            } else {
                // reset Media Time to Zero
                if let vLayer = videoLayer, let timebase = vLayer.controlTimebase {
                    _ = CMTimebaseSetRate(timebase, rate: 0.0)
                    _ = CMTimebaseSetTime(timebase, time: CMTime.zero)
                }
                
                // Clear base HostTime value
                baseHostTime = 0
                baseOffsetInSec = 0.0
            }
        }
    }
    
    /// Experimental : Check Time GAP
    ///
    /// - Parameter startTime: CMTime
    private func checkGAP(_ startTime :CMTime) {
        // Validate samplebuffer if time gap (lost sample) is detected
        var isGAP = false
        do {
            let compResult :Int32 = CMTimeCompare(startTime, prevEndTime)
            if startTime.value > 0 && compResult != 0 {
                if verbose {
                    NSLog("NOTICE: GAP DETECTED!")
                }
                
                isGAP = true
            }
        }
        
        if isGAP {
            if let vLayer = videoLayer {
                vLayer.flushAndRemoveImage()
            }
            else { NSLog("!!!\(#line)") }
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
        if let vLayer = videoLayer, let timebase = vLayer.controlTimebase {
            let tbTime = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            if tbTime >= startInSec {
                if verbose {
                    NSLog("NOTICE: DELAY DETECTED!")
                }
                
                isLate = true
            }
        }
        else { NSLog("!!!\(#line)") }
        
        if isLate {
            if let attachments :CFArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
                let ptr :UnsafeRawPointer = CFArrayGetValueAtIndex(attachments, 0)
                let dict = fromOpaque(ptr, CFMutableDictionary.self)
                let key = toOpaque(kCMSampleAttachmentKey_DisplayImmediately)
                let value = toOpaque(kCFBooleanTrue)
                CFDictionaryAddValue(dict, key, value)
            }
            else { NSLog("!!!\(#line)") }
        }
    }
    
    /// Experimental : Adjust timebase
    ///
    /// - Parameters:
    ///   - startTime: CMTime
    ///   - duration: CMTime
    private func adjustTimebase(_ startTime :CMTime, _ duration :CMTime) {
        // Adjust TimebaseTime if required (enqueue may hog time)
        if let vLayer = videoLayer, let timebase = vLayer.controlTimebase {
            let tbTime = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            let time2 = CMTimeSubtract(startTime, CMTimeMultiplyByFloat64(duration, multiplier: Float64(0.5)))
            let time2InSec = CMTimeGetSeconds(time2)
            if tbTime > time2InSec {
                if verbose {
                    NSLog("NOTICE: ADJUST! " + String(format:"%0.6f", (time2InSec - tbTime)))
                }
                
                // roll back timebase to make some delay for a half of sample duration
                _ = CMTimebaseSetTime(timebase, time: time2)
                _ = CMTimebaseSetRate(timebase, rate: 1.0)
            }
        }
        else { NSLog("!!!\(#line)") }
    }
    
    /* ================================================ */
    // MARK: - private functions (DisplayLink)
    /* ================================================ */
    
    private func prepareDisplayLink() {
        // Create CVDisplayLink
        var newDisplayLink :CVDisplayLink? = nil
        _ = CVDisplayLinkCreateWithActiveCGDisplays(&newDisplayLink)
        
        if let newDisplayLink = newDisplayLink {
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
            _ = CVDisplayLinkSetOutputHandler(newDisplayLink, outputHandler)
            
            // Set displayLink
            displayLink = newDisplayLink
            
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
    
    private func shutdownDisplayLink() {
        // Unregister observer
        NotificationCenter.default.removeObserver(self)
        
        // Stop and release CVDisplayLink
        _ = suspendDisplayLink()
        displayLink = nil
        
        //
        lastRequestedHostTime = 0
        
        //
        lastQueuedHostTime = 0
        newSampleBuffer = nil
    }
    
    /// Start displayLink with current CGDirectDisplayID.
    ///
    /// - Returns: True if displayLink is running.
    private func activateDisplayLink() -> Bool {
        var result = false;
        queueSync {
            if displayLink == nil {
                prepareDisplayLink()
            }
            
            if let displayLink = displayLink {
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
            if let displayLink = displayLink {
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
            if let displayLink = displayLink {
                let linkedDisplayID = CVDisplayLinkGetCurrentCGDisplay(displayLink)
                
                var viewDisplayID :CGDirectDisplayID = CGMainDisplayID()
                if let window = window, let screen = window.screen {
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
    
    /// Delayed enqueue with DisplayLink support
    /// - Parameter sampleBuffer: CMSampleBuffer to queue
    private func queueSampleBufferUsingDisplayLink(_ sampleBuffer :CMSampleBuffer) {
        queueSync {
            let startTime :CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration :CMTime = CMSampleBufferGetDuration(sampleBuffer)
            let endTime :CMTime = CMTimeAdd(startTime, duration)
            let startInSec :Float64 = CMTimeGetSeconds(startTime)
            let durationInSec :Float64 = CMTimeGetSeconds(duration)
            let endInSec :Float64 = CMTimeGetSeconds(endTime)
            if debugLog {
                let strStart = String(format:"%.3f", startInSec)
                let strEnd = String(format:"%.3f", endInSec)
                let strDuration = String(format:"%.3f", durationInSec)
                NSLog("Enqueue: start(\(strStart)) end(\(strEnd)) dur(\(strDuration))")
            }
            
            // Check/Activate displayLink
            let result = activateDisplayLink()
            if !result {
                NSLog("ERROR: DisplayLink is not ready.")
                return
            }
            
            #if false
            // Experimental
            checkGAP(startTime)
            checkDelayed(startTime, startInSec, sampleBuffer)
            #endif
            
            if baseHostTime == 0 {
                // Initialize Timebase if this is first sampleBuffer
                resetTimebase(sampleBuffer)
            }
            
            // Keep as delayed sample
            newSampleBuffer = sampleBuffer
            if enqueueImmediately {
                if let vLayer = videoLayer {
                    let statusOK :Bool = (vLayer.status != .failed)
                    let ready :Bool = vLayer.isReadyForMoreMediaData
                    if statusOK && ready {
                        // Enqueue samplebuffer
                        vLayer.enqueue(sampleBuffer)
                        lastQueuedHostTime = CVGetCurrentHostTime()
                        
                        // Release enqueued CMSampleBuffer
                        newSampleBuffer = nil
                        
                        //
                        prevEndTime = endTime
                    } else if verbose {
                        var eStr = ""
                        if !statusOK { eStr += "StatusFailed " }
                        if !ready { eStr += "NotReady " }
                        NSLog("NOTICE: videoLayer is not ready to enqueue. \(eStr)")
                    }
                }
            }
            
            #if false
            // Experimental
            adjustTimebase(startTime, duration)
            #endif
        }
    }
    
    /// Request sampleBuffer for specified future HostTime
    ///
    /// - Parameter outHostTime: future target hostTime (beamsync/video refresh scheduled)
    /// - Returns: False if failed to enqueue
    private func requestSampleAt(_ outHostTime :UInt64) -> Bool {
        var result :Bool = false
        do {
            lastRequestedHostTime = outHostTime
            
            // Check if no sampleBuffer is queued yet
            if baseHostTime == 0 {
                NSLog("ERROR: No video sample is queued yet.")
                return false
            }
            
            // Try delayed enqueue
            if let sampleBuffer = newSampleBuffer, let vLayer = videoLayer {
                let statusOK :Bool = (vLayer.status != .failed)
                let ready :Bool = vLayer.isReadyForMoreMediaData
                if statusOK && ready {
                    if checkPresentationTime {
                        // Validate sampleBuffer presentation time
                        result = validateSample(outHostTime, sampleBuffer)
                    } else {
                        result = true
                    }
                    
                    if result {
                        // Enqueue samplebuffer
                        vLayer.enqueue(sampleBuffer)
                        lastQueuedHostTime = CVGetCurrentHostTime()
                        
                        // Release captured CMSampleBuffer
                        newSampleBuffer = nil
                    } else {
                        NSLog("ERROR: No video sample is available for specified HostTime.")
                    }
                } else if verbose {
                    var eStr = ""
                    if !statusOK { eStr += "StatusFailed " }
                    if !ready { eStr += "NotReady " }
                    NSLog("NOTICE: videoLayer is not ready to enqueue. \(eStr)")
                }
            }
            
            // Stop CVDisplayLink if no update for a while
            if !result {
                // Check idle duration
                let idleInUnits :UInt64 = outHostTime - lastQueuedHostTime
                let idleInSec :Float64 = hostTimeUnitsToSec(idleInUnits)
                if idleInSec > FREEWHEELING_PERIOD_IN_SECONDS {
                    _ = suspendDisplayLink()
                }
                
                // Release captured CMSampleBuffer
                newSampleBuffer = nil
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
