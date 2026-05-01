//
//  FourKFrameBuffer.swift
//  TrapjawApp
//
//  Rolling buffer for4K frames using CVPixelBufferPool.
//  Stores recent4K frames indexed by frame_index for crop extraction.
//

import Foundation
import CoreVideo
import os.log

private let logger = Logger(subsystem: "com.trapjaw.4kbuffer", category: "FourKFrameBuffer")

final class FourKFrameBuffer {
    
    // MARK: - Configuration
    
    private let maxFrames: Int
    private let width: Int = 3840
    private let height: Int = 2160
    
    // MARK: - State
    
    private var frames: [UInt64: CVPixelBuffer] = [:]
    private var frameOrder: [UInt64] = []
    private let queue = DispatchQueue(label: "com.trapjaw.4kbuffer", qos: .userInitiated)
    
    // MARK: - Statistics
    
    private(set) var totalFramesStored: UInt64 = 0
    private(set) var totalFramesDropped: UInt64 = 0
    private(set) var totalCropsMissed: UInt64 = 0
    
    // MARK: - Init
    
    init(maxFrames: Int = 5) {  // Reduced from 10 to 5 for memory efficiency (~165MB vs ~330MB)
        self.maxFrames = maxFrames
    }
    
    // MARK: - Public API
    
    /// Add a 4K frame to the buffer.
    /// - Parameters:
    ///   - pixelBuffer: The 4K CVPixelBuffer to store
    ///   - frameIndex: Monotonic frame counter
    func add(pixelBuffer: CVPixelBuffer, frameIndex: UInt64) {
        queue.sync(flags: .barrier) {
            // Store the frame
            frames[frameIndex] = pixelBuffer
            frameOrder.append(frameIndex)
            totalFramesStored += 1
            
            // Diagnostic logging every 60 frames
            if frameIndex % 60 == 0 {
                let oldest = frameOrder.first ?? 0
                let newest = frameOrder.last ?? 0
                print("[BUFFER] Added frame \(frameIndex), buffer: \(frames.count)/\(maxFrames), range: [\(oldest)...\(newest)]")
            }
            
            // Remove oldest frames if buffer is full
            while frameOrder.count > maxFrames {
                guard let oldestIndex = frameOrder.first else { break }
                frameOrder.removeFirst()
                frames.removeValue(forKey: oldestIndex)
                totalFramesDropped += 1
                
                // Log eviction
                if frameIndex % 60 == 0 {
                    print("[BUFFER] ⚠️ Evicted frame \(oldestIndex) (buffer full)")
                }
            }
        }
    }
    
    /// Retrieve a 4K frame by frame index.
    /// - Parameter frameIndex: The frame index to look up
    /// - Returns: The CVPixelBuffer if available, nil if dropped or not found
    func get(frameIndex: UInt64) -> CVPixelBuffer? {
        return queue.sync {
            if frames[frameIndex] == nil {
                totalCropsMissed += 1
                // Log miss every 20th miss to avoid spam
                if totalCropsMissed % 20 == 1 {
                    let oldest = frameOrder.first ?? 0
                    let newest = frameOrder.last ?? 0
                    print("[BUFFER] ❌ Missed frame \(frameIndex), buffer has [\(oldest)...\(newest)]")
                }
            }
            return frames[frameIndex]
        }
    }
    
    /// Check if a frame is available in the buffer.
    /// - Parameter frameIndex: The frame index to check
    /// - Returns: true if frame is available
    func contains(frameIndex: UInt64) -> Bool {
        return queue.sync { frames[frameIndex] != nil }
    }
    
    /// Get the number of frames currently in the buffer.
    var currentCount: Int {
        return queue.sync { frames.count }
    }
    
    /// Get the most recent frame from the buffer.
    /// Returns nil if the buffer is empty.
    func getLatestFrame() -> CVPixelBuffer? {
        return queue.sync {
            guard let latestIndex = frameOrder.last else { return nil }
            return frames[latestIndex]
        }
    }
    
    /// Clear all frames from the buffer.
    func clear() {
        queue.sync(flags: .barrier) {
            frames.removeAll()
            frameOrder.removeAll()
        }
    }
    
    /// Reduce buffer capacity (for memory pressure handling).
    /// - Parameter newCapacity: New maximum frame count
    func reduceCapacity(to newCapacity: Int) {
        queue.sync(flags: .barrier) {
            while frameOrder.count > newCapacity {
                guard let oldestIndex = frameOrder.first else { break }
                frameOrder.removeFirst()
                frames.removeValue(forKey: oldestIndex)
                totalFramesDropped += 1
            }
        }
    }
    
    // MARK: - Statistics
    
    /// Get current buffer statistics.
    func getStats() -> BufferStats {
        return queue.sync {
            BufferStats(
                framesInBuffer: frames.count,
                maxCapacity: maxFrames,
                totalStored: totalFramesStored,
                totalDropped: totalFramesDropped,
                totalCropsMissed: totalCropsMissed
            )
        }
    }
}

// MARK: - Statistics Structure

struct BufferStats {
    let framesInBuffer: Int
    let maxCapacity: Int
    let totalStored: UInt64
    let totalDropped: UInt64
    let totalCropsMissed: UInt64
}