//
//  TrackBuffer.swift
//  TrapjawApp
//
//  Thread-safe in-memory buffer for crops per track.
//  Detects track termination and triggers early upload when threshold exceeded.
//

import Foundation
import CoreGraphics

struct BufferedCrop {
    let jpegData: Data
    let bbox: CGRect
    let frameIndex: UInt64
    let timestamp: Double
}

struct FinalizedTrack {
    let trackId: UInt32
    let stitchedId: UInt32
    let crops: [BufferedCrop]
    let resolution: StreamResolution
    let startIndex: Int          // Starting crop number for sequential filenames
    let trackIdString: String    // Stable track ID used across all batches
}

final class TrackBuffer {
    
    static let shared = TrackBuffer()
    
    private let queue = DispatchQueue(label: "com.trapjaw.trackbuffer")
    private var crops: [UInt32: [BufferedCrop]] = [:]
    private var lastCropFrame: [UInt32: UInt64] = [:]
    private var stitchedIds: [UInt32: UInt32] = [:]
    
    let maxCropsPerTrack: Int = 15
    
    private init() {}
    
    // Track how many crops have been uploaded per track for sequential filenames
    private var uploadedCropCounts: [UInt32: Int] = [:]
    
    // Stable track ID string per track (hexId + creation time), cached on first crop
    private var trackIdStrings: [UInt32: String] = [:]
    
    func setStitchedId(rawTrackId: UInt32, stitchedId: UInt32) {
        queue.sync {
            stitchedIds[rawTrackId] = stitchedId
        }
    }
    
    func addCrop(
        trackId: UInt32,
        bbox: CGRect,
        frameIndex: UInt64,
        timestamp: Double,
        jpegData: Data,
        resolution: StreamResolution
    ) -> FinalizedTrack? {
        var trackToUpload: FinalizedTrack?
        
        queue.sync {
            let bufferedCrop = BufferedCrop(
                jpegData: jpegData,
                bbox: bbox,
                frameIndex: frameIndex,
                timestamp: timestamp
            )
            
            if crops[trackId] == nil {
                crops[trackId] = []
                // Generate stable track ID string on first crop of this track
                if trackIdStrings[trackId] == nil {
                    let stitchedId = stitchedIds[trackId] ?? trackId
                    let hexId = String(format: "%08x", stitchedId)
                    let timeStr = dateFormatter.string(from: Date())
                    trackIdStrings[trackId] = "\(hexId)_\(timeStr)"
                }
            }
            crops[trackId]?.append(bufferedCrop)
            lastCropFrame[trackId] = frameIndex
            
            if let cropCount = crops[trackId]?.count, cropCount >= maxCropsPerTrack {
                trackToUpload = finalizeTrackInternal(trackId: trackId, resolution: resolution, isFinal: false)
            }
        }
        
        return trackToUpload
    }
    
    func finalizeTerminatedTracks(
        activeTrackIds: Set<UInt32>,
        resolution: StreamResolution
    ) -> [FinalizedTrack] {
        var terminatedTracks: [FinalizedTrack] = []
        
        queue.sync {
            let bufferedTrackIds = Set(crops.keys)
            let terminatedIds = bufferedTrackIds.subtracting(activeTrackIds)
            
            for trackId in terminatedIds {
                if let finalized = finalizeTrackInternal(trackId: trackId, resolution: resolution, isFinal: true) {
                    terminatedTracks.append(finalized)
                }
            }
        }
        
        return terminatedTracks
    }
    
    func clear() {
        queue.sync {
            crops.removeAll()
            lastCropFrame.removeAll()
            stitchedIds.removeAll()
            uploadedCropCounts.removeAll()
            trackIdStrings.removeAll()
        }
    }
    
    private func finalizeTrackInternal(trackId: UInt32, resolution: StreamResolution, isFinal: Bool) -> FinalizedTrack? {
        guard let trackCrops = crops[trackId], !trackCrops.isEmpty else { return nil }
        
        let stitchedId = stitchedIds[trackId] ?? trackId
        
        // Get the starting index (how many crops already uploaded for this track)
        let startIndex = uploadedCropCounts[trackId] ?? 0
        
        // Update the uploaded count for next batch
        uploadedCropCounts[trackId] = startIndex + trackCrops.count
        
        // Get the stable track ID string (should always exist if we have crops)
        let trackIdString = trackIdStrings[trackId] ?? "unknown"
        
        crops.removeValue(forKey: trackId)
        lastCropFrame.removeValue(forKey: trackId)
        stitchedIds.removeValue(forKey: trackId)
        
        if isFinal {
            // Clear the count and ID string for this track so recycled IDs start fresh
            uploadedCropCounts.removeValue(forKey: trackId)
            trackIdStrings.removeValue(forKey: trackId)
        }
        
        return FinalizedTrack(
            trackId: trackId,
            stitchedId: stitchedId,
            crops: trackCrops,
            resolution: resolution,
            startIndex: startIndex,
            trackIdString: trackIdString
        )
    }
}

private let dateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "HHmmss"
    return df
}()
