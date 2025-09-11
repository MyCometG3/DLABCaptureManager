//
//  CaptureVideoPreview.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2017/10/31.
//  Copyright © 2017-2025 MyCometG3. All rights reserved.
//

import Cocoa
import AVFoundation
import CoreVideo

/// Thread safe backing store - works with deinit and nonisolated func.
fileprivate final class CaptureVideoPreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return block()
    }
    
    private var preparedValue: Bool = false
    var prepared: Bool {
        get { withLock { preparedValue } }
        set { withLock { preparedValue = newValue } }
    }
    private var donotEnqueueValue: Bool = false
    var donotEnqueue: Bool {
        get { withLock { donotEnqueueValue } }
        set { withLock { donotEnqueueValue = newValue } }
    }
    private var verboseValue: Bool = false
    var verbose: Bool {
        get { withLock { verboseValue } }
        set { withLock { verboseValue = newValue } }
    }
    private var debugLogValue: Bool = false
    var debugLog: Bool {
        get { withLock { debugLogValue } }
        set { withLock { debugLogValue = newValue } }
    }
    
    private var videoLayerValue: AVSampleBufferDisplayLayer? = nil
    var videoLayer: AVSampleBufferDisplayLayer? {
        get { withLock { videoLayerValue } }
        set { withLock { videoLayerValue = newValue } }
    }
    private var caDisplayLinkValue: AnyObject? = nil
    var caDisplayLink: AnyObject? {
        get { withLock { caDisplayLinkValue } }
        set { withLock { caDisplayLinkValue = newValue } }
    }
    private var displayLinkValue: CVDisplayLink? = nil
    var displayLink :CVDisplayLink? {
        get { withLock { displayLinkValue } }
        set { withLock { displayLinkValue = newValue } }
    }
}

@MainActor
public class CaptureVideoPreview: NSView, CALayerDelegate {
    /* ================================================ */
    // MARK: - public properties
    /* ================================================ */
    
    /// Backing layer of AVSampleBufferDisplayLayer
    public private(set) var videoLayer :AVSampleBufferDisplayLayer? {
        get { cache.videoLayer }
        set { cache.videoLayer = newValue }
    }
    
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
    public var verbose :Bool {
        get { cache.verbose }
        set { cache.verbose = newValue }
    }
    
    /// Debug mode
    public var debugLog: Bool {
        get { cache.debugLog }
        set { cache.debugLog = newValue }
    }
    
    /// Prepared or not
    private var prepared :Bool {
        get { cache.prepared }
        set { cache.prepared = newValue }
    }
    
    /* ================================================ */
    // MARK: - private properties
    /* ================================================ */
    
    /// Initial value of hostTime - used for media timebase
    private var baseHostTime :UInt64 = 0
    
    /// Initial value of hostTime offset in sec - used for media timebase
    private var baseOffsetInSec :Float64 = 0.0
    
    /// Enqueued hostTime
    private var lastQueuedHostTime :UInt64 = 0
    
    /// CaptureVideoPreview cache w/ nonisolated func support
    nonisolated private let cache = CaptureVideoPreviewCache()
    
    /// SampleBufferHelper
    private let sbHelper = VideoSampleBufferHelper()
    
    /* ================================================ */
    // MARK: - private properties (displayLink)
    /* ================================================ */
    
    /// Configure DisplayLink - CADisplayLink or CVDisplayLink
    private var useDisplayLink = true
    private var preferCADisplayLink = true
    
    /// Background queueing flag (Thread-safe)
    private var donotEnqueue: Bool {
        get { cache.donotEnqueue }
        set { cache.donotEnqueue = newValue }
    }
    
    /// CADisplayLink
    /// - NOTE: CADisplayLink is undef before macOS 14.0.
    /// - NOTE: @available(macOS 14.0, *) does not work w/ stored property.
    /// - NOTE: use AnyObject to avoid @available check
    private var caDisplayLink: AnyObject? {
        get { cache.caDisplayLink }
        set { cache.caDisplayLink = newValue }
    }
    
    /// CVDisplayLink
    private var displayLink :CVDisplayLink? {
        get { cache.displayLink }
        set { cache.displayLink = newValue }
    }
    
    /// Suspend DisplayLink on idle (experimental)
    private var suspendDisplayLinkOnIdle: Bool = false
    
    /// Idle monitor limitation in seconds (experimental)
    private var FREEWHEELING_PERIOD_IN_SECONDS :Float64 = 1.0
    
    /// VideoSampleBuffer to enqueue on Output Handler
    private var newSampleBuffer :CMSampleBuffer? = nil
    
    /// Handles sampleBuffers that arrive late
    private var useDisplayImmediatelyFlag :Bool = true
    
    /// Handles sampleBuffers that arrive too late
    private var useDoNotDisplayFlag :Bool = true
    
    /* ================================================ */
    // MARK: - General NSView methods
    /* ================================================ */
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        
        setup()
    }
    
    required public init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
        
        setup()
    }
    
    override public func awakeFromNib() {
        super.awakeFromNib()
        
        // setup() moved to init(coder:)
    }
    
    deinit {
        deinitHelper()
    }
    
    nonisolated private func deinitHelper() {
        printVerbose("CaptureVideoPreview.\(#function)")
        if !cache.prepared {
            return
        }
        
        cache.prepared = false
        cache.donotEnqueue = true
        
        if let caDisplayLink = cache.caDisplayLink, #available(macOS 14.0, *) {
            caDisplayLink.invalidate()
            cache.caDisplayLink = nil
        } else {
            let notification = NSWindow.didChangeScreenNotification
            NotificationCenter.default.removeObserver(self,
                                                      name: notification,
                                                      object: nil)
            if let displayLink = cache.displayLink {
                if CVDisplayLinkIsRunning(displayLink) {
                    _ = CVDisplayLinkStop(displayLink)
                }
                cache.displayLink = nil
            }
        }
        
        if let videoLayer = cache.videoLayer {
            videoLayer.removeFromSuperlayer()
            cache.videoLayer = nil
        }
    }
    
    override public var wantsUpdateLayer: Bool {
        return true
    }
    
    override public func updateLayer() {
        if useDisplayLink, prepared {
            _ = activateDisplayLink()
        }
        layoutSublayersCore(of: layer!)
    }
    
    /* ================================================ */
    // MARK: - public functions
    /* ================================================ */
    
    /// Prepare videoPreview with DisplayLink.
    /// - Parameters:
    ///   - useDisplayLink: true to use DisplayLink, false to use instant enqueue.
    ///   - preferCADisplayLink: true to prefer CADisplayLink over CVDisplayLink
    /// - NOTE: CADisplayLink requires  macOS 14.0 or later.
    public func prepareWithDisplayLink(useDisplayLink: Bool = true, preferCADisplayLink: Bool = true) {
        self.useDisplayLink = useDisplayLink
        self.preferCADisplayLink = preferCADisplayLink
        prepare()
    }
    
    /// Prepare videoPreview and CVDisplayLink.
    public func prepare() {
        printVerbose("CaptureVideoPreview.\(#function)")
        if prepared {
            printVerbose("NOTICE: CaptureVideoPreview is already prepared. (\(#function))")
            return
        }
        do {
            guard let baseLayer = layer else {
                preconditionFailure("baseLayer is not available.")
            }
            guard let videoLayer = videoLayer else {
                preconditionFailure("videoLayer is not available.")
            }
            
            // Initialize Timebase
            resetTimebase(nil)
            flushImage()
            
            // Add CMSampleBufferDisplayLayer to SubLayer
            if videoLayer.superlayer == nil {
                baseLayer.addSublayer(videoLayer)
            }
            
            if useDisplayLink {
                prepareDisplayLink()
            }
            
            prepared = true
            donotEnqueue = !prepared
        }
    }
    
    /// Shutdown videoPreview and CVDisplayLink.
    public func shutdown() {
        printVerbose("CaptureVideoPreview.\(#function)")
        if !prepared {
            printVerbose("NOTICE: CaptureVideoPreview is not prepared. (\(#function))")
            return
        }
        do {
            guard let videoLayer = videoLayer else {
                preconditionFailure("videoLayer is not available.")
            }
            
            prepared = false
            donotEnqueue = !prepared
            
            if useDisplayLink {
                shutdownDisplayLink()
            }
            
            // Remove CMSampleBufferDisplayLayer from SubLayer
            if videoLayer.superlayer != nil {
                videoLayer.removeFromSuperlayer()
            }
            
            // Initialize Timebase
            resetTimebase(nil)
            flushImage()
            
            //
            lastQueuedHostTime = 0
            
            //
            sampleAspectRatio = nil
            sampleEncodedSize = nil
            sampleCleanSize = nil
            sampleProductionSize = nil
        }
    }
    
    /// Non-blocking enqueue of CMSampleBuffer.
    /// - Parameter sb: Video CMSampleBuffer
    public nonisolated func queueSampleBuffer(_ sb: CMSampleBuffer) {
        let info = UnsafeSampleBufferWrapper(sampleBuffer: sb)
        Task { [weak self] in
            guard let self = self else { return }
            await self.queueSampleBufferAsync(info.sampleBuffer)
        }
    }
    
    public func queueSampleBufferAsync(wrapper sb: UnsafeSampleBufferWrapper) async {
        await queueSampleBufferAsync(sb.sampleBuffer)
    }
    
    /// Enqueue new Video CMSampleBuffer
    ///
    /// - Parameter sampleBuffer: Video CMSampleBuffer
    /// - @discussion: If `useDisplayLink` is false, this function will enqueue sampleBuffer immediately to AVSampleBufferDisplayLayer.
    public func queueSampleBufferAsync(_ sb :CMSampleBuffer) async {
        if donotEnqueue {
            printVerbose("CaptureVideoPreview.\(#function)",
                         "NOTICE: DisplayLink is suspended. Ignore enqueue request. (\(#function))")
            return
        }
        
        //
        let sbwIn = UnsafeSampleBufferWrapper(sampleBuffer: sb)
        let sbwOut = await sbHelper.deeperCopyVideoSampleBufferAsync(sbwIn: sbwIn)
        guard let sampleBuffer = sbwOut?.sampleBuffer else {
            preconditionFailure("Failed to duplicate CMSampleBuffer")
        }
        
        // Parse ImageBuffer properties of CMSampleBuffer
        if sbHelper.updateSampleRect(sbwIn) {
            sampleAspectRatio = sbHelper.sampleAspectRatio
            sampleEncodedSize = sbHelper.sampleEncodedSize
            sampleCleanSize = sbHelper.sampleCleanSize
            sampleProductionSize = sbHelper.sampleProductionSize
            printVerbose("CaptureVideoPreview.\(#function)",
                         "INFO: Update video sample property.")
            
            // Ensure latest SampleRect/AspectRatio applied
            needsDisplay = true
        }
        
        // Debugging
        let startTime :CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration :CMTime = CMSampleBufferGetDuration(sampleBuffer)
        let endTime :CMTime = CMTimeAdd(startTime, duration)
        let startInSec :Float64 = CMTimeGetSeconds(startTime)
        let durationInSec :Float64 = CMTimeGetSeconds(duration)
        let endInSec :Float64 = CMTimeGetSeconds(endTime)
        if debugLog {
            let strStart = String(format:"%08.3f", startInSec)
            let strEnd = String(format:"%08.3f", endInSec)
            let strDuration = String(format:"%08.3f", durationInSec)
            printDebug("Enqueue: start(\(strStart)) end(\(strEnd)) dur(\(strDuration))")
        }
        
        // Initialize Timebase if this is first sampleBuffer
        if baseHostTime == 0 {
            resetTimebase(sampleBuffer)
            flushImage()
        }
        
        //
        if useDisplayLink {
            // Keep this for next displayLink callback
            newSampleBuffer = sampleBuffer
        } else {
            // Instant queueing
            do {
                guard let vLayer = videoLayer else {
                    preconditionFailure("videoLayer is nil")
                }
                
                let statusOK :Bool = (vLayer.status != .failed)
                let ready :Bool = vLayer.isReadyForMoreMediaData
                if statusOK && ready {
                    
                    // Enqueue samplebuffer
                    vLayer.enqueue(sampleBuffer)
                    lastQueuedHostTime = CVGetCurrentHostTime()
                    
                    // Release enqueued CMSampleBuffer
                    newSampleBuffer = nil
                    
                } else {
                    var eStr = ""
                    if !statusOK { eStr += "StatusFailed " }
                    if !ready { eStr += "NotReady " }
                    printVerbose("CaptureVideoPreview.\(#function)",
                                 "ERROR:(Instant queueing): videoLayer is not ready to enqueue. \(eStr)")
                    
                    flushImage()
                }
            }
        }
    }
    
    /* ================================================ */
    // MARK: - private functions
    /* ================================================ */
    
    /// Common initialization func
    private func setup() {
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
                printVerbose("CaptureVideoPreview.\(#function)",
                             "ERROR: Failed to setup videoLayer's controlTimebase")
            }
        } else {
            printVerbose("CaptureVideoPreview.\(#function)",
                         "ERROR: Failed to setup videoLayer.")
        }
    }
    
    nonisolated internal func printVerbose(_ message: String...) {
        if cache.verbose {
            let output = message.joined(separator: "\n")
            print(output)
        }
    }
    
    nonisolated internal func printDebug(_ message: String...) {
        if cache.debugLog {
            let output = message.joined(separator: "\n")
            print(output)
        }
    }
    
    /* ================================================ */
    // MARK: - CALayerDelegate and more
    /* ================================================ */
    
    /// Wrapper for CALayer to use in nonisolated context
    private struct UnsafeLayerWrapper: @unchecked Sendable {
        var layer: CALayer
    }
    
    /// Perform layoutSublayersCore on MainActor (CALayerDelegate protocol conformance)
    /// - Parameter targetLayer: target CALayer to layout
    nonisolated public func layoutSublayers(of targetLayer: CALayer) {
        let targetLayerWrapper = UnsafeLayerWrapper(layer: targetLayer)
        Task { @MainActor in
            let targetLayer = targetLayerWrapper.layer
            layoutSublayersCore(of: targetLayer)
        }
    }
    
    /// Perform layoutSublayersCore on MainActor
    /// - Parameter targetLayer: target CALayer to layout
    private func layoutSublayersCore(of targetLayer: CALayer) {
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
                    
                    printDebug("CaptureVideoPreview.\(#function)",
                               layerSize.debugDescription)
                }
            }
        }
    }
    
    /// Calculate preferred size of videoLayer
    /// - Parameter vLayer: AVSampleBufferDisplayLayer
    /// - Returns: CGSize of preferred size
    private func preferredSize(of vLayer :AVSampleBufferDisplayLayer) -> CGSize {
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
            } else {
                printDebug("CaptureVideoPreview.\(#function)",
                           "WARNING: sampleEncodedSize or sampleProductionSize is not available.")
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
        printVerbose("CaptureVideoPreview.\(#function)")
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
        if debugLog {
            let baseHostTimeInSecStr = String(format:"%012.3f", timeIntervalFromHostTime(baseHostTime))
            let baseOffsetInSecStr = String(format:"%08.3f", baseOffsetInSec)
            printDebug("NOTICE:\(#function) baseHostTime(s) = \(baseHostTimeInSecStr), baseOffset(s) = \(baseOffsetInSecStr)")
        }
    }
    
    /// Flush current image on videoLayer
    private func flushImage() {
        printVerbose("CaptureVideoPreview.\(#function)")
        if let vLayer = videoLayer {
            vLayer.flushAndRemoveImage()
        }
        else { preconditionFailure("videoLayer is nil") }
    }
    
    /* ================================================ */
    // MARK: - private functions (DisplayLink)
    /* ================================================ */
    
    /// Setup DisplayLink
    /// @discussion Under macOS 14.0 and later, CADisplayLink is used instead of CVDisplayLink.
    private func prepareDisplayLink() {
        printVerbose("CaptureVideoPreview.\(#function)")
        donotEnqueue = false
        
        if preferCADisplayLink, #available(macOS 14.0, *) {
            // Create CADisplayLink
            let selector = #selector(handleCADisplayLink(_:))
            let newCADisplayLink = self.displayLink(target: self, selector: selector)
            caDisplayLink = newCADisplayLink
            
            // Register DisplayLink
            newCADisplayLink.add(to: .main, forMode: .common)
        } else {
            // Create CVDisplayLink
            var newDisplayLink :CVDisplayLink? = nil
            _ = CVDisplayLinkCreateWithActiveCGDisplays(&newDisplayLink)
            
            guard let newDisplayLink = newDisplayLink else { return }
            
            // Define OutputHandler
            let outputHandler :CVDisplayLinkOutputHandler = { [weak self]
                (inDL :CVDisplayLink, inNowTS :UnsafePointer<CVTimeStamp>,
                 inOutTS :UnsafePointer<CVTimeStamp>, inFlags :CVOptionFlags,
                 outFlags :UnsafeMutablePointer<CVOptionFlags>
                ) -> CVReturn in
                
                guard let self = self else { return kCVReturnError }
                
                if cache.donotEnqueue {
                    Task { @MainActor in
                        printVerbose("NOTICE: DisplayLink is suspended. Ignore enqueue request (\(#function))")
                    }
                    return kCVReturnError
                }
                
                let refreshInterval = videoRefreshIntervalFromTimeStamp(inNowTS.pointee)! // refresh interval in seconds
                let lastVSync = videoTimeIntervalFromTimeStamp(inNowTS.pointee)! // last vsync (current frame)
                let targetTimestamp = videoTimeIntervalFromTimeStamp(inOutTS.pointee)! // deadline for next frame
                let nextVSync = lastVSync + refreshInterval // next vsync (next frame)
                let expiredTimestamp = nextVSync + refreshInterval // next frame expired
                
                // Schedule enqueue on MainActor
                Task { @MainActor in
                    enqueue(targetTimestamp, expiredTimestamp)
                }
                return kCVReturnSuccess
            }
            _ = CVDisplayLinkSetOutputHandler(newDisplayLink, outputHandler)
            
            // Set displayLink
            displayLink = newDisplayLink
            
            // Set displayID
            updateDisplayLink()
            
            // Register observer
            let selector = #selector(CaptureVideoPreview.updateDisplayLink)
            let notification = NSWindow.didChangeScreenNotification
            NotificationCenter.default.addObserver(self,
                                                   selector: selector,
                                                   name: notification,
                                                   object: nil)
        }
    }
    
    /// Enqueue latest sampleBuffer to videoLayer using DisplayLink
    /// - Parameter displayLink: CADisplayLink
    @available(macOS 14.0, *)
    @objc func handleCADisplayLink(_ displayLink: CADisplayLink) {
        // CFTimeInterval is in seconds
        // lastVSync + refreshInterval = nextVSync
        // lastVSync < CACurrentMediaTime() < targetTimestamp < nextVSync
        
        let refreshInterval = displayLink.duration // refresh interval in seconds
        let lastVSync = displayLink.timestamp // last vsync (current frame)
        let targetTimestamp = displayLink.targetTimestamp // deadline for next frame
        let nextVSync = lastVSync + refreshInterval // next vsync (next frame)
        let expiredTimestamp = nextVSync + displayLink.duration // next frame expired
        
        _ = enqueue(targetTimestamp, expiredTimestamp)
    }
    
    /// Enqueue latest sampleBuffer to videoLayer using DisplayLink
    /// - Parameters:
    ///  - targetTimestamp: CFTimeInterval for next frame
    ///  - expiredTimestamp: CFTimeInterval for next frame expired
    ///  - Returns: True if sampleBuffer is enqueued, false if not.
    private func enqueue(_ targetTimestamp: CFTimeInterval, _ expiredTimestamp: CFTimeInterval) -> Bool {
        if donotEnqueue {
            printVerbose("CaptureVideoPreview.\(#function)",
                         "NOTICE: DisplayLink is suspended. Ignore enqueue request (\(#function))")
            return false
        }
        
        guard let vLayer = videoLayer else {
            preconditionFailure("videoLayer is nil")
        }
        
        if let sampleBuffer = newSampleBuffer {
            let statusOK = (vLayer.status != .failed)
            let ready = vLayer.isReadyForMoreMediaData
            if (statusOK && ready) {
                // Check for late arrival of the sampleBuffer
                let currentMediaTime = CACurrentMediaTime()
                let missedTargetTimestamp = (currentMediaTime > targetTimestamp)
                let outdatedTargetTimestamp = (currentMediaTime > expiredTimestamp)
                
                if outdatedTargetTimestamp, useDoNotDisplayFlag {
                    let sbw = UnsafeSampleBufferWrapper(sampleBuffer: sampleBuffer)
                    sbHelper.donotDisplayImage(sbw) // set kCMSampleAttachmentKey_DoNotDisplay
                } else if missedTargetTimestamp, useDisplayImmediatelyFlag {
                    let sbw = UnsafeSampleBufferWrapper(sampleBuffer: sampleBuffer)
                    sbHelper.refreshImage(sbw)      // set kCMSampleAttachmentKey_DisplayImmediately
                }
                
                // Enqueue samplebuffer
                vLayer.enqueue(sampleBuffer)
                lastQueuedHostTime = CVGetCurrentHostTime()
                
                if debugLog {
                    let startTime :CMTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let duration :CMTime = CMSampleBufferGetDuration(sampleBuffer)
                    let endTime :CMTime = CMTimeAdd(startTime, duration)
                    let startInSec :Float64 = CMTimeGetSeconds(startTime)
                    let durationInSec :Float64 = CMTimeGetSeconds(duration)
                    let endInSec :Float64 = CMTimeGetSeconds(endTime)
                    
                    let strStart = String(format:"%08.3f", startInSec)
                    let strEnd = String(format:"%08.3f", endInSec)
                    let strDuration = String(format:"%08.3f", durationInSec)
                    
                    let mediaTimeInSecStr = String(format:"%012.3f", currentMediaTime)
                    let missedStr = (missedTargetTimestamp ? "MISS" : "OK")
                    let outdatedStr = (outdatedTargetTimestamp ? "OUTDATED" : "OK")
                    
                    let targetTimestampStr = String(format: "%012.3f", targetTimestamp)
                    
                    printDebug("CaptureVideoPreview.\(#function)",
                               "NOTICE:\(targetTimestampStr): enqueue start(\(strStart)) end(\(strEnd)) dur(\(strDuration)) mediaTime(\(mediaTimeInSecStr):\(missedStr):\(outdatedStr))")
                }
                
                // Release enqueued CMSampleBuffer
                newSampleBuffer = nil
                
                return true
            }
            
            if debugLog {
                var eStr = ""
                if !statusOK { eStr += "StatusFailed " }
                if !ready { eStr += "NotReady " }
                let targetTimestampStr = String(format: "%012.3f", targetTimestamp)
                printDebug("CaptureVideoPreview.\(#function)",
                           "ERROR:\(targetTimestampStr): videoLayer is not ready to enqueue. \(eStr)")
            }
            
            flushImage()
        } else {
            if debugLog {
                let targetTimestampStr = String(format: "%012.3f", targetTimestamp)
                printDebug("CaptureVideoPreview.\(#function)",
                           "NOTICE:\(targetTimestampStr): No sampleBuffer to enqueue. ")
            }
        }
        
        // experimental: suspend DisplayLink if idle
        if suspendDisplayLinkOnIdle {
            // Suspend DisplayLink if idle
            let idleTime = CVGetCurrentHostTime() - lastQueuedHostTime
            let idleTimeInSec = timeIntervalFromHostTime(idleTime)
            if idleTimeInSec > FREEWHEELING_PERIOD_IN_SECONDS {
                let targetTimestampStr = String(format: "%012.3f", targetTimestamp)
                let idleTimeInSecStr = String(format: "%08.3f", idleTimeInSec)
                printVerbose("CaptureVideoPreview.\(#function)",
                             "NOTICE:\(targetTimestampStr):\(idleTimeInSecStr): No enqueue - Consider to suspend DisplayLink.")
                
                _ = suspendDisplayLink()
            }
            else {
                if debugLog {
                    let targetTimestampStr = String(format: "%012.3f", targetTimestamp)
                    let idleTimeInSecStr = String(format: "%08.3f", idleTimeInSec)
                    printDebug("CaptureVideoPreview.\(#function)",
                               "NOTICE:\(targetTimestampStr):\(idleTimeInSecStr): No enqueue.")
                }
            }
        }
        return false
    }
    
    /// Shutdown DisplayLink and release resources.
    private func shutdownDisplayLink() {
        printVerbose("CaptureVideoPreview.\(#function)")
        // Avoid enqueueing prior to suspend DisplayLink
        donotEnqueue = true
        newSampleBuffer = nil
        
        do {
            if preferCADisplayLink, #available(macOS 14.0, *) {
                // Remove CADisplayLink
                if let caDisplayLink = caDisplayLink as? CADisplayLink {
                    caDisplayLink.invalidate()
                }
                self.caDisplayLink = nil
            } else {
                // Unregister observer
                NotificationCenter.default.removeObserver(self)
                
                // Remove CVDisplayLink
                if let displayLink = displayLink {
                    if CVDisplayLinkIsRunning(displayLink) {
                        _ = CVDisplayLinkStop(displayLink)
                    }
                }
                self.displayLink = nil
            }
        }
    }
    
    /// Start displayLink with current CGDirectDisplayID.
    ///
    /// - Returns: True if displayLink is running.
    /// @discussion Under macOS 14.0 and later, CADisplayLink is used instead of CVDisplayLink.
    private func activateDisplayLink() -> Bool {
        var result = false;
        do {
            if preferCADisplayLink, #available(macOS 14.0, *) {
                if let caDisplayLink = caDisplayLink as? CADisplayLink {
                    if caDisplayLink.isPaused {
                        caDisplayLink.isPaused = false
                    }
                    result = !caDisplayLink.isPaused
                } else {
                    preconditionFailure("ERROR: CADisplayLink is not valid.")
                }
            } else {
                if let displayLink = displayLink {
                    if !CVDisplayLinkIsRunning(displayLink) {
                        _ = CVDisplayLinkStart(displayLink)
                    }
                    result = CVDisplayLinkIsRunning(displayLink)
                } else {
                    preconditionFailure("ERROR: CVDisplayLink is not valid.")
                }
            }
        }
        
        // Update donotEnqueue flag
        donotEnqueue = !result
        return result
    }
    
    /// Stop displayLink with current CGDirectDisplayID.
    ///
    /// - Returns: True if displayLink is not running.
    /// @discussion Under macOS 14.0 and later, CADisplayLink is used instead of CVDisplayLink.
    private func suspendDisplayLink() -> Bool {
        var result = false;
        do {
            if preferCADisplayLink, #available(macOS 14.0, *) {
                if let caDisplayLink = caDisplayLink as? CADisplayLink {
                    if !caDisplayLink.isPaused {
                        caDisplayLink.isPaused = true
                    }
                    result = caDisplayLink.isPaused
                } else {
                    preconditionFailure("ERROR: CADisplayLink is not valid.")
                }
            } else  {
                if let displayLink = displayLink {
                    if CVDisplayLinkIsRunning(displayLink) {
                        _ = CVDisplayLinkStop(displayLink)
                    }
                    result = !CVDisplayLinkIsRunning(displayLink)
                } else {
                    preconditionFailure("ERROR: CVDisplayLink is not valid.")
                }
            }
        }
        if result {
            donotEnqueue = true
            newSampleBuffer = nil
        }
        return result
    }
    
    /// Update linked CGDirectDisplayID with current view's displayID.
    @objc private func updateDisplayLink() {
        printVerbose("CaptureVideoPreview.\(#function)")
        do {
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
    
    /// Convert hostTime(UInt64) to seconds(Float64)
    ///
    /// - Parameter hostTime: UInt64 value as HostTime
    /// - Returns: Float64 value in seconds
    nonisolated private func timeIntervalFromHostTime(_ hostTime :UInt64) -> Float64 {
        let valueInTime : CMTime = CMClockMakeHostTimeFromSystemUnits(hostTime)
        let valueInSec :Float64 = CMTimeGetSeconds(valueInTime)
        return valueInSec
    }
    
    /// Convert seconds(Float64) to hostTime(UInt64)
    ///
    /// - Parameter seconds: Float64 value in seconds
    /// - Returns: UInt64 value as HostTime
    nonisolated private func hostTimeUnitsFromTimeInterval(_ seconds: Float64) -> UInt64 {
        let valueInCMTime: CMTime = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000_000)
        let hostTimeUnits: UInt64 = CMClockConvertHostTimeToSystemUnits(valueInCMTime)
        return hostTimeUnits
    }
    
    /// Convert CVTimeStamp to hostTime(UInt64)
    /// - Parameter timestamp: CVTimeStamp which contains hostTime
    /// - Returns: Optional UInt64 value as HostTime if valid, nil otherwise
    nonisolated func hostTimeFromTimeStamp(_ timestamp: CVTimeStamp) -> UInt64? {
        // Check if hostTime is valid
        let flags = CVTimeStampFlags(rawValue: timestamp.flags)
        let hostTimeValid: Bool = flags.contains(.hostTimeValid)
        if hostTimeValid {
            return timestamp.hostTime
        }
        return nil
    }
    
    /// Convert CVTimeStamp to seconds(Float64)
    /// - Parameter timestamp: CVTimeStamp which contains videoTime
    /// - Returns: Optional Float64 value in seconds if valid, nil otherwise
    nonisolated func videoTimeIntervalFromTimeStamp(_ timestamp: CVTimeStamp) -> Float64? {
        // Check if videoTime is valid and has a valid scale
        let flags = CVTimeStampFlags(rawValue: timestamp.flags)
        let videoTimeValid: Bool = flags.contains(.videoTimeValid)
        if videoTimeValid && timestamp.videoTimeScale > 0 {
            let valueInCMTime: CMTime = CMTimeMake(value: timestamp.videoTime,
                                                   timescale: timestamp.videoTimeScale)
            return CMTimeGetSeconds(valueInCMTime)
        }
        return nil
    }
    
    /// Convert CVTimeStamp to video refresh interval(Float64)
    /// - Parameter timestamp: CVTimeStamp which contains videoRefreshPeriod
    /// - Returns: Optional Float64 value in seconds if valid, nil otherwise
    nonisolated func videoRefreshIntervalFromTimeStamp(_ timestamp: CVTimeStamp) -> Float64? {
        // Check if videoRefreshPeriod is valid
        let flags = CVTimeStampFlags(rawValue: timestamp.flags)
        let videoRefreshValid: Bool = flags.contains(.videoRefreshPeriodValid)
        if videoRefreshValid && timestamp.videoTimeScale > 0 {
            let valueInCMTime: CMTime = CMTimeMake(value: timestamp.videoRefreshPeriod,
                                                   timescale: timestamp.videoTimeScale)
            return CMTimeGetSeconds(valueInCMTime)
        }
        return nil
    }
}
