//
//  CaptureErrorHelper.swift
//  DLABCapture
//
//  Created by Takashi Mochizuki on 2026/05/11.
//  Copyright © 2026 MyCometG3. All rights reserved.
//

import Foundation

private let errorDomain = "com.MyCometG3.DLABCaptureManager.ErrorDomain"

/// Create an NSError in the shared DLABCapture error domain.
internal func createError(_ status: OSStatus,
                          _ description: String?,
                          _ failureReason: String?) -> NSError {
    let code = NSInteger(status)
    let desc = description ?? "unknown description"
    let reason = failureReason ?? "unknown failureReason"
    let userInfo: [String: Any] = [NSLocalizedDescriptionKey: desc,
                                   NSLocalizedFailureReasonErrorKey: reason]
    return NSError(domain: errorDomain, code: code, userInfo: userInfo)
}
