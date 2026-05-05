//
//  RecordedMovieTimeRangeNormalizer.swift
//  DLABCaptureManager
//
//  Created by Takashi Mochizuki on 2026/05/05.
//  Copyright © 2026 MyCometG3. All rights reserved.
//

import Foundation
import AVFoundation
import UniformTypeIdentifiers

internal enum RecordedMovieReferenceMediaKind: String, Sendable {
    case video
    case audio
    
    var mediaCharacteristic: AVMediaCharacteristic {
        switch self {
        case .video:
            return .visual
        case .audio:
            return .audible
        }
    }
}

internal struct RecordedMovieNormalizationResult: Sendable {
    let didRewrite: Bool
    let mediaKind: RecordedMovieReferenceMediaKind
    let selectedRange: CMTimeRange
}

internal enum RecordedMovieTimeRangeNormalizationError: Error, LocalizedError {
    case unsupportedMovieFileType(String)
    case movieOpenFailed(String)
    case movieDurationUnavailable
    case noEligibleVideoOrAudioTrack
    case selectedRangeUnavailable(RecordedMovieReferenceMediaKind)
    case destinationMoviePreparationFailed(String)
    case movieRangeInsertFailed(String)
    case movieHeaderWriteFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedMovieFileType(let reason):
            return "Unsupported movie file type: \(reason)."
        case .movieOpenFailed(let reason):
            return "Failed to open movie: \(reason)."
        case .movieDurationUnavailable:
            return "Movie duration is unavailable."
        case .noEligibleVideoOrAudioTrack:
            return "No eligible video or audio track was found."
        case .selectedRangeUnavailable(let mediaKind):
            return "Selected \(mediaKind.rawValue) range is unavailable."
        case .destinationMoviePreparationFailed(let reason):
            return "Failed to prepare destination movie: \(reason)."
        case .movieRangeInsertFailed(let reason):
            return "Failed to insert movie range: \(reason)."
        case .movieHeaderWriteFailed(let reason):
            return "Failed to write movie header: \(reason)."
        }
    }
}

internal enum RecordedMovieTimeRangeNormalizer {
    @discardableResult
    static func normalizeMovie(at movieURL: URL) throws -> RecordedMovieNormalizationResult {
        try validateMovieFileType(at: movieURL)
        let sourceMovie = try openSourceMovie(at: movieURL)
        let (mediaKind, selectedRange) = try chooseReferenceRange(in: sourceMovie)
        let movieRange = try moviePresentationRange(for: sourceMovie)
        let selectedEnd = CMTimeRangeGetEnd(selectedRange)
        let movieEnd = CMTimeRangeGetEnd(movieRange)
        
        let needsLeadingTrim = CMTimeCompare(selectedRange.start, movieRange.start) > 0
        let needsTrailingTrim = CMTimeCompare(selectedEnd, movieEnd) < 0
        guard needsLeadingTrim || needsTrailingTrim else {
            return RecordedMovieNormalizationResult(
                didRewrite: false,
                mediaKind: mediaKind,
                selectedRange: selectedRange
            )
        }
        
        let trimmedMovie = try buildTrimmedMovie(from: sourceMovie, selectedRange: selectedRange)
        try commit(movie: trimmedMovie, to: movieURL)
        
        return RecordedMovieNormalizationResult(
            didRewrite: true,
            mediaKind: mediaKind,
            selectedRange: selectedRange
        )
    }
    
    private static func validateMovieFileType(at movieURL: URL) throws {
        guard movieURL.isFileURL else {
            throw RecordedMovieTimeRangeNormalizationError.movieOpenFailed("URL is not a file URL: \(movieURL.absoluteString)")
        }
        
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey, .typeIdentifierKey]
        let resourceValues: URLResourceValues
        do {
            resourceValues = try movieURL.resourceValues(forKeys: resourceKeys)
        } catch {
            throw RecordedMovieTimeRangeNormalizationError.movieOpenFailed("\(movieURL.path): \(error.localizedDescription)")
        }
        
        guard resourceValues.isRegularFile == true else {
            throw RecordedMovieTimeRangeNormalizationError.movieOpenFailed("Path is not a regular file: \(movieURL.path)")
        }
        
        if let contentType = resourceValues.contentType {
            guard contentType == .quickTimeMovie || contentType.conforms(to: .quickTimeMovie) else {
                throw RecordedMovieTimeRangeNormalizationError.unsupportedMovieFileType("\(movieURL.path) (\(contentType.identifier))")
            }
            return
        }
        
        if let typeIdentifier = resourceValues.typeIdentifier, typeIdentifier == AVFileType.mov.rawValue {
            return
        }
        
        throw RecordedMovieTimeRangeNormalizationError.unsupportedMovieFileType(movieURL.path)
    }
    
    private static func openSourceMovie(at movieURL: URL) throws -> AVMutableMovie {
        let movie = AVMutableMovie(url: movieURL, options: nil)
        
        let duration = movie.duration
        guard duration.isValid, !duration.isIndefinite else {
            throw RecordedMovieTimeRangeNormalizationError.movieDurationUnavailable
        }
        
        return movie
    }
    
    private static func nonEmptyPresentationUnion(for track: AVMutableMovieTrack) -> CMTimeRange? {
        var unionRange: CMTimeRange? = nil
        
        for segment in track.segments where !segment.isEmpty {
            let segmentRange = segment.timeMapping.target
            guard segmentRange.isValid, !segmentRange.isEmpty else { continue }
            
            if let current = unionRange {
                unionRange = CMTimeRangeGetUnion(current, otherRange: segmentRange)
            } else {
                unionRange = segmentRange
            }
        }
        
        guard let unionRange, unionRange.isValid, !unionRange.isEmpty else {
            return nil
        }
        
        return unionRange
    }
    
    private static func aggregatePresentationUnion(in movie: AVMutableMovie,
                                                   characteristic: AVMediaCharacteristic) -> CMTimeRange? {
        var unionRange: CMTimeRange? = nil
        
        for track in movie.tracks(withMediaCharacteristic: characteristic) {
            guard let trackRange = nonEmptyPresentationUnion(for: track) else { continue }
            if let current = unionRange {
                unionRange = CMTimeRangeGetUnion(current, otherRange: trackRange)
            } else {
                unionRange = trackRange
            }
        }
        
        guard let unionRange, unionRange.isValid, !unionRange.isEmpty else {
            return nil
        }
        
        return unionRange
    }
    
    private static func chooseReferenceRange(in movie: AVMutableMovie) throws -> (RecordedMovieReferenceMediaKind, CMTimeRange) {
        if let videoRange = aggregatePresentationUnion(in: movie, characteristic: .visual) {
            return try validatedSelection(videoRange, mediaKind: .video)
        }
        
        if let audioRange = aggregatePresentationUnion(in: movie, characteristic: .audible) {
            return try validatedSelection(audioRange, mediaKind: .audio)
        }
        
        throw RecordedMovieTimeRangeNormalizationError.noEligibleVideoOrAudioTrack
    }
    
    private static func validatedSelection(_ range: CMTimeRange,
                                           mediaKind: RecordedMovieReferenceMediaKind) throws -> (RecordedMovieReferenceMediaKind, CMTimeRange) {
        guard range.isValid, !range.isEmpty else {
            throw RecordedMovieTimeRangeNormalizationError.selectedRangeUnavailable(mediaKind)
        }
        return (mediaKind, range)
    }
    
    private static func moviePresentationRange(for movie: AVMutableMovie) throws -> CMTimeRange {
        let duration = movie.duration
        guard duration.isValid, !duration.isIndefinite else {
            throw RecordedMovieTimeRangeNormalizationError.movieDurationUnavailable
        }
        
        let range = CMTimeRange(start: .zero, duration: duration)
        guard range.isValid else {
            throw RecordedMovieTimeRangeNormalizationError.movieDurationUnavailable
        }
        
        return range
    }
    
    private static func buildTrimmedMovie(from sourceMovie: AVMutableMovie,
                                          selectedRange: CMTimeRange) throws -> AVMutableMovie {
        let destinationMovie: AVMutableMovie
        do {
            destinationMovie = try AVMutableMovie(settingsFrom: sourceMovie, options: nil)
        } catch {
            throw RecordedMovieTimeRangeNormalizationError.destinationMoviePreparationFailed(error.localizedDescription)
        }
        
        do {
            try destinationMovie.insertTimeRange(selectedRange, of: sourceMovie, at: .zero, copySampleData: false)
        } catch {
            throw RecordedMovieTimeRangeNormalizationError.movieRangeInsertFailed(error.localizedDescription)
        }
        
        return destinationMovie
    }
    
    private static func commit(movie: AVMutableMovie, to originalURL: URL) throws {
        do {
            try movie.writeHeader(to: originalURL,
                                  fileType: .mov,
                                  options: .addMovieHeaderToDestination)
        } catch {
            throw RecordedMovieTimeRangeNormalizationError.movieHeaderWriteFailed("\(originalURL.path): \(error.localizedDescription)")
        }
    }
}
