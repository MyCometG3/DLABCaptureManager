//
//  CaptureTimecodeHelper.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2017/10/01.
//  Copyright © 2017-2020年 MyCometG3. All rights reserved.
//

import Foundation
import CoreMedia

class CaptureTimecodeHelper: NSObject {
    /// Special CoreAudio SMPTE Time - embeded as CMSampleBuffer attachment
    private let smpteTimeKey : String = "com.apple.cmio.buffer_attachment.core_audio_smpte_time"
    
    /// Default Timecode format : either TimeCode32 or TimeCode64
    public var timeCodeFormatType : CMTimeCodeFormatType = kCMTimeCodeFormatType_TimeCode32
    
    /* ============================================ */
    // MARK: - public init/deinit
    /* ============================================ */
    
    /// Prepare Timecode Helper with specified Timecode FormatType. See TN2310.
    ///
    /// - Parameter typeValue: CMTimeCodeFormatType either Timecode32 or TimeCode64.
    init(formatType typeValue : CMTimeCodeFormatType) {
        super.init()
        
        timeCodeFormatType = typeValue
        
        // print("TimecodeHelper.init")
    }
    
    deinit {
        // print("TimecodeHelper.deinit")
    }
    
    /* ============================================ */
    // MARK: - public func
    /* ============================================ */
    
    /// Extract CoreAudio SMPTETime from CMSampleBuffer Attachment
    ///
    /// - Parameter videoSampleBuffer: CMSampleBuffer of VideoSample
    /// - Returns: CMSampleBuffer of TimecodeSample if available
    public func createTimeCodeSample(from videoSampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        // Check CMTimeCodeFormatType
        var sizes: Int = 0
        switch timeCodeFormatType {
        case kCMTimeCodeFormatType_TimeCode32: sizes = MemoryLayout<Int32>.size // tmcd 32bit
        case kCMTimeCodeFormatType_TimeCode64: sizes = MemoryLayout<Int64>.size // tc64 64bit
        default:
            print("ERROR: Unsupported CMTimeCodeFormatType detected.")
            return nil
        }
        
        // Extract SMPTETime from video sample
        guard let smpteTime = extractCVSMPTETime(from: videoSampleBuffer)
            else { return nil }
        
        // Evaluate TimeCode Quanta
        var quanta: UInt32 = 30
        switch smpteTime.type {
        case 0:          quanta = 24
        case 1:          quanta = 25
        case 2..<6:      quanta = 30
        case 6..<10:     quanta = 60
        case 10:         quanta = 50
        case 11:         quanta = 24
        default:         break
        }
        
        // Evaluate TimeCode type
        var tcType: UInt32 = kCMTimeCodeFlag_24HourMax // | kCMTimeCodeFlag_NegTimesOK
        switch smpteTime.type {
        case 2,5,8,9:    tcType |= kCMTimeCodeFlag_DropFrame
        default:         break
        }
        
        // Prepare Data Buffer for new SampleBuffer
        guard let dataBuffer = prepareTimeCodeDataBuffer(smpteTime, sizes, quanta, tcType)
            else { return nil }
        
        /* ============================================ */
        
        // Prepare TimeCode SampleBuffer
        var sampleBuffer: CMSampleBuffer? = nil
        var status: OSStatus = noErr
        
        // Extract duration from video sample
        let duration = CMSampleBufferGetDuration(videoSampleBuffer)
        
        // Extract timingInfo from video sample
        var timingInfo = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(videoSampleBuffer, at: 0, timingInfoOut: &timingInfo)
        
        // Prepare CMTimeCodeFormatDescription
        var description : CMTimeCodeFormatDescription? = nil
        status = CMTimeCodeFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                   timeCodeFormatType: timeCodeFormatType,
                                                   frameDuration: duration,
                                                   frameQuanta: quanta,
                                                   flags: tcType,
                                                   extensions: nil,
                                                   formatDescriptionOut: &description)
        if status != noErr || description == nil {
            print("ERROR: Could not create format description.")
            return nil
        }
        
        // Create new SampleBuffer
        var timingInfoTMP = timingInfo
        status = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                      dataBuffer: dataBuffer,
                                      dataReady: true,
                                      makeDataReadyCallback: nil,
                                      refcon: nil,
                                      formatDescription: description,
                                      sampleCount: 1,
                                      sampleTimingEntryCount: 1,
                                      sampleTimingArray: &timingInfoTMP,
                                      sampleSizeEntryCount: 1,
                                      sampleSizeArray: &sizes,
                                      sampleBufferOut: &sampleBuffer)
        if status != noErr || sampleBuffer == nil {
            print("ERROR: Could not create sample buffer.")
            return nil
        }
        
        return sampleBuffer
    }
    
    /* ============================================ */
    // MARK: - private func
    /* ============================================ */
    
    /// Extract CoreAudio SMPTETime from CMSampleBuffer Attachment
    ///
    /// - Parameter sampleBuffer: CMSampleBuffer of source VideoSample
    /// - Returns: CVSMPTETime struct if available
    private func extractCVSMPTETime(from sampleBuffer: CMSampleBuffer) -> CVSMPTETime? {
        // Extract sampleBuffer attachment for SMPTETime
        let smpteTimeData = CMGetAttachment(sampleBuffer,
                                            key: smpteTimeKey as CFString,
                                            attachmentModeOut: nil)
        
        // Create SMPTETime struct from sampleBuffer attachment
        var smpteTime: CVSMPTETime? = nil
        if let smpteTimeData = smpteTimeData as? Data {
            let data = (smpteTimeData as NSData).bytes.bindMemory(to: CVSMPTETime.self,
                                                                  capacity: smpteTimeData.count).pointee
            smpteTime = CVSMPTETime(subframes: data.subframes,
                                    subframeDivisor: data.subframeDivisor,
                                    counter: data.counter,
                                    type: data.type,
                                    flags: data.flags,
                                    hours: data.hours,
                                    minutes: data.minutes,
                                    seconds: data.seconds,
                                    frames: data.frames)
        }
        
        return smpteTime
    }
    
    /// Convert CVSMPTETime struct into CMBlockBuffer of specified type
    ///
    /// - Parameters:
    ///   - smpteTime: source CVSMPTETime
    ///   - sizes: size of Timecode Sample
    ///   - quanta: Base Resolution per second in integer value
    ///   - tcType: Timecode Type in kCMTimeCodeFlag_xxx form
    /// - Returns: CMBlockBuffer of TimecodeSample if available
    private func prepareTimeCodeDataBuffer(_ smpteTime: CVSMPTETime,
                                           _ sizes: Int,
                                           _ quanta: UInt32,
                                           _ tcType: UInt32) -> CMBlockBuffer?  {
        var dataBuffer: CMBlockBuffer? = nil
        var status: OSStatus = noErr
        
        // Caluculate frameNumber for specific SMPTETime
        var frameNumber64: Int64 = 0
        let tcNegativeFlag = Int16(0x80)
        frameNumber64 = Int64(smpteTime.frames)
        frameNumber64 += Int64(smpteTime.seconds) * Int64(quanta)
        frameNumber64 += Int64(smpteTime.minutes & ~tcNegativeFlag) * Int64(quanta) * 60
        frameNumber64 += Int64(smpteTime.hours) * Int64(quanta) * 60 * 60
        
        let fpm: Int64 = Int64(quanta) * 60
        if (tcType & kCMTimeCodeFlag_DropFrame) != 0 {
            let fpm10 = fpm * 10
            let num10s = frameNumber64 / fpm10
            var frameAdjust = -num10s * (9*2)
            var numFramesLeft = frameNumber64 % fpm10
            
            if numFramesLeft > 1 {
                let num1s = numFramesLeft / fpm
                if num1s > 0 {
                    frameAdjust -= (num1s - 1) * 2
                    numFramesLeft = numFramesLeft % fpm
                    if numFramesLeft > 1 {
                        frameAdjust -= 2
                    } else {
                        frameAdjust -= (numFramesLeft + 1)
                    }
                }
            }
            frameNumber64 += frameAdjust
        }
        
        if (smpteTime.minutes & tcNegativeFlag) != 0 {
            frameNumber64 = -frameNumber64
        }
        
        // TODO
        let frameNumber32: Int32 = Int32(frameNumber64)
        
        /* ============================================ */
        
        // Allocate BlockBuffer
        status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                    memoryBlock: nil,
                                                    blockLength: sizes,
                                                    blockAllocator: kCFAllocatorDefault,
                                                    customBlockSource: nil,
                                                    offsetToData: 0,
                                                    dataLength: sizes,
                                                    flags: kCMBlockBufferAssureMemoryNowFlag,
                                                    blockBufferOut: &dataBuffer)
        if status != noErr || dataBuffer == nil {
            print("ERROR: Could not create block buffer.")
            return nil
        }
        
        // Write FrameNumfer into BlockBuffer
        if let dataBuffer = dataBuffer {
            switch sizes {
            case MemoryLayout<Int32>.size:
                var frameNumber32BE = frameNumber32.bigEndian
                status = CMBlockBufferReplaceDataBytes(with: &frameNumber32BE,
                                                       blockBuffer: dataBuffer,
                                                       offsetIntoDestination: 0,
                                                       dataLength: sizes)
            case MemoryLayout<Int64>.size:
                var frameNumber64BE = frameNumber64.bigEndian
                status = CMBlockBufferReplaceDataBytes(with: &frameNumber64BE,
                                                       blockBuffer: dataBuffer,
                                                       offsetIntoDestination: 0,
                                                       dataLength: sizes)
            default:
                status = -1
            }
            if status != kCMBlockBufferNoErr {
                print("ERROR: Could not write into block buffer.")
                return nil
            }
        }
        
        return dataBuffer
    }
}
