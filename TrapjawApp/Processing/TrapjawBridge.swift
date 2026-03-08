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

/// Data extracted from a trapjaw crop callback, safe to hold beyond the callback lifetime.
struct CropData {
    let trackID: UInt32
    let bbox: tj_bbox_t
    let width: UInt32
    let height: UInt32
    let frameIndex: UInt64
    let timestamp: Double
    let pixelData: Data  // Copy of BGRA8 pixels
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

        guard let ctx = tj_create(&cfg, metalPtr) else {
            throw TrapjawError.initFailed
        }
        self.context = ctx

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
            tj_flush(ctx)
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

        return tj_process_frame(ctx, &frame)
    }

    /// Flush the async GPU pipeline. Must be called after the last frame.
    func flush() {
        guard let ctx = context else { return }
        tj_flush(ctx)
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
        // Pass nil buffer with 0 max to just get the count
        return tj_get_active_tracks(ctx, nil, 0)
    }

    // MARK: - Callback Handlers

    private func handleCrop(_ crop: tj_crop_t) {
        let byteCount = Int(crop.bytes_per_row) * Int(crop.height)
        let pixelData = Data(bytes: crop.pixels, count: byteCount)

        let cropData = CropData(
            trackID: crop.track_id,
            bbox: crop.bbox,
            width: crop.width,
            height: crop.height,
            frameIndex: crop.frame_index,
            timestamp: crop.timestamp_sec,
            pixelData: pixelData
        )

        onCrop?(cropData)
    }

    private func handleDebugFrame(_ frame: tj_debug_frame_t) {
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
