//
//  TimingMetrics.swift
//  TrapjawApp
//
//  Timing and memory diagnostics for the pipeline.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.trapjaw.timing", category: "TimingMetrics")

struct StageTiming {
    var count: Int = 0
    var totalMs: Double = 0
    var minMs: Double = Double.infinity
    var maxMs: Double = 0
    var lastMs: Double = 0
    
    mutating func record(durationMs: Double) {
        count += 1
        totalMs += durationMs
        minMs = min(minMs, durationMs)
        maxMs = max(maxMs, durationMs)
        lastMs = durationMs
    }
    
    var avgMs: Double {
        return count > 0 ? totalMs / Double(count) : 0
    }
    
    mutating func reset() {
        count = 0
        totalMs = 0
        minMs = Double.infinity
        maxMs = 0
        lastMs = 0
    }
}

final class TimingMetrics {
    
    // MARK: - Stage Timings
    
    var bufferStore = StageTiming()
    var downscale = StageTiming()
    var trapjawProcess = StageTiming()
    var cropLookup = StageTiming()
    var cropExtract = StageTiming()
    var jpegConvert = StageTiming()
    var totalPipeline = StageTiming()
    
    // MARK: - Frame Timing
    
    private var frameStartTime: CFAbsoluteTime = 0
    private var lastFrameLogTime: CFAbsoluteTime = 0
    private var frameCount: UInt64 = 0
    
    // MARK: - FPS Tracking
    
    private var frameTimestamps: [CFAbsoluteTime] = []
    private let fpsWindow: TimeInterval = 1.0
    
    // MARK: - Public API
    
    /// Mark the start of a frame processing cycle.
    func startFrame() {
        frameStartTime = CFAbsoluteTimeGetCurrent()
    }
    
    /// Mark the end of a frame processing cycle and return total duration.
    func endFrame() -> Double {
        let endTime = CFAbsoluteTimeGetCurrent()
        let durationMs = (endTime - frameStartTime) * 1000
        totalPipeline.record(durationMs: durationMs)
        
        // Track FPS
        frameTimestamps.append(endTime)
        let cutoff = endTime - fpsWindow
        frameTimestamps.removeAll { $0 < cutoff }
        
        return durationMs
    }
    
    /// Record a stage timing.
    func record(stage: inout StageTiming, durationMs: Double) {
        stage.record(durationMs: durationMs)
    }
    
    /// Get current FPS.
    var currentFPS: Double {
        return Double(frameTimestamps.count) / fpsWindow
    }
    
    /// Get memory usage in MB.
    var memoryMB: Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }
    
    /// Log a summary every 60 frames.
    func logSummaryIfNeeded(frameIndex: UInt64, bufferDepth: Int) {
        frameCount += 1
        
        if frameCount % 60 == 0 {
            print("[TIMING] Frame \(frameIndex) | FPS: \(String(format: "%.1f", currentFPS))")
            print("[TIMING] Buffer: \(String(format: "%.2f", bufferStore.lastMs))ms | Downscale: \(String(format: "%.2f", downscale.lastMs))ms | Trapjaw: \(String(format: "%.2f", trapjawProcess.lastMs))ms")
            print("[TIMING] Total: \(String(format: "%.2f", totalPipeline.lastMs))ms | Memory: \(String(format: "%.1f", memoryMB)) MB | Buffer Depth: \(bufferDepth)")
        }
    }
    
    /// Reset all metrics.
    func reset() {
        bufferStore.reset()
        downscale.reset()
        trapjawProcess.reset()
        cropLookup.reset()
        cropExtract.reset()
        jpegConvert.reset()
        totalPipeline.reset()
        frameTimestamps.removeAll()
        frameCount = 0
    }
}