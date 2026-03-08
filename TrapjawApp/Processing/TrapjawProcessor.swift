//
//  TrapjawProcessor.swift
//  TrapjawApp
//
//  Orchestrates the full pipeline: receives camera frames from CameraManager,
//  feeds them through TrapjawBridge, collects crops, updates metrics,
//  and dispatches crops to the ServerClient.
//

import Foundation
import AVFoundation
import Metal
import CoreVideo

@Observable
final class TrapjawProcessor {

    // MARK: - Public State

    let metrics = PerformanceMetrics()
    private(set) var isRunning = false
    private(set) var error: Error?
    private(set) var state: ProcessorState = .idle

    enum ProcessorState: String {
        case idle = "Idle"
        case configuring = "Configuring..."
        case warmingUp = "Warming Up"
        case processing = "Processing"
        case stopping = "Stopping..."
        case failed = "Failed"
    }

    // MARK: - Dependencies

    let cameraManager = CameraManager()
    private var bridge: TrapjawBridge?
    private let serverClient: ServerClientProtocol
    private let metalDevice: MTLDevice?

    // MARK: - Processing State

    private var frameIndex: UInt64 = 0
    private var startTime: CFAbsoluteTime = 0
    private let config: tj_config_t
    private let statsUpdateInterval: UInt64 = 30  // Update stats every N frames

    // MARK: - Init

    init(serverClient: ServerClientProtocol = StubServerClient(), config: tj_config_t? = nil) {
        self.serverClient = serverClient
        self.metalDevice = MTLCreateSystemDefaultDevice()

        var cfg = config ?? tj_config_defaults()
        // iPhone wide camera defaults — 1920x1080 at 30fps, 67deg FOV
        // These match the CameraManager's .hd1920x1080 preset
        cfg.frame_width = 1920
        cfg.frame_height = 1080
        cfg.fps = 30.0
        cfg.camera_fov_degrees = 67.0
        cfg.debug_enabled = true  // Enable debug callback for pipeline timing
        self.config = cfg
    }

    // MARK: - Lifecycle

    /// Start the capture and processing pipeline.
    func start() async {
        guard !isRunning else { return }

        state = .configuring
        error = nil
        frameIndex = 0
        startTime = CFAbsoluteTimeGetCurrent()
        metrics.reset()

        do {
            // Initialize trapjaw
            let bridge = try TrapjawBridge(config: config, device: metalDevice)
            self.bridge = bridge

            // Wire up crop callback
            bridge.onCrop = { [weak self] crop in
                self?.handleCrop(crop)
            }

            // Wire up debug callback for pipeline timing
            bridge.onDebugFrame = { [weak self] (pipelineMs, activeTracks, frameIdx) in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.metrics.updateActiveTrackCount(activeTracks)
                }
            }

            // Configure camera
            try await cameraManager.configure()
            cameraManager.delegate = self

            // Start capture
            cameraManager.start()
            isRunning = true
            state = .warmingUp

        } catch {
            self.error = error
            state = .failed
        }
    }

    /// Stop the capture and processing pipeline.
    func stop() {
        guard isRunning else { return }

        state = .stopping
        cameraManager.stop()
        bridge?.flush()
        bridge = nil
        isRunning = false
        state = .idle
    }

    // MARK: - Private

    private func handleCrop(_ crop: CropData) {
        // Dispatch crop to server client
        Task {
            try? await serverClient.sendCrop(crop)
        }
    }

    private func updateStats() {
        guard let bridge else { return }
        let stats = bridge.getStats()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metrics.updateFromStats(stats)
            self.metrics.updateWarmupStatus(
                framesProcessed: stats.frames_processed,
                warmupFrames: self.config.bg_warmup_frames
            )

            if stats.frames_processed >= UInt64(self.config.bg_warmup_frames) && self.state == .warmingUp {
                self.state = .processing
            }
        }
    }
}

// MARK: - CameraManagerDelegate

extension TrapjawProcessor: CameraManagerDelegate {
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        guard let bridge, isRunning else { return }

        // Record camera frame delivery
        DispatchQueue.main.async { [weak self] in
            self?.metrics.recordCameraFrame()
        }

        // Extract pixel buffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Calculate timestamp relative to start
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = CMTimeGetSeconds(pts)

        let currentIndex = frameIndex
        frameIndex += 1

        // Process through trapjaw
        let result = bridge.processFrame(
            pixelBuffer: pixelBuffer,
            frameIndex: currentIndex,
            timestamp: timestamp
        )

        if result == TJ_OK || result == TJ_ERROR_NOT_READY {
            DispatchQueue.main.async { [weak self] in
                self?.metrics.recordProcessedFrame()
            }
        }

        // Periodic stats update
        if currentIndex % statsUpdateInterval == 0 {
            updateStats()
        }
    }

    func cameraManager(_ manager: CameraManager, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.error = error
            self?.state = .failed
        }
    }
}
