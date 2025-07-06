//
//  VideoSampleBufferHelper.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2025/07/06.
//  Copyright © 2025 MyCometG3. All rights reserved.
//

import Cocoa
import AVFoundation
import CoreVideo

/* ================================================ */
// MARK: - Video SampleBuffer Helper
/* ================================================ */

internal final class VideoSampleBufferHelper: @unchecked Sendable {
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
        sbwOut = await Task.detached(priority: .high) { [weak self] in
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
