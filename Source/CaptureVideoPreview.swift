//
//  CaptureVideoPreview.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2017/10/31.
//  Copyright © 2017-2024 MyCometG3. All rights reserved.
//

import Cocoa
import AVFoundation
import CoreVideo

/// Helper class to support CVDisplayLinkOutputHandler (nonisolated sync support)
fileprivate final class CaptureVideoPreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return block()
    }
    
    private var preparedValue: Bool = false
    private var donotEnqueueValue: Bool = false
    
    var prepared: Bool {
        withLock { preparedValue }
    }
    func updatePrepared(_ value: Bool) {
        withLock { preparedValue = value }
    }
    var donotEnqueue: Bool {
        withLock { donotEnqueueValue }
    }
    func updateDonotEnqueue(_ value: Bool) {
        withLock { donotEnqueueValue = value }
    }
}

@MainActor
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
    
    /// Prepared or not
    public var prepared :Bool {
        get {
            return cache.prepared
        }
        set {
            cache.updatePrepared(newValue)
        }
    }
    
    /* ================================================ */
    // MARK: - private properties
    /* ================================================ */
    
    /// Initial value of hostTime - used for media timebase
    private var baseHostTime :UInt64 = 0
    
    /// Initial value of hostTime offset in sec - used for media timebase
    private var baseOffsetInSec :Float64 = 0.0
    
    /// Debug mode
    public let debugLog = false
    
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
        get {
            return cache.donotEnqueue
        }
        set {
            cache.updateDonotEnqueue(newValue)
        }
    }
    
    /// CADisplayLink
    /// - NOTE: CADisplayLink is undef before macOS 14.0.
    /// - NOTE: @available(macOS 14.0, *) does not work w/ stored property.
    private var caDisplayLink: AnyObject? = nil // use AnyObject to avoid @available check
    
    /// CVDisplayLink
    private var displayLink :CVDisplayLink? = nil
    
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
        // setup() moved from awakeFromNib()
    }
    
    override public func awakeFromNib() {
        super.awakeFromNib()
        
        // setup() moved to init(coder:)
    }
    
    deinit {
        precondition(cache.prepared == false, "CaptureVideoPreview should be shutdown before deinit.")
        
        /*
         TODO: async operation is not allowed in deinit
         
         await cleanup()
         */
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
    public func prepareWithDisplayLink(_ useDisplayLink: Bool = true, _ preferCADisplayLink: Bool = true) {
        self.useDisplayLink = useDisplayLink
        self.preferCADisplayLink = preferCADisplayLink
        prepare()
    }
    
    /// Prepare videoPreview and CVDisplayLink.
    public func prepare() {
        if prepared {
            if verbose {
                print("CaptureVideoPreview.\(#function)")
                print("NOTICE: CaptureVideoPreview is already prepared. (\(#function))")
            }
            return
        }
        if verbose {
            print("CaptureVideoPreview.\(#function)")
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
        if !prepared {
            if verbose {
                print("CaptureVideoPreview.\(#function)")
                print("NOTICE: CaptureVideoPreview is not prepared. (\(#function))")
            }
            return
        }
        if verbose {
            print("CaptureVideoPreview.\(#function)")
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
        Task(priority: .high) { [weak self] in
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
            if verbose {
                print("CaptureVideoPreview.\(#function)")
                print("NOTICE: DisplayLink is suspended. Ignore enqueue request. (\(#function))")
            }
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
            if verbose {
                print("CaptureVideoPreview.\(#function)")
                print("INFO: Update video sample property.")
            }
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
            print("Enqueue: start(\(strStart)) end(\(strEnd)) dur(\(strDuration))")
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
                    if verbose {
                        var eStr = ""
                        if !statusOK { eStr += "StatusFailed " }
                        if !ready { eStr += "NotReady " }
                        print("CaptureVideoPreview.\(#function)")
                        print("ERROR:(Instant queueing): videoLayer is not ready to enqueue. \(eStr)")
                    }
                    
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
                if verbose {
                    print("CaptureVideoPreview.\(#function)")
                    print("ERROR: Failed to setup videoLayer's controlTimebase")
                }
            }
        } else {
            if verbose {
                print("CaptureVideoPreview.\(#function)")
                print("ERROR: Failed to setup videoLayer.")
            }
        }
    }
    
    /// clean up func
    private func cleanup() {
        shutdown()
        
        videoLayer = nil
    }
    
    /* ================================================ */
    // MARK: - CALayerDelegate and more
    /* ================================================ */
    
    /// Runs a non-throwing `@MainActor`-isolated closure synchronously.
    /// - Parameter block: A non-throwing closure isolated to the main actor.
    /// - Returns: The result of the closure's operation.
    /// - Warning: Blocks the calling thread if not already on the main thread, potentially causing UI freezes.
    nonisolated func performSyncOnMainActor<T: Sendable>(_ block: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                block()
            }
        } else {
            return DispatchQueue.main.sync {
                return MainActor.assumeIsolated {
                    block()
                }
            }
        }
    }
    
    /// Wrapper for CALayer to use in nonisolated context
    private struct UnsafeLayerWrapper: @unchecked Sendable {
        var layer: CALayer
    }
    
    /// Perform layoutSublayersCore on MainActor (CALayerDelegate protocol conformance)
    /// - Parameter targetLayer: target CALayer to layout
    nonisolated public func layoutSublayers(of targetLayer: CALayer) {
        let targetLayerWrapper = UnsafeLayerWrapper(layer: targetLayer)
        performSyncOnMainActor {
            let targetLayer = targetLayerWrapper.layer
            layoutSublayersCore(of: targetLayer)
        }
    }
    
    /// Perform layoutSublayersCore on MainActor
    /// - Parameter block: block to perform
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
                    
                    if debugLog {
                        print("CaptureVideoPreview.\(#function)")
                        print("\(#function): \(layerSize.debugDescription)")
                    }
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
        if verbose {
            print("CaptureVideoPreview.\(#function)")
        }
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
            print("NOTICE:\(#function) baseHostTime(s) = \(baseHostTimeInSecStr), baseOffset(s) = \(baseOffsetInSecStr)")
        }
    }
    
    /// Flush current image on videoLayer
    private func flushImage() {
        if verbose {
            print("CaptureVideoPreview.\(#function)")
        }
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
        if verbose {
            print("CaptureVideoPreview.\(#function)")
        }
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
                        if verbose {
                            print("NOTICE: DisplayLink is suspended. Ignore enqueue request (\(#function))")
                        }
                    }
                    return kCVReturnError
                }
                
                let refreshInterval = videoRefreshIntervalFromTimeStamp(inNowTS.pointee)! // refresh interval in seconds
                let lastVSync = videoTimeIntervalFromTimeStamp(inNowTS.pointee)! // last vsync (current frame)
                let targetTimestamp = videoTimeIntervalFromTimeStamp(inOutTS.pointee)! // deadline for next frame
                let nextVSync = lastVSync + refreshInterval // next vsync (next frame)
                let expiredTimestamp = nextVSync + refreshInterval // next frame expired
                
                // Schedule enqueue on MainActor
                Task(priority: .high) { @MainActor in
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
            if verbose {
                print("CaptureVideoPreview.\(#function)")
                print("NOTICE: DisplayLink is suspended. Ignore enqueue request (\(#function))")
            }
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
                    
                    print("CaptureVideoPreview.\(#function)")
                    print("NOTICE:\(targetTimestampStr): enqueue start(\(strStart)) end(\(strEnd)) dur(\(strDuration)) mediaTime(\(mediaTimeInSecStr):\(missedStr):\(outdatedStr))")
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
                print("CaptureVideoPreview.\(#function)")
                print("ERROR:\(targetTimestampStr): videoLayer is not ready to enqueue. \(eStr)")
            }
            
            flushImage()
        } else {
            if debugLog {
                let targetTimestampStr = String(format: "%012.3f", targetTimestamp)
                print("CaptureVideoPreview.\(#function)")
                print("NOTICE:\(targetTimestampStr): No sampleBuffer to enqueue. ")
            }
        }
        
        // experimental: suspend DisplayLink if idle
        if suspendDisplayLinkOnIdle {
            // Suspend DisplayLink if idle
            let idleTime = CVGetCurrentHostTime() - lastQueuedHostTime
            let idleTimeInSec = timeIntervalFromHostTime(idleTime)
            if idleTimeInSec > FREEWHEELING_PERIOD_IN_SECONDS {
                if verbose {
                    let targetTimestampStr = String(format: "%012.3f", targetTimestamp)
                    let idleTimeInSecStr = String(format: "%08.3f", idleTimeInSec)
                    print("CaptureVideoPreview.\(#function)")
                    print("NOTICE:\(targetTimestampStr):\(idleTimeInSecStr): No enqueue - Consider to suspend DisplayLink.")
                }
                //_ = suspendDisplayLink()
            }
            else {
                if debugLog {
                    let targetTimestampStr = String(format: "%012.3f", targetTimestamp)
                    let idleTimeInSecStr = String(format: "%08.3f", idleTimeInSec)
                    print("CaptureVideoPreview.\(#function)")
                    print("NOTICE:\(targetTimestampStr):\(idleTimeInSecStr): No enqueue.")
                }
            }
        }
        return false
    }
    
    /// Shutdown DisplayLink and release resources.
    private func shutdownDisplayLink() {
        if verbose {
            print("CaptureVideoPreview.\(#function)")
        }
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
        if verbose {
            print("CaptureVideoPreview.\(#function)")
        }
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

/* ================================================ */
// MARK: - Video SampleBuffer Helper
/* ================================================ */

fileprivate final class VideoSampleBufferHelper: @unchecked Sendable {
    /* ================================================ */
    // MARK: - public properties
    /* ================================================ */
    
    /// sampleBuffer native pixel aspect ratio (pasp ImageDescription Extension)
    public private(set) var sampleAspectRatio :CGFloat? = nil
    /// image size of encoded rect
    public private(set) var sampleEncodedSize :CGSize? = nil
    /// image size of clean aperture (aspect ratio applied)
    public private(set) var sampleCleanSize : CGSize? = nil
    /// image size of encoded rect (aspect ratio applied)
    public private(set) var sampleProductionSize :CGSize? = nil
    
    /* ================================================ */
    // MARK: - private properties
    /* ================================================ */
    
    /// CVPixelBufferPool
    private var pixelBufferPool :CVPixelBufferPool? = nil
    
    /* ================================================ */
    // MARK: - public functions (duplicate sampleBuffer)
    /* ================================================ */
    
    /// Duplicate CMSampleBuffer with new CVPixelBuffer.
    /// - Parameter sbwIn: source UnsafeSampleBufferWrapper
    /// - Returns: new UnsafeSampleBufferWrapper with duplicated CVPixelBuffer
    public func deeperCopyVideoSampleBufferAsync(sbwIn :UnsafeSampleBufferWrapper) async -> UnsafeSampleBufferWrapper? {
        var sbwOut: UnsafeSampleBufferWrapper? = nil
        sbwOut = await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return nil }
            
            let sbIn = sbwIn.sampleBuffer
            
            // Duplicate CMSampleBuffer with new CVPixelBuffer
            let sbOut:CMSampleBuffer? = self.deeperCopyVideoSampleBuffer(sbIn: sbIn)
            if let sbOut = sbOut {
                // Create new UnsafeSampleBufferWrapper
                return UnsafeSampleBufferWrapper(sampleBuffer: sbOut)
            } else {
                // Return nil if copy failed
                return nil
            }
        }.value
        return sbwOut
    }
    
    /// Duplicate CMSampleBuffer with new CVPixelBuffer.
    /// - Parameter sbIn: source CMSampleBuffer
    /// - Returns: new CMSampleBuffer with duplicated CVPixelBuffer
    public func deeperCopyVideoSampleBuffer(sbIn :CMSampleBuffer) -> CMSampleBuffer? {
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
            duplicatePixelBuffer(pb, &pbOut)
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
    // MARK: - private functions (duplicate pixelBuffer)
    /* ================================================ */
    
    /// Duplicate CVPixelBuffer using CVPixelBufferPool.
    /// - Parameters:
    ///  - pb: source CVPixelBuffer
    ///  - pbOut: output CVPixelBuffer
    private func duplicatePixelBuffer(_ pb: CVPixelBuffer, _ pbOut: inout CVBuffer?) {
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
            precondition(err == kCVReturnSuccess, "ERROR: Failed to create CVPixelBufferPool")
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
    
    /* ================================================ */
    // MARK: - public functions (sampleBuffer attachments)
    /* ================================================ */
    
    /// Mark sampleBuffer as DisplayImmediately
    /// - Parameter sbwIn: UnsafeSampleBufferWrapper
    /// @discussion: This will force sampleBuffer to be displayed immediately.
    public func refreshImage(_ sbwIn :UnsafeSampleBufferWrapper) {
        let sbIn = sbwIn.sampleBuffer
        refreshImage(sbIn)
    }
    
    /// Mark sampleBuffer as DoNotDisplay
    /// - Parameter sbwIn: UnsafeSampleBufferWrapper
    /// @discussion: This will force sampleBuffer to be skipped.
    public func donotDisplayImage(_ sbwIn :UnsafeSampleBufferWrapper) {
        let sbIn = sbwIn.sampleBuffer
        donotDisplayImage(sbIn)
    }
    
    /// Mark sampleBuffer as DisplayImmediately
    ///
    /// - Parameter sampleBuffer: CMSampleBuffer
    /// @discussion: This will force sampleBuffer to be displayed immediately.
    public func refreshImage(_ sampleBuffer: CMSampleBuffer) {
        if let attachments :CFArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let ptr :UnsafeRawPointer = CFArrayGetValueAtIndex(attachments, 0)
            let dict = fromOpaque(ptr, CFMutableDictionary.self)
            let key = toOpaque(kCMSampleAttachmentKey_DisplayImmediately)
            let value = toOpaque(kCFBooleanTrue)
            CFDictionarySetValue(dict, key, value)
        }
        else { preconditionFailure("attachments is nil") }
    }
    
    /// Mark sampleBuffer as DoNotDisplay
    ///
    /// - Parameter sampleBuffer: CMSampleBuffer
    /// @discussion: This will prevent sampleBuffer from being displayed.
    public func donotDisplayImage(_ sampleBuffer: CMSampleBuffer) {
        if let attachments :CFArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let ptr :UnsafeRawPointer = CFArrayGetValueAtIndex(attachments, 0)
            let dict = fromOpaque(ptr, CFMutableDictionary.self)
            let key = toOpaque(kCMSampleAttachmentKey_DoNotDisplay)
            let value = toOpaque(kCFBooleanFalse)
            CFDictionarySetValue(dict, key, value)
        }
        else { preconditionFailure("attachments is nil") }
    }
    
    /* ================================================ */
    // MARK: - public functions (sampleBuffer properties)
    /* ================================================ */
    
    /// Update sampleRect properties from UnsafeSampleBufferWrapper.
    /// - Parameter sbwIn: UnsafeSampleBufferWrapper to update
    /// - Returns: True if sampleRect properties are updated, false if not.
    public func updateSampleRect(_ sbwIn :UnsafeSampleBufferWrapper) -> Bool {
        let sbIn = sbwIn.sampleBuffer
        return updateSampleRect(sbIn)
    }
    
    /// Update sampleRect properties from sampleBuffer.
    /// - Parameter sampleBuffer: CMSampleBuffer to update
    /// - Returns: True if sampleRect properties are updated, false if not.
    public func updateSampleRect(_ sampleBuffer :CMSampleBuffer) -> Bool {
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
                
                return true
            }
        }
        return false
    }
    
    /* ================================================ */
    // MARK: - private functions (sampleBuffer properties)
    /* ================================================ */
    
    //
    private var useCast :Bool = true
    
    /// CFObject to UnsafeRawPointer conversion
    /// - Parameter obj: AnyObject to convert
    /// - Returns: UnsafeRawPointer
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
    
    /// UnsafeRawPointer to CFObject conversion
    /// - Parameters:
    ///  - ptr: UnsafeRawPointer to convert
    ///  - type: Type of CFObject to convert
    ///  - Returns: CFObject of specified type
    private func fromOpaque<T :AnyObject>(_ ptr :UnsafeRawPointer, _ type :T.Type) -> T {
        let val = Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
        return val
    }
    
    /// Extract CFDictionary attachment of specified key from CVPixelBuffer
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
}
