//
//  PerformanceMetrics.swift
//  TrapjawApp
//
//  Observable object that tracks real-time performance metrics
//  from both the camera pipeline and trapjaw processing.
//

import Foundation

@Observable
final class PerformanceMetrics {

    // MARK: - Published Metrics

    /// Camera capture frame rate (frames delivered per second).
    private(set) var cameraFPS: Double = 0

    /// Trapjaw processing frame rate (frames processed per second).
    private(set) var processingFPS: Double = 0

    /// Average pipeline latency in milliseconds (from tj_stats_t).
    private(set) var avgPipelineMs: Double = 0

    /// Peak pipeline latency in milliseconds.
    private(set) var maxPipelineMs: Double = 0

    /// Average GPU time per frame in milliseconds.
    private(set) var avgGpuMs: Double = 0

    /// Average CPU time per frame in milliseconds.
    private(set) var avgCpuMs: Double = 0

    /// Number of currently active tracks.
    private(set) var activeTrackCount: UInt32 = 0

    /// Total frames processed since start.
    private(set) var totalFrames: UInt64 = 0

    /// Total crops emitted since start.
    private(set) var totalCrops: UInt64 = 0

    /// Total tracks created since start.
    private(set) var totalTracks: UInt64 = 0

    /// Whether the pipeline is currently in warmup (background model learning).
    private(set) var isWarmingUp: Bool = true

    // MARK: - Internal Tracking

    private var cameraFrameTimestamps: [CFAbsoluteTime] = []
    private var processFrameTimestamps: [CFAbsoluteTime] = []
    private let fpsWindow: TimeInterval = 1.0  // 1-second sliding window

    // MARK: - Update Methods

    /// Record that a camera frame was delivered.
    func recordCameraFrame() {
        let now = CFAbsoluteTimeGetCurrent()
        cameraFrameTimestamps.append(now)
        pruneTimestamps(&cameraFrameTimestamps, before: now - fpsWindow)
        cameraFPS = Double(cameraFrameTimestamps.count) / fpsWindow
    }

    /// Record that a frame was processed by trapjaw.
    func recordProcessedFrame() {
        let now = CFAbsoluteTimeGetCurrent()
        processFrameTimestamps.append(now)
        pruneTimestamps(&processFrameTimestamps, before: now - fpsWindow)
        processingFPS = Double(processFrameTimestamps.count) / fpsWindow
    }

    /// Update metrics from trapjaw statistics.
    func updateFromStats(_ stats: tj_stats_t) {
        totalFrames = stats.frames_processed
        totalCrops = stats.total_crops_emitted
        totalTracks = stats.total_tracks_created
        avgPipelineMs = stats.avg_pipeline_time_ms
        maxPipelineMs = stats.max_pipeline_time_ms
        avgGpuMs = stats.avg_gpu_time_ms
        avgCpuMs = stats.avg_cpu_time_ms
    }

    /// Update the active track count.
    func updateActiveTrackCount(_ count: UInt32) {
        activeTrackCount = count
    }

    /// Update warmup status based on frame count and config warmup frames.
    func updateWarmupStatus(framesProcessed: UInt64, warmupFrames: UInt32) {
        isWarmingUp = framesProcessed < UInt64(warmupFrames)
    }

    /// Reset all metrics to zero.
    func reset() {
        cameraFPS = 0
        processingFPS = 0
        avgPipelineMs = 0
        maxPipelineMs = 0
        avgGpuMs = 0
        avgCpuMs = 0
        activeTrackCount = 0
        totalFrames = 0
        totalCrops = 0
        totalTracks = 0
        isWarmingUp = true
        cameraFrameTimestamps.removeAll()
        processFrameTimestamps.removeAll()
    }

    // MARK: - Helpers

    private func pruneTimestamps(_ timestamps: inout [CFAbsoluteTime], before cutoff: CFAbsoluteTime) {
        timestamps.removeAll { $0 < cutoff }
    }
}
