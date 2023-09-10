//
//  CaptureAudioPreview.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2017/10/14.
//  Copyright © 2017-2023 MyCometG3. All rights reserved.
//

import Foundation
import CoreMedia
import AudioToolbox

class CaptureAudioPreview: NSObject {
    /* ================================================ */
    // MARK: - private properties
    /* ================================================ */
    
    /// AudioQueueBuffer count to be available
    private let kNumberBuffer = 5
    /// AudioQueueBuffer count to be queued
    private var numEnqueued :Int = 0
    /// AudioQueueBuffer time resolution (per second)
    private let resolution :Float64 = 10.0
    
    /// AudioQueue
    private var audioQueue :AudioQueueRef? = nil
    /// AudioQueueBuffer array
    private var aqBufferRefArray :[AudioQueueBufferRef] = []
    /// AudioQueue DispatchQueue
    private var internalQueue :DispatchQueue? = nil
    /// AudioQueue DispatchQueue label
    private let internalQueueLabel = "audioPreviewInternal"
    
    /// Processing dispatch queue
    private var processingQueue :DispatchQueue? = nil
    /// Processing dispatch queue label
    private let processingQueueLabel = "audioPreview"
    /// Processing dispatch queue key
    private let processingQueueSpecificKey = DispatchSpecificKey<Void>()
    
    /* ================================================ */
    // MARK: - public properties
    /* ================================================ */
    
    /// True if AudioQueue is running
    public private(set) var running :Bool = false
    
    /// AudioQueue Volume (0.0 - 1.0 in Float32)
    public var volume :Float32 {
        get {
            var status :OSStatus = -1
            var aqVolume :AudioQueueParameterValue = 0.0
            if let audioQueue = audioQueue {
                status = AudioQueueGetParameter(audioQueue,
                                                kAudioQueueParam_Volume,
                                                &aqVolume)
            }
            if status != 0 {
                //print("ERROR: Failed to get volume.")
                return 0.0
            }
            return aqVolume
        }
        set(newValue) {
            var status :OSStatus = -1
            let aqVolume :AudioQueueParameterValue = max(0.0, min(1.0, newValue))
            if let audioQueue = audioQueue {
                status = AudioQueueSetParameter(audioQueue,
                                                kAudioQueueParam_Volume,
                                                aqVolume)
            }
            if status != 0 {
                //print("ERROR: Failed to set volume.")
            }
        }
    }
    
    /* ================================================ */
    // MARK: - public init/deinit
    /* ================================================ */
    
    /// Prepare AudioQueue using specified audioFormatDescription
    ///
    /// - Parameter audioFormatDescription: CMAudioFormatDescription
    /// - Returns: AudioPreview Object if success, nil if failed.
    init?(_ audioFormatDescription :CMAudioFormatDescription) {
        super.init()
        
        // Use supplied asbd for AudioQueue
        let asbdRef = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormatDescription)
        guard var asbd = asbdRef?.pointee else { return nil }
        
        // Prepare Processing DispatchQueue
        processingQueue = DispatchQueue(label:processingQueueLabel)
        if let processingQueue = processingQueue {
            processingQueue.setSpecific(key: processingQueueSpecificKey, value: ())
        } else {
            return nil
        }
        
        // Create AudioQueue
        var status :OSStatus = -1
        let inCallbackBlock :AudioQueueOutputCallbackBlock = {(aqRef, aqBufRef) in
            // - We do not enqueue in callback here (= pull model).
            // - Separate enqueue() is used instead (= push model).
            
            self.queueAsync {
                let count = self.numEnqueuedCountDec(false)
                
                // reset bytesize value of returned audioQueueBuffer
                aqBufRef.pointee.mAudioDataByteSize = 0
                
                // Wait a short period to minimize out-of-sync
                if count == 0 {
                    self.enqueueDelay(asbd, aqBufRef)
                }
            }
        }
        internalQueue = DispatchQueue(label: internalQueueLabel)
        if let internalQueue = internalQueue {
            status = AudioQueueNewOutputWithDispatchQueue(&audioQueue,
                                                          &asbd,
                                                          0,
                                                          internalQueue,
                                                          inCallbackBlock)
        }
        if status != 0 {
            return nil
        }
        
        // Apply AudioChannelLayout to AudioQueue if available
        var aclSize :Int = 0
        let aclPtr :UnsafePointer<AudioChannelLayout>? = CMAudioFormatDescriptionGetChannelLayout(audioFormatDescription,
                                                                                                  sizeOut: &aclSize)
        if let audioQueue = audioQueue, let aclPtr = aclPtr {
            status = AudioQueueSetProperty(audioQueue,
                                           kAudioQueueProperty_ChannelLayout,
                                           aclPtr,
                                           UInt32(aclSize))
            if status != 0 {
                return nil
            }
        }
        
        // Create AudioQueueBuffer(s); Use resolution per second.
        if let audioQueue = audioQueue {
            let numFrames = UInt32(asbd.mSampleRate/resolution)
            let inBufferByteSize = numFrames * asbd.mBytesPerFrame
            for _ in 0..<kNumberBuffer {
                var aqBufRef :AudioQueueBufferRef? = nil
                status = AudioQueueAllocateBuffer(audioQueue,
                                                  inBufferByteSize,
                                                  &aqBufRef)
                if status == 0, let outBuffer = aqBufRef {
                    aqBufferRefArray.append(outBuffer)
                } else {
                    status = (status == 0) ? -1 : status
                    break
                }
            }
        }
        if status != 0 {
            try? aqDispose()
            return nil
        }
        
        // Enqueue w/ short delay
        for aqBufRef in aqBufferRefArray {
            enqueueDelay(asbd, aqBufRef)
        }
        
        // Start AudioQueue instantly
        queueAsync {
            try? self.aqPrime()
            try? self.aqStart()
        }
        
        // print("AudioPreview.init")
    }
    
    deinit {
        // print("AudioPreview.deinit")
        
        try? aqDispose()
    }
    
    /* ================================================ */
    // MARK: - private functions
    /* ================================================ */
    
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
    
    private func createError(_ status :OSStatus, _ description :String?, _ failureReason :String?) -> NSError {
        let domain = "com.MyCometG3.DLABCaptureManager.ErrorDomain"
        let code = NSInteger(status)
        let desc = description ?? "unknown description"
        let reason = failureReason ?? "unknown failureReason"
        let userInfo :[String:Any] = [NSLocalizedDescriptionKey:desc,
                                      NSLocalizedFailureReasonErrorKey:reason]
        return NSError(domain: domain, code: code, userInfo: userInfo)
    }
    
    /// Extract ASBD from Audio CMSampleBuffer
    ///
    /// - Parameter sampleBuffer: Audio CMSampleBuffer
    /// - Returns: ASBD struct, of nil if failed
    private func getASBD(_ sampleBuffer :CMSampleBuffer) -> AudioStreamBasicDescription? {
        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        if let formatDescription = formatDescription {
            let asbdRef = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
            if let asbdRef = asbdRef {
                let asbd :AudioStreamBasicDescription = asbdRef.pointee
                return asbd
            }
        }
        return nil
    }
    
    /// Increment queued buffer count
    ///
    /// - Parameter show: debug dump the count
    /// - Returns: count of queued buffer
    private func numEnqueuedCountDec(_ show :Bool) -> Int {
        // update enqueuedCounter value
        var count = 0
        queueSync {
            count = numEnqueued - 1
            assert(count >= 0, "ERROR: Enqueued Counter value error.")
            numEnqueued = count
            
            if show {
                print("count == \(count)")
            }
        }
        return count
    }
    
    /// Decrement queued buffer count
    ///
    /// - Parameter show: debug dump the count
    /// - Returns: count of queued buffer
    private func numEnqueuedCountInc(_ show :Bool) -> Int {
        // update enqueuedCounter value
        var count = 0
        queueSync {
            count = numEnqueued + 1
            assert(count <= kNumberBuffer, "ERROR: Enqueued Counter value error.")
            numEnqueued = count
            
            if show {
                print("count == \(count)")
            }
        }
        return count
    }
    
    /// Wait short delay for next Audio Sample queueing
    ///
    /// - Parameters:
    ///   - asbd: ASBD
    ///   - aqBufRef: free audioQueueBuffer
    private func enqueueDelay(_ asbd :AudioStreamBasicDescription, _ aqBufRef :AudioQueueBufferRef) {
        queueSync {
            if let audioQueue = audioQueue {
                let delayResolution = 100 // per second
                let sampleRate = Int(asbd.mSampleRate)
                let bytesPerFrame = Int(asbd.mBytesPerFrame)
                let delayBytes = bytesPerFrame * sampleRate / delayResolution
                
                // zeroing
                let ptr = aqBufRef.pointee.mAudioData
                let capacity = Int(aqBufRef.pointee.mAudioDataBytesCapacity)
                memset(ptr, 0, capacity)
                
                // queueing
                aqBufRef.pointee.mAudioDataByteSize = UInt32(delayBytes)
                _ = AudioQueueEnqueueBuffer(audioQueue, aqBufRef, 0, nil)
                _ = numEnqueuedCountInc(false)
                
                // print("enqueueDelay()")
            }
        }
    }
    
    /// Find free audioQueueBuffer
    ///
    /// - Parameter aqBufferRef: inout AudioQueueBuffer
    /// - Returns: result value, 0 means success.
    private func findFreeAQBuffer(_ aqBufferRef: inout UnsafeMutablePointer<AudioQueueBuffer>?) -> OSStatus {
        var status :OSStatus = -1
        
        for index in 0..<kNumberBuffer {
            let aqBufRef :AudioQueueBufferRef = aqBufferRefArray[index]
            if aqBufRef.pointee.mAudioDataByteSize == 0 {
                aqBufferRef = aqBufRef
                status = 0
                break
            }
        }
        
        return status
    }
    
    /// Fill audioQueueBuffer using Audio CMSampleBuffer
    ///
    /// - Parameters:
    ///   - sampleBuffer: Audio CMSampleBuffer
    ///   - aqBufferRef: free audioQueueBuffer to be filled
    /// - Returns: result value, 0 means success.
    private func fillAQBuffer(_ sampleBuffer: CMSampleBuffer, _ aqBufferRef: AudioQueueBufferRef?) -> OSStatus {
        var status :OSStatus = 0
        
        // Prepare audioBufferList from CMSampleBuffer
        var audioBufferList :AudioBufferList = AudioBufferList()
        var blockBuffer :CMBlockBuffer? = nil
        do {
            var bufferListSizeNeededOut :Int = 0
            let sizeOfAudioBufferList = Int(MemoryLayout<AudioBufferList>.size)
            let alignmentFlag = kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment
            
            status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
                                                                             bufferListSizeNeededOut: &bufferListSizeNeededOut,
                                                                             bufferListOut: &audioBufferList,
                                                                             bufferListSize: sizeOfAudioBufferList,
                                                                             blockBufferAllocator: kCFAllocatorDefault,
                                                                             blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                             flags: alignmentFlag,
                                                                             blockBufferOut: &blockBuffer)
            if status != 0 {
                //print("ERROR: Failed to get audioBufferList. \(status)")
                return status
            }
        }
        
        // Fill AudioQueueBuffer(dst) from AudioBufferList(src)
        var totalSize :Int = 0
        if let aqBufferRef = aqBufferRef {
            let dst = aqBufferRef.pointee.mAudioData
            let dstCapacity = Int(aqBufferRef.pointee.mAudioDataBytesCapacity)
            let srcCount = Int(audioBufferList.mNumberBuffers)
            
            withUnsafeMutablePointer(to: &audioBufferList) { (ptr) in
                let ablPtr = UnsafeMutableAudioBufferListPointer.init(ptr)
                
                for index in 0..<srcCount {
                    let buffer :AudioBuffer = ablPtr[index]
                    let bufferSize :Int = Int(buffer.mDataByteSize)
                    if (dstCapacity - totalSize) >= bufferSize {
                        memcpy(dst + totalSize, buffer.mData, bufferSize)
                        totalSize += bufferSize
                    } else {
                        status = -1
                        break
                    }
                }
            }
            if status != 0 {
                //print("ERROR: Failed to fill audioQueueBuffer. (\(status))")
                return status
            }
            
            // Update buffer's data byte size
            aqBufferRef.pointee.mAudioDataByteSize = UInt32(totalSize)
        }
        
        return status
    }
    
    /* ================================================ */
    // MARK: - public functions
    /* ================================================ */
    
    /// Enqueue Audio CMSampleBuffer into AudioQueue
    ///
    /// - Parameter sampleBuffer: Audio CMSampleBuffer
    public func enqueue(_ sampleBuffer :CMSampleBuffer) throws {
        var status :OSStatus = -1
        var errDescription :String? = nil
        var errReason :String? = nil
        
        queueSync {
            // Get free AudioQueueBuffer
            var aqBufferRef :AudioQueueBufferRef? = nil
            status = findFreeAQBuffer(&aqBufferRef)
            if status != 0 {
                errDescription = "\(#function)) (\(#line))"
                errReason = "ERROR: AudioQueueBuffer is all in use (\(status))"
                return
            }
            
            // Fill AudioQueueBuffer(dst) from CMSampleBuffer(src)
            status = fillAQBuffer(sampleBuffer, aqBufferRef)
            if status != 0 {
                errDescription = "\(#function)) (\(#line))"
                errReason = "ERROR: Failed to fill audioQueueBuffer (\(status))"
                return
            }
            
            // Enqueue AudioQueueBuffer
            if let audioQueue = audioQueue, let audioQueueBuffer = aqBufferRef {
                status = AudioQueueEnqueueBuffer(audioQueue,
                                                 audioQueueBuffer,
                                                 0,
                                                 nil)
                if status != 0 {
                    errDescription = "\(#function)) (\(#line))"
                    errReason = "ERROR: Failed to enqueue audioQueueBuffer (\(status))"
                    return
                }
                
                _ = numEnqueuedCountInc(false)
            }
        }
        
        if status != 0 {
            throw createError(status, errDescription, errReason)
        }
    }
    
    /// Dispose AudioQueue and AudioQueueBuffers
    public func aqDispose() throws {
        var status :OSStatus = -1
        var errDescription :String? = nil
        var errReason :String? = nil
        
        queueSync {
            if let audioQueue = self.audioQueue {
                // Dispose AudioQueue
                status = AudioQueueDispose(audioQueue, false)
                if status != 0 {
                    errDescription = "\(#function)) (\(#line))"
                    errReason = "ERROR: Failed to dispose AudioQueue (\(status))"
                }
                
                self.audioQueue = nil
            } else {
                // Allow multiple call
                status = 0
            }
        }
        
        if status != 0 {
            throw createError(status, errDescription, errReason)
        }
    }
    
    /// AudioQueuePrime() wrapper
    public func aqPrime() throws {
        var status :OSStatus = -1
        var errDescription :String? = nil
        var errReason :String? = nil
        
        queueSync {
            if let audioQueue = audioQueue, running == false {
                status = AudioQueuePrime(audioQueue, 0, nil)
            }
        }
        
        if status != 0 {
            errDescription = "\(#function)) (\(#line))"
            errReason = "ERROR: Failed to AudioQueuePrime (\(status))"
            throw createError(status, errDescription, errReason)
        }
    }
    
    /// AudioQueueStart() wrapper
    public func aqStart() throws {
        var status :OSStatus = -1
        var errDescription :String? = nil
        var errReason :String? = nil
        
        queueSync {
            if let audioQueue = audioQueue, running == false {
                status = AudioQueueStart(audioQueue, nil)
                
                running = (status == 0) ? true : false
            }
        }
        
        if status != 0 {
            errDescription = "\(#function)) (\(#line))"
            errReason = "ERROR: Failed to AudioQueueStart (\(status))"
            throw createError(status, errDescription, errReason)
        }
    }
    
    /// AudioQueueFlush() wrapper
    public func aqFlush() throws {
        var status :OSStatus = -1
        var errDescription :String? = nil
        var errReason :String? = nil
        
        queueSync {
            if let audioQueue = audioQueue, running == true {
                status = AudioQueueFlush(audioQueue)
            }
        }
        
        if status != 0 {
            errDescription = "\(#function)) (\(#line))"
            errReason = "ERROR: Failed to AudioQueueFlush (\(status))"
            throw createError(status, errDescription, errReason)
        }
    }
    
    /// AudioQueueStop() wrapper
    public func aqStop() throws {
        var status :OSStatus = -1
        var errDescription :String? = nil
        var errReason :String? = nil
        
        queueSync {
            if let audioQueue = audioQueue, running == true {
                status = AudioQueueStop(audioQueue, true)
                
                running = (status == 0) ? false : true
            }
        }
        
        if status != 0 {
            errDescription = "\(#function)) (\(#line))"
            errReason = "ERROR: Failed to AudioQueueStop (\(status))"
            throw createError(status, errDescription, errReason)
        }
    }
    
    /// AudioQueuePause() wrapper
    public func aqPause() throws {
        var status :OSStatus = -1
        var errDescription :String? = nil
        var errReason :String? = nil
        
        queueSync {
            if let audioQueue = audioQueue, running == true {
                status = AudioQueuePause(audioQueue)
            }
        }
        
        if status != 0 {
            errDescription = "\(#function)) (\(#line))"
            errReason = "ERROR: Failed to AudioQueuePause (\(status))"
            throw createError(status, errDescription, errReason)
        }
    }
    
    /// AudioQueueReset() wrapper
    public func aqReset() throws {
        var status :OSStatus = -1
        var errDescription :String? = nil
        var errReason :String? = nil
        
        queueSync {
            if let audioQueue = audioQueue {
                status = AudioQueueReset(audioQueue)
            }
        }
        
        if status != 0 {
            errDescription = "\(#function)) (\(#line))"
            errReason = "ERROR: Failed to AudioQueueReset (\(status))"
            throw createError(status, errDescription, errReason)
        }
    }
}
