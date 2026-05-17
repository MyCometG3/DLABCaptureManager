//
//  AACFamilyHelper.swift
//  DLABCapture
//
//  Created by Takashi Mochizuki on 2026/05/11.
//  Copyright © 2026 MyCometG3. All rights reserved.
//

import AudioToolbox

/// Returns true if the AudioFormatID is within the AAC family range
/// (MPEG-4 AAC through HE-AAC v2).
internal func isAACFamily(_ formatID: UInt32) -> Bool {
    return (formatID >= kAudioFormatMPEG4AAC && formatID <= kAudioFormatMPEG4AAC_HE_V2)
}
