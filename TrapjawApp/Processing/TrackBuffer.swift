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
}

final class TrackBuffer {
    
    static let shared = TrackBuffer()
    
    private let queue = DispatchQueue(label: "com.trapjaw.trackbuffer")
    private var crops: [UInt32: [BufferedCrop]] = [:]
    private var lastCropFrame: [UInt32: UInt64] = [:]
    private var stitchedIds: [UInt32: UInt32] = [:]
    
    let maxCropsPerTrack: Int = 150
    let terminationCheckInterval: UInt64 = 60
    
    private init() {}
    
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
            }
            crops[trackId]?.append(bufferedCrop)
            lastCropFrame[trackId] = frameIndex
            
            if let cropCount = crops[trackId]?.count, cropCount >= maxCropsPerTrack {
                trackToUpload = finalizeTrackInternal(trackId: trackId, resolution: resolution)
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
                if let finalized = finalizeTrackInternal(trackId: trackId, resolution: resolution) {
                    terminatedTracks.append(finalized)
                }
            }
        }
        
        return terminatedTracks
    }
    
    func getActiveBufferedTrackIds() -> Set<UInt32> {
        return queue.sync { Set(crops.keys) }
    }
    
    func getBufferedCropCount(for trackId: UInt32) -> Int {
        return queue.sync { crops[trackId]?.count ?? 0 }
    }
    
    func getTotalBufferedCropCount() -> Int {
        return queue.sync { crops.values.reduce(0) { $0 + $1.count } }
    }
    
    func clear() {
        queue.sync {
            crops.removeAll()
            lastCropFrame.removeAll()
            stitchedIds.removeAll()
        }
    }
    
    private func finalizeTrackInternal(trackId: UInt32, resolution: StreamResolution) -> FinalizedTrack? {
        guard let trackCrops = crops[trackId], !trackCrops.isEmpty else { return nil }
        
        let stitchedId = stitchedIds[trackId] ?? trackId
        
        crops.removeValue(forKey: trackId)
        lastCropFrame.removeValue(forKey: trackId)
        stitchedIds.removeValue(forKey: trackId)
        
        return FinalizedTrack(
            trackId: trackId,
            stitchedId: stitchedId,
            crops: trackCrops,
            resolution: resolution
        )
    }
}
