//
//  TrapjawBridge.swift
//  TrapjawApp
//
//  Thin Swift wrapper around the trapjaw C API. Manages the opaque
//  tj_context_t lifecycle and provides Swift-friendly method signatures.
//

import Foundation
import Metal
import CoreVideo
import os.log

private let bridgeLog = Logger(subsystem: "com.trapjaw.bridge", category: "TrapjawBridge")

/// Data extracted from a trapjaw crop callback, safe to hold beyond the callback lifetime.
struct CropData {
    let trackID: UInt32
    let bbox: CGRect
    let width: UInt32
    let height: UInt32
    let frameIndex: UInt64
    let timestamp: Double
    let pixelData: Data
}

/// Swift wrapper around the trapjaw C context.
final class TrapjawBridge {

    private var context: OpaquePointer?   // tj_context_t*

    /// Callback invoked on the processing thread when a crop is emitted.
    var onCrop: ((CropData) -> Void)?

    /// Callback invoked on the processing thread with per-frame pipeline timing.
    var onDebugFrame: ((Double, UInt32, UInt64) -> Void)?  // (pipelineMs, activeTracks, frameIndex)

    // MARK: - Lifecycle

    /// Initialize trapjaw with the given config and Metal device.
    ///
    /// - Parameters:
    ///   - config: Trapjaw configuration. Use `tj_config_defaults()` as a starting point.
    ///   - device: The Metal device for GPU-accelerated processing, or nil for CPU-only mode.
    init(config: tj_config_t, device: MTLDevice?) throws {
        var cfg = config
        let metalPtr = device.map { Unmanaged.passUnretained($0).toOpaque() }

        bridgeLog.info("TrapjawBridge init: frame=\(cfg.frame_width)x\(cfg.frame_height), fps=\(cfg.fps), gmm_components=\(cfg.gmm_num_components), history=\(cfg.gmm_history), metal_device=\(device != nil ? "yes" : "no")")

        guard let ctx = tj_create(&cfg, metalPtr) else {
            bridgeLog.error("TrapjawBridge init: tj_create returned NULL")
            throw TrapjawError.initFailed
        }
        self.context = ctx
        bridgeLog.info("TrapjawBridge init: tj_create succeeded, context=\(String(describing: ctx))")

        let hasGPU = metalPtr != nil
        let stats = tj_get_stats(ctx)
        bridgeLog.info("TrapjawBridge init: initial stats frames_processed=\(stats.frames_processed), total_crops=\(stats.total_crops_emitted)")

        // Set up crop callback with self as user_data
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        tj_set_crop_callback(ctx, { (crop, userData) in
            guard let crop = crop, let userData = userData else { return }
            let bridge = Unmanaged<TrapjawBridge>.fromOpaque(userData).takeUnretainedValue()
            bridge.handleCrop(crop.pointee)
        }, selfPtr)

        tj_set_debug_callback(ctx, { (frame, userData) in
            guard let frame = frame, let userData = userData else { return }
            let bridge = Unmanaged<TrapjawBridge>.fromOpaque(userData).takeUnretainedValue()
            bridge.handleDebugFrame(frame.pointee)
        }, selfPtr)
    }

    deinit {
        if let ctx = context {
            tj_destroy(ctx)
        }
        context = nil
    }

    // MARK: - Frame Processing

    /// Process a single frame from a CVPixelBuffer.
    ///
    /// Locks the pixel buffer, constructs a `tj_frame_t` with the raw pixel pointer,
    /// and feeds it through the trapjaw pipeline. The pixel buffer must be BGRA8.
    ///
    /// - Parameters:
    ///   - pixelBuffer: A locked or lockable CVPixelBuffer in BGRA8 format.
    ///   - frameIndex: Monotonic frame counter.
    ///   - timestamp: Presentation timestamp in seconds.
    /// - Returns: The trapjaw result code.
    private var debugFrameCount: UInt64 = 0
    private var cropCount: UInt64 = 0

    @discardableResult
    func processFrame(
        pixelBuffer: CVPixelBuffer,
        frameIndex: UInt64,
        timestamp: Double
    ) -> tj_result_t {
        guard let ctx = context else { return TJ_ERROR_INVALID_ARG }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let width = UInt32(CVPixelBufferGetWidth(pixelBuffer))
        let height = UInt32(CVPixelBufferGetHeight(pixelBuffer))
        let bytesPerRow = UInt32(CVPixelBufferGetBytesPerRow(pixelBuffer))

        if frameIndex == 0 {
            bridgeLog.info("processFrame: first frame \(width)x\(height), bpr=\(bytesPerRow), ptr=\(String(describing: baseAddress))")
        }

        var frame = tj_frame_t()
        frame.pixels = UnsafeRawPointer(baseAddress)
        frame.pixel_buffer = nil
        frame.metal_texture = nil
        frame.width = width
        frame.height = height
        frame.bytes_per_row = bytesPerRow
        frame.format = TJ_PIXEL_FORMAT_BGRA8
        frame.frame_index = frameIndex
        frame.timestamp_sec = timestamp

        let result = tj_process_frame(ctx, &frame)

        if frameIndex < 5 {
            bridgeLog.info("processFrame: frame=\(frameIndex) result=\(result.rawValue) (TJ_OK=0, NOT_READY=9)")
        }

        if result == TJ_OK && frameIndex % 300 == 0 && frameIndex > 0 {
            let stats = tj_get_stats(ctx)
            bridgeLog.info("processFrame periodic: frame=\(frameIndex) frames_processed=\(stats.frames_processed) tracks_created=\(stats.total_tracks_created) tracks_stitched=\(stats.total_tracks_stitched) crops=\(stats.total_crops_emitted) avg_ms=\(stats.avg_pipeline_time_ms)")
        }

        return result
    }

    /// Flush pending operations and destroy context.
    func flush() {
        guard let ctx = context else { return }
        context = nil
        tj_destroy(ctx)
    }

    // MARK: - Queries

    /// Get the current cumulative statistics.
    func getStats() -> tj_stats_t {
        guard let ctx = context else { return tj_stats_t() }
        return tj_get_stats(ctx)
    }

    /// Get currently active track count.
    func getActiveTrackCount() -> UInt32 {
        guard let ctx = context else { return 0 }
        return tj_get_active_tracks(ctx, nil, 0)
    }
    
    /// Get the set of currently active track IDs.
    func getActiveTrackIds() -> Set<UInt32> {
        guard let ctx = context else { return [] }
        
        let count = tj_get_active_tracks(ctx, nil, 0)
        guard count > 0 else { return [] }
        
        var tracks = [tj_track_t](repeating: tj_track_t(), count: Int(count))
        let actualCount = tj_get_active_tracks(ctx, &tracks, count)
        
        var trackIds = Set<UInt32>()
        for i in 0..<Int(actualCount) {
            trackIds.insert(tracks[i].id)
        }
        return trackIds
    }
    
    /// Get the stitched ID for a raw track ID.
    func getStitchedId(rawTrackId: UInt32) -> UInt32 {
        guard let ctx = context else { return rawTrackId }
        return tj_get_stitched_id(ctx, rawTrackId)
    }

    // MARK: - Callback Handlers

    private func handleCrop(_ crop: tj_crop_t) {
        let myCount = cropCount
        cropCount += 1
        if myCount < 3 {
            bridgeLog.info("handleCrop #\(myCount): track_id=\(crop.track_id) bbox=\(crop.bbox.x),\(crop.bbox.y) \(crop.bbox.w)x\(crop.bbox.h) frame=\(crop.frame_index)")
        }

        let byteCount = Int(crop.bytes_per_row) * Int(crop.height)
        let pixelData = Data(bytes: crop.pixels, count: byteCount)

        let cropData = CropData(
            trackID: crop.track_id,
            bbox: CGRect(
                x: CGFloat(crop.bbox.x),
                y: CGFloat(crop.bbox.y),
                width: CGFloat(crop.bbox.w),
                height: CGFloat(crop.bbox.h)
            ),
            width: crop.width,
            height: crop.height,
            frameIndex: crop.frame_index,
            timestamp: crop.timestamp_sec,
            pixelData: pixelData
        )

        onCrop?(cropData)
    }

    private func handleDebugFrame(_ frame: tj_debug_frame_t) {
        let myCount = debugFrameCount
        debugFrameCount += 1
        if myCount < 5 || myCount % 300 == 0 {
            bridgeLog.info("handleDebugFrame #\(myCount): pipeline_ms=\(String(format: "%.2f", frame.pipeline_time_ms)) tracks=\(frame.active_track_count) blobs=\(frame.blob_count) frame=\(frame.frame_index)")
        }
        onDebugFrame?(frame.pipeline_time_ms, frame.active_track_count, frame.frame_index)
    }
}

// MARK: - Errors

enum TrapjawError: LocalizedError {
    case initFailed

    var errorDescription: String? {
        switch self {
        case .initFailed:
            return "Failed to initialize trapjaw context. Check config and Metal device availability."
        }
    }
}
