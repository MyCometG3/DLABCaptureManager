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

public class CaptureVideoPreview: NSView {
    /* ================================================ */
    // MARK: - public properties
    /* ================================================ */
    
    /// Backing layer of AVSampleBufferDisplayLayer
    public private(set) var videoLayer :AVSampleBufferDisplayLayer? = nil
    
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
    
    /* ================================================ */
    // MARK: - public functions
    /* ================================================ */
    
    /// Prepare videoPreview and CVDisplayLink.
    public func prepare() {
        queueSync {
            // Clean up first
            shutdown()
            
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
        }
    }
    
    /// Enqueue new Video CMSampleBuffer
    ///
    /// - Parameter sampleBuffer: Video CMSampleBuffer
    /// - Returns: False if failed to enqueue
    public func queueSampleBuffer(_ sampleBuffer :CMSampleBuffer) -> Bool {
        var result :Bool = false
        queueSync {
            if useDisplayLink {
                // Check/Activate displayLink
                result = activateDisplayLink()
                if !result {
                    print("ERROR: DisplayLink is not ready.")
                    return
                }
            } else {
                result = true
            }
            
            // Retain new sampleBuffer
            self.newSampleBuffer = sampleBuffer
            
            if self.baseHostTime == 0 {
                // Initialize Timebase - This is first sampleBuffer
                resetTimebase(sampleBuffer)
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
                    } else {
                        var eStr = ""
                        if !statusOK { eStr += "StatusFailed " }
                        if !ready { eStr += "NotReady " }
                        print("ERROR: videoLayer is not ready to enqueue. \(eStr)")
                    }
                }
            }
        }
        return result
    }
    
    /* ================================================ */
    // MARK: - private functions
    /* ================================================ */
    
    /// Reset timebase using SampleBuffer presentation time
    ///
    /// - Parameter sampleBuffer: timebase source sampleBuffer. Set nil to reset to shutdown.
    private func resetTimebase(_ sampleBuffer :CMSampleBuffer?) {
        queueSync {
            if let sampleBuffer = sampleBuffer {
                // start Media Time from sampleBuffer's presentation time
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if let layer = self.videoLayer, let timebase = layer.controlTimebase {
                    _ = CMTimebaseSetTime(timebase, time)
                    _ = CMTimebaseSetRate(timebase, 1.0)
                }
                
                // Record base HostTime value as video timebase
                self.baseHostTime = CVGetCurrentHostTime()
                self.baseOffsetInSec = CMTimeGetSeconds(time)
            } else {
                // reset Media Time to Zero
                if let layer = self.videoLayer, let timebase = layer.controlTimebase {
                    _ = CMTimebaseSetRate(timebase, 0.0)
                    _ = CMTimebaseSetTime(timebase, kCMTimeZero)
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
        if let videoLayer = videoLayer {
            videoLayer.bounds = self.bounds
            videoLayer.position = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
            videoLayer.videoGravity = .resizeAspect
            videoLayer.backgroundColor = NSColor.gray.cgColor
            
            self.layer = videoLayer
            self.wantsLayer = true
            
            // Create new CMTimebase using HostTimeClock
            let clock :CMClock = CMClockGetHostTimeClock()
            var timebase :CMTimebase? = nil
            let status :OSStatus = CMTimebaseCreateWithMasterClock(kCFAllocatorDefault, clock, &timebase)
            
            // Set controlTimebase
            if status == noErr, let timebase = timebase {
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
        
        if nil != queue.getSpecific(key: processingQueueSpecificKey) {
            block()
        } else {
            queue.sync(execute: block)
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
        queueSync {
            self.lastRequestedHostTime = outHostTime
    
            // Check if no sampleBuffer is queued yet
            if self.baseHostTime == 0 {
                print("ERROR: No video sample is queued yet.")
                return
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
                } else {
                    var eStr = ""
                    if !statusOK { eStr += "StatusFailed " }
                    if !ready { eStr += "NotReady " }
                    print("ERROR: videoLayer is not ready to enqueue. \(eStr)")
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
