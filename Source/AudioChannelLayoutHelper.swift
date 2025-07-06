//
//  AudioProperties.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2025/07/27.
//  Copyright © 2025 MyCometG3. All rights reserved.
//

import Foundation
import AVFoundation
import VideoToolbox

extension CaptureWriter {
    /*
     NOTE:
     This function remaps the channel order of the input LPCM Audio SampleBuffer.
     The framework supposes the native HDMI Audio layout as MPEG_7_1_A (L R C LFE Ls Rs Lc Rc).
     With Reverse34 enabled, Channel C,LFE order is swapped as LFE,C.
     Followings shows how channel remapping works from HDMI layout into AAC Layout.
     
     ### 3ch Audio
                     0 1 2 3 4 5 6 7
     src:MPEG_3_0_A  L R C _ _ _ _ _
     dst:AAC_3_0
     dst:MPEG_3_0_B  C L R
                     2 0 1
     
     ### 3ch Audio + Reverse34
                     0 1 2 3 4 5 6 7
     src:MPEG_3_0_A  L R _ C _ _ _ _
     dst:AAC_3_0
     dst:MPEG_3_0_B  C L R
                     3 0 1
     
     ### 5.1ch Audio
                     0 1 2 3   4  5  6 7
     src:MPEG_5_1_A  L R C LFE Ls Rs _ _
     dst:AAC_5_1
     dst:MPEG_5_1_D  C L R Ls Rs LFE
                     2 0 1 4  5  3
     
     ### 5.1ch Audio + Reverse34
                     0 1 2   3 4  5  6 7
     src:Reverse34   L R LFE C Ls Rs _ _
     dst:AAC_5_1
     dst:MPEG_5_1_D  C L R Ls Rs LFE
                     3 0 1 4  5  2
     
     ### 7.1ch Audio
                     0 1 2 3   4  5  6  7
     src:MPEG_7_1_A  L R C LFE Ls Rs Lc Rc
     dst:AAC_7_1
     dst:MPEG_7_1_B  C Lc Rc L R Ls Rs Lfe
                     2 6  7  0 1 4  5  3
     
     ### 7.1ch Audio + Reverse34
                     0 1 2   3 4  5  6  7
     src:Reverse34   L R LFE C Ls Rs Lc Rc
     dst:AAC_7_1
     dst:MPEG_7_1_B  C Lc Rc L R Ls Rs Lfe
                     3 6  7  0 1 4  5  2
     */

    /// Check if the AudioChannelLayout has Reverse34 layout.
    /// - Parameters:
    ///  - layoutPtr: Pointer to the AudioChannelLayout structure.
    ///  - validChannelCount: Number of valid channels in the layout.
    ///  - Returns: `true` if the layout has Reverse34 configuration, otherwise `false`.
    ///  - Note:
    ///         The framework supposes the native HDMI Audio layout as MPEG_7_1_A (L R C LFE Ls Rs Lc Rc).
    ///         With Reverse34 enabled, Channel C,LFE order is swapped as LFE,C.
    internal func hasReverse34Layout(layoutPtr: UnsafePointer<AudioChannelLayout>, validChannelCount: Int) -> Bool {
        // Check if the layout is valid
        let layout = layoutPtr.pointee
        let numDescriptions = Int(layout.mNumberChannelDescriptions)
        guard numDescriptions == 8 else {
            return false // ("AudioChannelLayout must have 8 channel descriptions for reverse34 check")
        }
        
        // Get base pointer to channel descriptions in the AudioChannelLayout
        guard let basePtr = getInputChannelDescriptionPointer(from: layoutPtr) else {
            return false
        }
        
        // For 3ch: Check if Center is at position 3 (reverse34) instead of position 2 (normal)
        if validChannelCount == 3 {
            let label2 = basePtr.advanced(by: 2).pointee.mChannelLabel
            let label3 = basePtr.advanced(by: 3).pointee.mChannelLabel
            return label2 == kAudioChannelLabel_Unused && label3 == kAudioChannelLabel_Center
        }
        
        // For 5.1ch and 7.1ch: Check if LFE is at position 2 instead of position 3
        if validChannelCount >= 6 {
            let label2 = basePtr.advanced(by: 2).pointee.mChannelLabel
            let label3 = basePtr.advanced(by: 3).pointee.mChannelLabel
            return label2 == kAudioChannelLabel_LFEScreen && label3 == kAudioChannelLabel_Center
        }
        
        return false
    }
    
    /// Count valid channels in the AudioChannelLayout.
    /// - Parameter layoutPtr: Pointer to the AudioChannelLayout structure.
    /// - Returns: The count of valid channels.
    /// - Note:
    ///        This function counts valid channels based on the mChannelBitmap or AudioChannelDescriptions.
    ///        If the layout uses mChannelBitmap, it counts the number of bits set to 1.
    ///        If it uses AudioChannelDescriptions, it counts channels with labels other than
    ///        kAudioChannelLabel_Unknown and kAudioChannelLabel_Unused.
    ///        If the layout tag provides a specific number of channels, it uses that count.
    internal func countValidChannels(layoutPtr: UnsafePointer<AudioChannelLayout>) -> Int {
        // Source ACL could contain unused channels. Count valid channels.
        let layout = layoutPtr.pointee
        let tag = layout.mChannelLayoutTag
        let numDescriptions = Int(layout.mNumberChannelDescriptions)

        // Count valid channels based on mChannelBitmap
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            let bitmap: UInt32 = layout.mChannelBitmap.rawValue
            let validCount: Int = bitmap.nonzeroBitCount
            return validCount
        }
        
        // Count valid channels based on AudioChannelDescriptions
        if numDescriptions > 0 { // kAudioChannelLayoutTag_UseChannelDescriptions
            var validCount: Int = 0
            guard let basePtr = getInputChannelDescriptionPointer(from: layoutPtr) else {
                return 0
            }
            for i in 0..<numDescriptions {
                let label = basePtr.advanced(by: i).pointee.mChannelLabel
                if label != kAudioChannelLabel_Unknown && label != kAudioChannelLabel_Unused {
                    validCount += 1
                }
            }
            return validCount
        }
        
        // Use AudioChannelLayoutTag_GetNumberOfChannels for other tags
        let channelCount: UInt32 = AudioChannelLayoutTag_GetNumberOfChannels(tag)
        return Int(channelCount)
    }
    
    /* ============================================ */
    // MARK: - Remap LPCM Channel Order for AAC Encoding
    /* ============================================ */

    /// Remap the channel order of an LPCM Audio SampleBuffer for AAC encoding (3ch, 5.1ch, 7.1ch).
    /// - Parameters:
    ///   - inSampleBuffer: The input CMSampleBuffer containing LPCM audio data.
    ///   - outputType: The output type for AudioChannelLayout creation. Defaults to `.descriptions8Ch`.
    /// - Returns: A new CMSampleBuffer with the remapped channel order, or `nil` if remapping fails.
    /// - Note:
    ///     This function performs LPCM channel order remapping for AAC encoding.
    ///     The output format depends on the outputType parameter:
    ///     - `.descriptions8Ch`: Creates 8-channel layout with AudioChannelDescriptions (existing behavior)
    ///     - `.tag3Ch`, `.tag5_1Ch`, `.tag7_1Ch`: Creates compact layouts with AudioChannelLayoutTag
    ///
    ///     Channel remapping patterns:
    ///     - src:MPEG_3_0_A (L R C) → dst:MPEG_3_0_B/AAC_3_0 (C L R)
    ///     - src:MPEG_5_1_A (L R C LFE Ls Rs) → dst:MPEG_5_1_D/AAC_5_1 (C L R Ls Rs LFE)
    ///     - src:MPEG_7_1_A (L R C LFE Ls Rs Lc Rc) → dst:MPEG_7_1_B/AAC_7_1 (C Lc Rc L R Ls Rs LFE)
    internal func remapLPCMChannelOrderForAAC(_ inSampleBuffer: CMSampleBuffer, _ outputType: AudioChannelLayoutOutputType = .descriptions8Ch) -> CMSampleBuffer? {
        // 1. Validate prerequisites and extract audio properties
        guard let audioProps = extractAudioProperties(from: inSampleBuffer, outputType: outputType) else { return nil }
        
        // 2. Determine channel mapping based on layout
        guard !audioProps.channelMap.isEmpty else { return nil }
        
        // 3. Create output buffer and get data pointers
        guard let bufferInfo = createOutputBuffer(audioProps: audioProps) else { return nil }
        
        // 4. Perform channel remapping
        performChannelRemapping(audioProps: audioProps, channelMap: audioProps.channelMap, bufferInfo: bufferInfo)
        
        // 5. Create and return new sample buffer
        return createOutputSampleBuffer(audioProps: audioProps, outputBuffer: bufferInfo.outputBuffer)
    }
    
    // MARK: - Helper Structures
    
    private struct AudioProperties {
        let asbd: AudioStreamBasicDescription
        let layoutPtr: UnsafePointer<AudioChannelLayout>
        let inputChannelCount: Int
        let validChannelCount: Int
        let bytesPerSample: Int
        let frameCount: Int
        let inBlockBuffer: CMBlockBuffer
        let sampleCount: Int
        let presentationTimeStamp: CMTime
        let duration: CMTime
        let channelMap: [Int] // Add channelMap to avoid recalculation
        let outputChannelCount: Int // Add output channel count
        let outputType: AudioChannelLayoutOutputType // Add output type
    }
    
    private struct BufferInfo {
        let inputData: UnsafeMutablePointer<Int8>
        let outputData: UnsafeMutablePointer<Int8>
        let outputBuffer: CMBlockBuffer
    }
    
    // MARK: - Step 1: Extract Audio Properties
    
    private func extractAudioProperties(from sampleBuffer: CMSampleBuffer, outputType: AudioChannelLayoutOutputType = .descriptions8Ch) -> AudioProperties? {
        guard encodeAudio, encodeAudioFormatID == kAudioFormatMPEG4AAC else { return nil }
        guard let sourceAudioFormatDescription = sourceAudioFormatDescription else { return nil }
        guard let asbd_p = CMAudioFormatDescriptionGetStreamBasicDescription(sourceAudioFormatDescription) else { return nil }
        
        var layoutSize: Int = 0
        guard let acl_p = CMAudioFormatDescriptionGetChannelLayout(sourceAudioFormatDescription, sizeOut: &layoutSize) else { return nil }
        
        let inputChannels = Int(asbd_p.pointee.mChannelsPerFrame)
        guard inputChannels == 8 else { return nil }
        
        guard let originalBlockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        
        // Ensure input buffer is contiguous using utility function
        guard let contiguousBlockBuffer = ensureContiguousBlockBuffer(originalBlockBuffer) else { return nil }
        
        let inSize = CMBlockBufferGetDataLength(contiguousBlockBuffer)
        let asbd = asbd_p.pointee
        let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let frameCount = inSize / bytesPerFrame
        let validChannelCount = countValidChannels(layoutPtr: acl_p)
        
        // Calculate channel mapping once
        let isReverse34 = hasReverse34Layout(layoutPtr: acl_p, validChannelCount: validChannelCount)
        let channelMap: [Int]
        switch validChannelCount {
        case 3:
            channelMap = isReverse34 ? [3, 0, 1] : [2, 0, 1] // C L R
        case 6: // 5.1ch
            channelMap = isReverse34 ? [3, 0, 1, 4, 5, 2] : [2, 0, 1, 4, 5, 3] // C L R Ls Rs LFE
        case 8: // 7.1ch
            channelMap = isReverse34 ? [3, 6, 7, 0, 1, 4, 5, 2] : [2, 6, 7, 0, 1, 4, 5, 3] // C Lc Rc L R Ls Rs LFE
        default:
            channelMap = []
        }
        
        // Determine output channel count based on output type
        let outputChannelCount: Int
        if outputType == .descriptions8Ch {
            outputChannelCount = 8 // Always 8 channels for descriptions8Ch
        } else {
            outputChannelCount = outputType.outputChannelCount // Use type-specific channel count
        }
        
        return AudioProperties(
            asbd: asbd,
            layoutPtr: acl_p,
            inputChannelCount: inputChannels,
            validChannelCount: validChannelCount,
            bytesPerSample: bytesPerSample,
            frameCount: frameCount,
            inBlockBuffer: contiguousBlockBuffer, // Use contiguous buffer
            sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer),
            channelMap: channelMap,
            outputChannelCount: outputChannelCount,
            outputType: outputType
        )
    }
    
    // MARK: - Step 2: Create Output Buffer
    
    private func createOutputBuffer(audioProps: AudioProperties) -> BufferInfo? {
        // Calculate output buffer size based on output type
        let inputBufferSize = CMBlockBufferGetDataLength(audioProps.inBlockBuffer)
        let inputBytesPerFrame = audioProps.inputChannelCount * audioProps.bytesPerSample
        let outputBufferSize: Int
        let outputBytesPerFrame = audioProps.outputChannelCount * audioProps.bytesPerSample
        if audioProps.outputType == .descriptions8Ch {
            // For descriptions8Ch, use same size as input buffer (8 channels)
            outputBufferSize = inputBufferSize
        } else {
            // For Tag-based output, calculate smaller buffer size based on output channel count
            outputBufferSize = (inputBufferSize / inputBytesPerFrame) * outputBytesPerFrame
        }
        
        // Create contiguous output buffer using utility function
        guard let contiguousOutputBuffer = createContiguousBlockBuffer(memorySize: outputBufferSize) else {
            return nil
        }
        
        // Create BufferInfo using the helper function
        return createBufferInfo(
            inputBuffer: audioProps.inBlockBuffer,
            outputBuffer: contiguousOutputBuffer
        )
    }
    
    /// Helper function to create BufferInfo from input and output CMBlockBuffers
    private func createBufferInfo(
        inputBuffer: CMBlockBuffer,
        outputBuffer: CMBlockBuffer
    ) -> BufferInfo? {
        var inDataPtr: UnsafeMutablePointer<Int8>? = nil
        var outDataPtr: UnsafeMutablePointer<Int8>? = nil
        
        let inAccessStatus = CMBlockBufferGetDataPointer(
            inputBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: nil,
            dataPointerOut: &inDataPtr
        )
        
        let outAccessStatus = CMBlockBufferGetDataPointer(
            outputBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: nil,
            dataPointerOut: &outDataPtr
        )
        
        guard inAccessStatus == noErr, outAccessStatus == noErr,
              let inData = inDataPtr, let outData = outDataPtr else {
            return nil
        }
        
        // Note: Both buffers are guaranteed to be contiguous at this point
        // - Input buffer: ensured by ensureContiguousBlockBuffer() in extractAudioProperties()
        // - Output buffer: created by createContiguousBlockBuffer() which guarantees contiguity
        
        return BufferInfo(
            inputData: inData,
            outputData: outData,
            outputBuffer: outputBuffer
        )
    }
    
    // MARK: - Step 3: Perform Channel Remapping
    
    private func performChannelRemapping(audioProps: AudioProperties, channelMap: [Int], bufferInfo: BufferInfo) {
        switch audioProps.bytesPerSample {
        case 2: // 16-bit samples
            performChannelRemappingGeneric(T: Int16.self, audioProps: audioProps, channelMap: channelMap, bufferInfo: bufferInfo)
        case 4: // 32-bit samples
            performChannelRemappingGeneric(T: Int32.self, audioProps: audioProps, channelMap: channelMap, bufferInfo: bufferInfo)
        default:
            break // Unsupported sample size
        }
    }
    
    private func performChannelRemappingGeneric<T: FixedWidthInteger>(T: T.Type, audioProps: AudioProperties, channelMap: [Int], bufferInfo: BufferInfo) {
        let inputNumSamples = audioProps.frameCount * audioProps.inputChannelCount
        let inSamples = bufferInfo.inputData.withMemoryRebound(to: T.self, capacity: inputNumSamples) { $0 }
        
        if audioProps.outputType == .descriptions8Ch {
            // For descriptions8Ch output, use same buffer size and channel count (8 channels)
            let outSamples = bufferInfo.outputData.withMemoryRebound(to: T.self, capacity: inputNumSamples) { $0 }
            
            for frame in 0..<audioProps.frameCount {
                for outChannel in 0..<8 {
                    let inChannel = outChannel < channelMap.count ? channelMap[outChannel] : -1
                    let outIndex = frame * 8 + outChannel
                    if inChannel >= 0 {
                        let inIndex = frame * audioProps.inputChannelCount + inChannel
                        outSamples[outIndex] = inSamples[inIndex]
                    }
                    // If inChannel is -1, outSamples[outIndex] remains 0 (already initialized)
                }
            }
        } else {
            // For Tag-based output, use smaller buffer size based on output channel count
            let outputSamples = audioProps.frameCount * audioProps.outputChannelCount
            let outSamples = bufferInfo.outputData.withMemoryRebound(to: T.self, capacity: outputSamples) { $0 }
            
            for frame in 0..<audioProps.frameCount {
                for outChannel in 0..<audioProps.outputChannelCount {
                    let inChannel = channelMap[outChannel]
                    let outIndex = frame * audioProps.outputChannelCount + outChannel
                    let inIndex = frame * audioProps.inputChannelCount + inChannel
                    outSamples[outIndex] = inSamples[inIndex]
                }
            }
        }
    }
    
    // MARK: - Step 4: Create Output Sample Buffer
    
    private func createOutputSampleBuffer(audioProps: AudioProperties, outputBuffer: CMBlockBuffer) -> CMSampleBuffer? {
        // Create output audio format description
        var outFormatDesc: CMAudioFormatDescription? = nil
        // Modify ASBD for output channel count
        var outASBD = audioProps.asbd
        outASBD.mChannelsPerFrame = UInt32(audioProps.outputChannelCount)
        outASBD.mBytesPerFrame = UInt32(audioProps.outputChannelCount * audioProps.bytesPerSample)
        outASBD.mBytesPerPacket = outASBD.mBytesPerFrame // For LPCM, packet = frame
        
        // Create AudioChannelLayout using AudioChannelDescriptions for 8 channels
        guard let outputLayoutData = createOutputAudioChannelLayout(audioProps: audioProps, channelMap: audioProps.channelMap) else {
            return nil
        }
        
        let layoutPtr = outputLayoutData.bytes.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        let layoutSize = outputLayoutData.length
        let createFormatStatus = CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &outASBD,
            layoutSize: layoutSize,
            layout: layoutPtr,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &outFormatDesc
            )
        
        guard createFormatStatus == noErr, let outFormatDesc = outFormatDesc else { return nil }
        
        // Create output sample buffer
        var outSampleBuffer: CMSampleBuffer? = nil
        var timingInfo = CMSampleTimingInfo(
            duration: audioProps.duration,
            presentationTimeStamp: audioProps.presentationTimeStamp,
            decodeTimeStamp: CMTime.invalid
        )
        
        let createSampleStatus = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: outputBuffer,
            formatDescription: outFormatDesc,
            sampleCount: audioProps.sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &outSampleBuffer
        )
        
        guard createSampleStatus == noErr else { return nil }
        return outSampleBuffer
    }
    
    /* ============================================ */
    // MARK: - AudioChannelLayout Helper Functions
    /* ============================================ */
    
    /// Defines the output type for AudioChannelLayout creation
    internal enum AudioChannelLayoutOutputType {
        case descriptions8Ch    // AudioChannelDescriptions with 8 channels (existing behavior)
        case tag3Ch            // AudioChannelLayoutTag for 3ch (AAC_3_0)
        case tag5_1Ch          // AudioChannelLayoutTag for 5.1ch (AAC_5_1)
        case tag7_1Ch          // AudioChannelLayoutTag for 7.1ch (AAC_7_1)
        
        /// Get the number of output channels for this layout type
        var outputChannelCount: Int {
            switch self {
            case .descriptions8Ch:
                return 8
            case .tag3Ch:
                return 3
            case .tag5_1Ch:
                return 6
            case .tag7_1Ch:
                return 8
            }
        }
        
        /// Get the appropriate AudioChannelLayoutTag for this layout type
        var layoutTag: AudioChannelLayoutTag {
            switch self {
            case .descriptions8Ch:
                return kAudioChannelLayoutTag_UseChannelDescriptions
            case .tag3Ch:
                return kAudioChannelLayoutTag_AAC_3_0
            case .tag5_1Ch:
                return kAudioChannelLayoutTag_AAC_5_1
            case .tag7_1Ch:
                return kAudioChannelLayoutTag_AAC_7_1
            }
        }
    }
    
    /// Calculate the size needed for AudioChannelLayout with specified number of channel descriptions
    /// - Parameter channelDescriptionCount: Number of channel descriptions
    /// - Returns: Size in bytes needed for the AudioChannelLayout
    private func calculateAudioChannelLayoutSize(channelDescriptionCount: Int) -> Int {
        guard channelDescriptionCount > 0 else {
            return MemoryLayout<AudioChannelLayout>.size
        }
        
        return MemoryLayout<AudioChannelLayout>.size +
               (channelDescriptionCount - 1) * MemoryLayout<AudioChannelDescription>.size
    }
    
    /// Get pointer to the channel descriptions array in the input AudioChannelLayout.
    /// - Parameter layoutPtr: Pointer to the AudioChannelLayout structure
    /// - Returns: Pointer to the channel descriptions array, or nil if unable to access
    private func getInputChannelDescriptionPointer(from layoutPtr: UnsafePointer<AudioChannelLayout>) -> UnsafePointer<AudioChannelDescription>? {
        guard let descOffset: Int = MemoryLayout<AudioChannelLayout>
            .offset(of: \AudioChannelLayout.mChannelDescriptions)
        else {
            return nil
        }
        let descCount: Int = Int(layoutPtr.pointee.mNumberChannelDescriptions)
        return UnsafeRawPointer(layoutPtr)
            .advanced(by: descOffset)
            .bindMemory(to: AudioChannelDescription.self, capacity: descCount)
    }

    /// Get pointer to the channel descriptions array in the output AudioChannelLayout
    /// - Parameter layoutPtr: Pointer to the AudioChannelLayout structure
    /// - Returns: Pointer to the channel descriptions array, or nil if unable to access
    private func getOutputChannelDescriptionPointer(from layoutPtr: UnsafeMutablePointer<AudioChannelLayout>) -> UnsafeMutablePointer<AudioChannelDescription>? {
        guard let descOffset: Int = MemoryLayout<AudioChannelLayout>
            .offset(of: \AudioChannelLayout.mChannelDescriptions)
        else {
            return nil
        }
        let descCount: Int = Int(layoutPtr.pointee.mNumberChannelDescriptions)
        return UnsafeMutableRawPointer(layoutPtr)
            .advanced(by: descOffset)
            .bindMemory(to: AudioChannelDescription.self, capacity: descCount)
    }
    
    /// Create output AudioChannelLayout based on output type
    /// - Parameters:
    ///   - audioProps: Audio properties containing input layout information
    ///   - channelMap: Channel mapping array for remapping
    /// - Returns: NSData containing the AudioChannelLayout data, or nil if creation fails
    private func createOutputAudioChannelLayout(audioProps: AudioProperties, channelMap: [Int]) -> NSData? {
        if audioProps.outputType == .descriptions8Ch {
            // For descriptions8Ch, create layout with 8 channel descriptions (existing behavior)
            return createAudioChannelLayoutWithDescriptions(audioProps: audioProps, channelMap: channelMap)
        } else {
            // For Tag-based output, create simple AudioChannelLayout with only tag
            return createAudioChannelLayoutWithTag(outputType: audioProps.outputType)
        }
    }
    
    /// Create AudioChannelLayout with tag only (for Tag-based output types)
    /// - Parameter outputType: The output type specifying the tag to use
    /// - Returns: NSData containing the AudioChannelLayout data, or nil if creation fails
    private func createAudioChannelLayoutWithTag(outputType: AudioChannelLayoutOutputType) -> NSData? {
        // Create NSMutableData to hold the AudioChannelLayout (basic size only)
        let layoutSize = MemoryLayout<AudioChannelLayout>.size
        guard let outputLayoutData = NSMutableData(length: layoutSize) else { return nil }
        
        // Get pointer to the layout structure
        let outputLayoutPtr = outputLayoutData.mutableBytes.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        
        // Initialize the layout with tag only
        outputLayoutPtr.pointee.mChannelLayoutTag = outputType.layoutTag
        outputLayoutPtr.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        outputLayoutPtr.pointee.mNumberChannelDescriptions = 0
        
        // Return immutable copy to prevent further modifications
        return NSData(data: outputLayoutData as Data)
    }
    
    /// Create AudioChannelLayout with 8 channel descriptions (existing behavior)
    /// - Parameters:
    ///   - audioProps: Audio properties containing input layout information
    ///   - channelMap: Channel mapping array for remapping
    /// - Returns: NSData containing the AudioChannelLayout data, or nil if creation fails
    private func createAudioChannelLayoutWithDescriptions(audioProps: AudioProperties, channelMap: [Int]) -> NSData? {
        // Create NSMutableData to hold the AudioChannelLayout
        let layoutSize = calculateAudioChannelLayoutSize(channelDescriptionCount: 8)
        guard let outputLayoutData = NSMutableData(length: layoutSize) else { return nil }
        
        // Get pointer to the layout structure
        let outputLayoutPtr = outputLayoutData.mutableBytes.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        
        // Initialize the layout header
        outputLayoutPtr.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        outputLayoutPtr.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        outputLayoutPtr.pointee.mNumberChannelDescriptions = 8
        
        // Copy and remap channel descriptions from input to output
        guard remapChannelDescriptions(
            inputLayoutPtr: audioProps.layoutPtr,
            outputLayoutPtr: outputLayoutPtr,
            channelMap: channelMap
        ) else {
            return nil
        }
        
        // Return immutable copy to prevent further modifications
        return NSData(data: outputLayoutData as Data)
    }
    
    /// Remap channel descriptions from input to output layout
    /// - Parameters:
    ///   - inputLayoutPtr: Pointer to the input AudioChannelLayout
    ///   - outputLayoutPtr: Pointer to the output AudioChannelLayout
    ///   - channelMap: Channel mapping array for remapping
    /// - Returns: true if remapping succeeds, false otherwise
    private func remapChannelDescriptions(
        inputLayoutPtr: UnsafePointer<AudioChannelLayout>,
        outputLayoutPtr: UnsafeMutablePointer<AudioChannelLayout>,
        channelMap: [Int]
    ) -> Bool {
        // Get pointers to input and output channel descriptions
        guard let inputDescPtr = getInputChannelDescriptionPointer(from: inputLayoutPtr),
              let outputDescPtr = getOutputChannelDescriptionPointer(from: outputLayoutPtr)
        else {
            return false
        }
        
        // Initialize all output descriptions as unused
        for i in 0..<8 {
            outputDescPtr.advanced(by: i).pointee = AudioChannelDescription(
                mChannelLabel: kAudioChannelLabel_Unused,
                mChannelFlags: AudioChannelFlags(rawValue: 0),
                mCoordinates: (0, 0, 0)
            )
        }
        
        // Remap channel descriptions based on channel map
        for outChannel in 0..<channelMap.count {
            let inChannel = channelMap[outChannel]
            if inChannel >= 0 && inChannel < 8 {
                outputDescPtr.advanced(by: outChannel).pointee = inputDescPtr.advanced(by: inChannel).pointee
            }
        }
        
        return true
    }
    
    /* ============================================ */
    // MARK: - CMBlockBuffer Utility Functions
    /* ============================================ */
    
    /// Ensure CMBlockBuffer is contiguous. If already contiguous, return the input buffer.
    /// If not contiguous, create a contiguous copy using CMBlockBufferCreateContiguous.
    /// - Parameter blockBuffer: The input CMBlockBuffer to check and potentially copy
    /// - Returns: A contiguous CMBlockBuffer, or nil if operation fails
    /// - Note: The returned buffer may be the same as input if already contiguous,
    ///         or a new contiguous copy if the input was fragmented.
    private func ensureContiguousBlockBuffer(_ blockBuffer: CMBlockBuffer) -> CMBlockBuffer? {
        // Check if the buffer is already contiguous
        let isContiguous = CMBlockBufferIsRangeContiguous(
            blockBuffer,
            atOffset: 0,
            length: 0 // 0 means check entire buffer
        )
        
        if isContiguous {
            // Buffer is already contiguous, return as-is
            return blockBuffer
        }
        
        // Buffer is fragmented, create a contiguous copy
        var contiguousBuffer: CMBlockBuffer? = nil
        let createStatus = CMBlockBufferCreateContiguous(
            allocator: nil,
            sourceBuffer: blockBuffer,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: 0, // 0 means copy entire buffer
            flags: 0,
            blockBufferOut: &contiguousBuffer
        )
        
        guard createStatus == noErr, let result = contiguousBuffer else {
            return nil
        }
        
        return result
    }
    
    /// Create a CMBlockBuffer with contiguous memory allocated using calloc.
    /// - Parameter memorySize: The size of memory to allocate in bytes
    /// - Returns: A CMBlockBuffer backed by contiguous memory, or nil if allocation fails
    /// - Note: The memory is zero-initialized by calloc and will be automatically freed
    ///         when the CMBlockBuffer is released.
    private func createContiguousBlockBuffer(memorySize: Int) -> CMBlockBuffer? {
        guard memorySize > 0 else {
            return nil
        }
        
        // Allocate zero-initialized contiguous memory using calloc
        guard let memoryBlock = calloc(1, memorySize) else {
            return nil
        }
        
        var blockBuffer: CMBlockBuffer? = nil
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: memoryBlock,
            blockLength: memorySize,
            blockAllocator: kCFAllocatorMalloc, // Use malloc/free for memory management
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: memorySize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard createStatus == noErr, let result = blockBuffer else {
            // Clean up allocated memory if CMBlockBuffer creation failed
            free(memoryBlock)
            return nil
        }
        
        return result
    }

}
