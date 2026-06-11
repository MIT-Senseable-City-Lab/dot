//
//  TrapjawProcessor.swift
//  TrapjawApp
//
//  Orchestrates the full pipeline: receives camera frames from CameraManager,
//  feeds them through TrapjawBridge, buffers crops, detects track termination,
//  and uploads telemetry + crops to the server.
//

import Foundation
import AVFoundation
import Metal
import CoreVideo
import UIKit
import CoreImage
import os.log

private let procLog = Logger(subsystem: "com.trapjaw.processor", category: "TrapjawProcessor")

// Shared CIContext for efficient crop extraction (preserves color accuracy)
private let sharedCIContext = CIContext(options: [.cacheIntermediates: false])

    @Observable
    final class TrapjawProcessor {

    // MARK: - Public State

    let metrics = PerformanceMetrics()
    private let runningLock = OSAllocatedUnfairLock(initialState: false)
    private let startingLock = OSAllocatedUnfairLock(initialState: false)
    private let emergencyStoppedLock = OSAllocatedUnfairLock(initialState: false)
    private let shuttingDownLock = OSAllocatedUnfairLock(initialState: false)
    private(set) var isRunning: Bool {
        get { runningLock.withLock { $0 } }
        set { runningLock.withLock { $0 = newValue } }
    }
    private(set) var isStarting: Bool {
        get { startingLock.withLock { $0 } }
        set { startingLock.withLock { $0 = newValue } }
    }
    private(set) var isEmergencyStopped: Bool {
        get { emergencyStoppedLock.withLock { $0 } }
        set { emergencyStoppedLock.withLock { $0 = newValue } }
    }
    private(set) var isShuttingDown: Bool {
        get { shuttingDownLock.withLock { $0 } }
        set { shuttingDownLock.withLock { $0 = newValue } }
    }
    private(set) var error: Error?
    private(set) var state: ProcessorState = .idle
    private(set) var isConnected: Bool = false
    private(set) var tracksSent: Int = 0
    private(set) var pendingUploads: Int = 0
    private(set) var uploadErrors: Int = 0
    private(set) var isCoolingDown: Bool = false

    enum ProcessorState: String {
        case idle = "Idle"
        case configuring = "Configuring..."
        case warmingUp = "Warming Up"
        case processing = "Processing"
        case stopping = "Stopping..."
        case failed = "Failed"
        case paused = "Paused"
        case waiting = "Waiting..."
        case coolingDown = "Cooling Down"
    }

    // MARK: - Dependencies

    let cameraManager = CameraManager()
    private(set) var bridge: TrapjawBridge?
    private let metalDevice: MTLDevice?
    
    // MARK: - 4K Processing
    
    private var fourKBuffer: FourKFrameBuffer?
    private var downscaler: MetalDownscaler?
    private let processingWidth: Int = 1920
    private let processingHeight: Int = 1080
    
    // Scale factor: 4K / 1080p = 2
    private let cropScaleFactor: CGFloat = 2.0

    // MARK: - Processing State

    private var frameIndex: UInt64 = 0
    private var warmupFramesProcessed: UInt64 = 0  // Counts frames during warmup
    private var lastProcessedFrame: UInt64 = 0     // For detecting out-of-order processing
    private var lastTerminationTrackCount: Int = 0
    private var terminatingTracks: Set<UInt32> = []
    private let terminatingTracksLock = OSAllocatedUnfairLock<Void>()
    private let motionPauseLock = OSAllocatedUnfairLock<Void>()
    private var isMotionPaused: Bool = false
    private var startTime: CFAbsoluteTime = 0
    private let config: tj_config_t
    private let statsUpdateInterval: UInt64 = 30
    private let terminationCheckInterval: UInt64 = 60
    
    // MARK: - Networking
    
    private let dataStreamer = DataStreamer.shared
    private let httpUploader = HTTPUploader.shared
    private let trackBuffer = TrackBuffer.shared
    private let networkConfig = NetworkConfig.shared
    private(set) var backgroundCaptureManager: BackgroundCaptureManager?
    private(set) var videoClipManager: VideoClipManager?
    
    // MARK: - Timing & Diagnostics
    
    private let timing = TimingMetrics()
    private let timingLogInterval: UInt64 = 60
    
    // MARK: - Queues
    
    /// Serial queue for all frame processing (downscale, bridge, crop dispatch).
    /// Ensures pause() can wait for all in-flight work before destroying the bridge.
    private let processingQueue = DispatchQueue(label: "com.trapjaw.processing", qos: .userInitiated)
    
    private let jpegQueue = DispatchQueue(label: "com.trapjaw.jpeg", qos: .utility, attributes: .concurrent)
    
    // MARK: - Luminance-Based Exposure Release
    
    private var luminanceHistory: [Float] = []
    private let luminanceHistorySize = 75   // 5 seconds at 15fps
    private let luminanceReleaseThreshold: Float = 0.50
    private let luminanceLogInterval: UInt64 = 30
    
    // MARK: - Memory Guard
    
    private var memoryGuardWorkItem: DispatchWorkItem?
    private let memoryCheckInterval: TimeInterval = 5.0
    private let memoryThresholdMB: Double = 900

    // MARK: - Init

init(config: tj_config_t? = nil) {
        self.metalDevice = MTLCreateSystemDefaultDevice()

        // Use C's defaults entirely - avoid Swift/C struct ABI issues
        // The C defaults are already tuned for this use case
        var cfg = config ?? tj_config_defaults()
        
        // Enable debug callback for UI metrics (GPU ms, active tracks)
        cfg.debug_enabled = true
        
        // iOS re-extracts crops from 4K buffer using bbox+frame_index, so
        // pixel data in the callback is pure overhead. Disable it for efficiency.
        cfg.crop_callback_pixels = false
        
        procLog.info("Config initialized with C defaults, debug_enabled=true, crop_callback_pixels=false")
        
        self.config = cfg
        
        // Initialize 4K frame buffer (5 frames ~165MB)
        // At 15fps with every-frame sampling, 5 frames = 5 frames of runway
        self.fourKBuffer = FourKFrameBuffer(maxFrames: 5)
        
        // Initialize Metal downscaler for 4K→1080p
        self.downscaler = MetalDownscaler(device: metalDevice)
        
        // Observe memory pressure to reduce buffer if needed
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        // Observe cool-down state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(coolDownStateChanged),
            name: .coolDownStateChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(connectionStatusChanged),
            name: .connectionStatusChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(trackSentNotification),
            name: .trackSent,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(uploadPendingChanged),
            name: .uploadPendingChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(uploadErrorOccurred),
            name: .uploadErrorOccurred,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        // Note: Screen idle timer is now managed at app level (always disabled)
    }
    
    @objc private func connectionStatusChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = self?.dataStreamer.isConnected ?? false
        }
    }
    
    @objc private func trackSentNotification() {
        DispatchQueue.main.async { [weak self] in
            self?.tracksSent = self?.dataStreamer.tracksSentThisSession ?? 0
        }
    }
    
    @objc private func uploadPendingChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.pendingUploads = self?.httpUploader.pendingUploads ?? 0
        }
    }
    
    @objc private func uploadErrorOccurred() {
        DispatchQueue.main.async { [weak self] in
            self?.uploadErrors = self?.httpUploader.uploadErrors ?? 0
        }
    }
    
    @objc private func handleMemoryWarning() {
        // Reduce 4K buffer to 5 frames on memory warning
        fourKBuffer?.reduceCapacity(to: 5)
    }
    
    @objc private func coolDownStateChanged() {
        let coolingDown = CoolDownManager.shared.isCoolingDown
        
        DispatchQueue.main.async { [weak self] in
            self?.isCoolingDown = coolingDown
            
            if coolingDown {
                // Entering cool-down: flush pending tracks but don't stop camera
                self?.state = .coolingDown
                print("[COOL-DOWN] Processor entering cool-down state")
            } else {
                // Exiting cool-down: resume normal processing
                print("[COOL-DOWN] Processor resuming from cool-down state")
                // State will be updated by normal processing flow
            }
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning && !isStarting && !isShuttingDown else { return }
        isStarting = true

        state = .configuring
        error = nil
        frameIndex = 0
        warmupFramesProcessed = 0
        startTime = CFAbsoluteTimeGetCurrent()
        metrics.reset()
        trackBuffer.clear()
        networkConfig.startNewSession()
        fourKBuffer?.clear()

        do {
            let bridge = try TrapjawBridge(config: config, device: metalDevice)
            self.bridge = bridge
            procLog.info("TrapjawBridge created successfully")

            bridge.onCrop = { [weak self] crop in
                self?.handleCrop(crop)
            }

            bridge.onDebugFrame = { [weak self] (pipelineMs, activeTracks, frameIdx, status) in
                guard let self else { return }
                // Debug logging every 30 frames
                if frameIdx % 30 == 0 {
                    print("[DEBUG_FRAME] idx=\(frameIdx), activeTracks=\(activeTracks), pipelineMs=\(pipelineMs), status=\(status)")
                }
                DispatchQueue.main.async {
                    // Update combined GPU time: downscale + trapjaw pipeline
                    let downscaleMs = self.timing.downscale.lastMs
                    self.metrics.updateGpuTime(downscaleMs: downscaleMs, trapjawPipelineMs: pipelineMs)
                    self.metrics.updateActiveTrackCount(activeTracks)
                    // Update state from trapjaw's authoritative status (reuses .paused for motion pause)
                    if status == "PAUSED" && self.state != .paused {
                        self.state = .paused
                    } else if status == "ACTIVE" && self.state == .paused {
                        self.state = .processing
                    }
                }
            }

            bridge.onTrackTerminated = { [weak self] (trackId, confirmed, numCrops, metrics) in
                guard let self else { return }
                procLog.info("Track terminated callback: id=\(trackId) confirmed=\(confirmed) crops=\(numCrops)")
                self.terminatingTracksLock.withLock {
                    self.terminatingTracks.insert(trackId)
                }
                // Do NOT trigger checkTerminatedTracks here — crops may still be arriving.
                // The 60-frame poll will catch the termination after all crops are buffered.
            }

            try await cameraManager.configure()
            cameraManager.delegate = self

            cameraManager.start()
            dataStreamer.start()
            
            // Start background capture manager (2x daily reference images)
            if let buffer = fourKBuffer {
                backgroundCaptureManager = BackgroundCaptureManager(fourKBuffer: buffer)
                backgroundCaptureManager?.start()
            }
            
            // Start video clip manager (scheduled 1-min MP4 uploads)
            videoClipManager = VideoClipManager()
            cameraManager.videoClipManager = videoClipManager
            videoClipManager?.start()
            
            isRunning = true
            state = .warmingUp
            
            // Start memory guard using recursive asyncAfter (most reliable scheduling)
            startMemoryGuard()

        } catch {
            procLog.error("TrapjawBridge init FAILED: \(error.localizedDescription)")
            self.error = error
            state = .failed
        }
        
        isStarting = false
    }

    func stop() {
        guard isRunning else { return }
        
        memoryGuardWorkItem?.cancel()
        memoryGuardWorkItem = nil

        backgroundCaptureManager?.stop()
        videoClipManager?.stop()
        state = .stopping
        dataStreamer.stop()
        cameraManager.stop()
        bridge?.flush()
        
        flushRemainingTracks()
        
        bridge = nil
        fourKBuffer?.clear()
        isRunning = false
        state = .idle
    }
    
    // MARK: - Pause/Resume for Operating Hours
    
    func pause() {
        guard isRunning && !isStarting && !isShuttingDown else { return }
        
        // Signal shutdown so that new frame processing is rejected immediately
        isShuttingDown = true
        
        memoryGuardWorkItem?.cancel()
        memoryGuardWorkItem = nil
        
        backgroundCaptureManager?.stop()
        videoClipManager?.stop()
        state = .stopping
        
        // Stop camera first to stop new frames arriving
        cameraManager.stop()
        
        // Wait for the camera output queue to finish the current didOutput call
        // before we touch any shared state.
        cameraManager.waitForOutputQueue()
        
        // Wait for all in-flight processing (downscale, bridge, crop dispatch)
        // to finish before we destroy the bridge or touch C state.
        processingQueue.sync { }
        
        // Wait for all pending JPEG encoding to finish
        jpegQueue.sync(flags: .barrier) { }
        
        // Now it is safe to flush remaining tracks and upload them
        flushRemainingTracks()
        
        // Stop networking
        dataStreamer.stop()
        
        // Now it is safe to flush and destroy the bridge — no C callbacks are in flight.
        bridge?.flush()
        bridge = nil
        
        // Clear 4K buffer
        fourKBuffer?.clear()
        
        isRunning = false
        isShuttingDown = false
        state = .paused
    }
    
    func resume() async {
        guard !isRunning && !isStarting && !isShuttingDown else { return }
        await start()
    }
    
    // MARK: - Memory Guard
    
    private func checkMemory() {
        guard isRunning else { return }
        
        let memoryMB = timing.memoryMB
        print("[MEMORY] Check: \(Int(memoryMB))MB (threshold: \(Int(memoryThresholdMB))MB)")
        guard memoryMB > memoryThresholdMB else { return }
        
        print("[MEMORY] Guard triggered at \(Int(memoryMB))MB (threshold: \(Int(memoryThresholdMB))MB)")
        emergencyPause(duration: 5)
    }
    
    private func startMemoryGuard() {
        memoryGuardWorkItem?.cancel()
        memoryGuardWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.checkMemory()
            self.startMemoryGuard()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + memoryCheckInterval, execute: memoryGuardWorkItem!)
    }
    
    private func emergencyPause(duration: TimeInterval) {
        guard !isEmergencyStopped else { return }
        isEmergencyStopped = true
        
        print("[MEMORY] Emergency pause for \(Int(duration))s at \(Int(timing.memoryMB))MB")
        
        DispatchQueue.main.async { [weak self] in
            self?.state = .idle
        }
        
        cameraManager.stop()
        fourKBuffer?.clear()
        // Don't flush bridge — keep background model alive for fast resume
        
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.emergencyResume()
        }
    }
    
    private func emergencyResume() {
        isEmergencyStopped = false
        print("[MEMORY] Emergency resume")
        
        state = .warmingUp
        cameraManager.start()
    }
    
    private func flushRemainingTracks() {
        guard let bridge else { return }

        let allIds = bridge.getAllTrackIds()
        let resolution = StreamResolution(
            width: Int(CameraManager.captureWidth),
            height: Int(CameraManager.captureHeight)
        )

        let finalizedTracks = trackBuffer.finalizeTerminatedTracks(
            activeTrackIds: allIds,
            resolution: resolution
        )

        for track in finalizedTracks {
            // On pause/stop all flushed tracks are effectively final — app is shutting down
            uploadTrack(track, isFinalUpload: true)
            terminatingTracksLock.withLock {
                terminatingTracks.remove(track.trackId)
            }
        }
    }

    // MARK: - Crop Handling

    // Diagnostic counters for frame extraction
    private var totalCropsReceived: UInt64 = 0
    private var cropsDroppedMissingFrame: UInt64 = 0
    private var cropsDroppedExtractionFailed: UInt64 = 0
    
    private func handleCrop(_ crop: CropData) {
        guard let bridge else { return }
        
        procLog.info("handleCrop: track=\(crop.trackID) bbox=\(Int(crop.bbox.origin.x)),\(Int(crop.bbox.origin.y)) \(Int(crop.bbox.width))x\(Int(crop.bbox.height)) frame=\(crop.frameIndex)")
        
        let stitchedId = bridge.getStitchedId(rawTrackId: crop.trackID)
        trackBuffer.setStitchedId(rawTrackId: crop.trackID, stitchedId: stitchedId)
        
        let trackId = crop.trackID
        let frameIndex = crop.frameIndex
        let timestamp = crop.timestamp
        
        totalCropsReceived += 1
        
        // Scale bbox from1080p to 4K
        let bbox1080p = crop.bbox
        let bbox4K = CGRect(
            x: bbox1080p.origin.x * cropScaleFactor,
            y: bbox1080p.origin.y * cropScaleFactor,
            width: bbox1080p.size.width * cropScaleFactor,
            height: bbox1080p.size.height * cropScaleFactor
        )
        
        // Diagnostic logging every 20 crops
        if totalCropsReceived % 20 == 1 {
            let bufferDepth = fourKBuffer?.currentCount ?? 0
            print("[CROP-DIAG] Requesting frame \(frameIndex), buffer depth: \(bufferDepth), drops: missing=\(cropsDroppedMissingFrame), failed=\(cropsDroppedExtractionFailed)")
        }
        
        // Dispatch to jpegQueue — look up frame inside closure to avoid retaining pixelBuffer
        jpegQueue.async { [weak self] in
            guard let self else { return }
            
            // Look up frame when job actually runs (not when queued)
            // This prevents pixelBuffer retention in the queue
            guard let pixelBuffer4K = self.fourKBuffer?.get(frameIndex: frameIndex) else {
                self.cropsDroppedMissingFrame += 1
                return
            }
            
            // Extract crop from 4K frame and convert to JPEG (CoreImage preserves color accuracy)
            guard let jpegData = self.extractCropFrom4K(
                pixelBuffer: pixelBuffer4K,
                bbox: bbox4K
            ) else {
                // Failed to extract crop, drop
                self.cropsDroppedExtractionFailed += 1
                if self.totalCropsReceived % 20 == 1 {
                    print("[CROP-DIAG] ❌ Extraction failed for frame \(frameIndex)")
                }
                return
            }
            
            // Resolution is 4K
            let resolution = StreamResolution(
                width: Int(CameraManager.captureWidth),
                height: Int(CameraManager.captureHeight)
            )
            
            if let trackToUpload = self.trackBuffer.addCrop(
                trackId: trackId,
                bbox: bbox4K,  // Store 4K bbox for correct composite placement
                frameIndex: frameIndex,
                timestamp: timestamp,
                jpegData: jpegData,
                resolution: resolution
            ) {
                self.uploadTrack(trackToUpload)
            }
        }
    }
    
    /// Extract a cropped region from a 4K CVPixelBuffer using CoreImage for accurate color.
    /// This preserves the camera's color space metadata (fixes pink/purple color cast).
    private func extractCropFrom4K(pixelBuffer: CVPixelBuffer, bbox: CGRect) -> Data? {
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        
        // Clamp bbox to valid bounds
        let clampedX = max(0, CGFloat(bbox.origin.x))
        let clampedY = max(0, CGFloat(bbox.origin.y))
        let clampedW = min(CGFloat(bbox.size.width), CGFloat(CVPixelBufferGetWidth(pixelBuffer)) - clampedX)
        let clampedH = min(CGFloat(bbox.size.height), CGFloat(bufferHeight) - clampedY)
        
        guard clampedW > 0 && clampedH > 0 else { return nil }
        
        // Create CIImage from pixel buffer (preserves camera color space)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Flip Y coordinate (CoreImage uses bottom-left origin, UIKit uses top-left)
        let flippedY = CGFloat(bufferHeight) - clampedY - clampedH
        let cropRect = CGRect(x: clampedX, y: flippedY, width: clampedW, height: clampedH)
        
        // Crop the image
        let croppedImage = ciImage.cropped(to: cropRect)
        
        // Render to CGImage using shared context (GPU-accelerated)
        guard let cgImage = sharedCIContext.createCGImage(croppedImage, from: croppedImage.extent) else {
            return nil
        }
        
        // Convert to JPEG using ImageIO (hardware-accelerated on modern devices)
        return encodeJPEGWithImageIO(cgImage: cgImage)
    }
    
    // ImageIO-based JPEG encoder - uses hardware JPEG encoder on A12+ (iPhone XR and later)
    private func encodeJPEGWithImageIO(cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }
        
		let options: [CFString: Any] = [
			kCGImageDestinationLossyCompressionQuality: 0.85
		]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
    
    // MARK: - Track Upload

    private func uploadTrack(_ track: FinalizedTrack, isFinalUpload: Bool = false) {
        let trackIdString = track.trackIdString

        let firstFrameIndex = track.startIndex
        let points = track.crops.map { crop -> TrackNode in
            TrackNode(
                timestamp: Date().addingTimeInterval(Double(crop.frameIndex - UInt64(firstFrameIndex)) / 15.0),
                x: crop.bbox.origin.x,
                y: crop.bbox.origin.y,
                width: crop.bbox.size.width,
                height: crop.bbox.size.height,
                frameIndex: Int(crop.frameIndex)
            )
        }

        let payload = InsectTelemetryPayload(
            trackId: trackIdString,
            status: isFinalUpload ? "completed" : "active",
            resolution: track.resolution,
            points: points,
            deviceId: networkConfig.deviceId,
            deviceName: networkConfig.deviceName
        )

        dataStreamer.sendTrackTelemetry(payload)

        let jpegDataArray = track.crops.map { $0.jpegData }
        httpUploader.uploadCrops(trackId: trackIdString, crops: jpegDataArray, startIndex: track.startIndex) { [weak self] success in
            guard let self else { return }
            if success && isFinalUpload {
                self.httpUploader.uploadDone(trackId: trackIdString)
                procLog.info("uploadTrack FINAL done: \(trackIdString)")
            }
        }

        if isFinalUpload {
            procLog.info("uploadTrack FINAL started: \(trackIdString) (\(track.crops.count) crops)")
        } else {
            procLog.info("uploadTrack BATCH: \(trackIdString) (\(track.crops.count) crops, start=\(track.startIndex))")
        }
    }

    private func updateStats(warmupCount: UInt64) {
        guard let bridge else { return }
        let stats = bridge.getStats()
        
        if warmupCount <= 5 || warmupCount % 300 == 0 {
            let warmupFrames = config.gmm_history
            procLog.info("updateStats: warmup=\(warmupCount)/\(warmupFrames) frames=\(stats.frames_processed) tracks=\(stats.total_tracks_created) crops=\(stats.total_crops_emitted) avg_ms=\(String(format: "%.2f", stats.avg_pipeline_time_ms))")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let warmupFrames = self.config.gmm_history
            self.metrics.updateFromStats(stats)
            
            self.metrics.updateWarmupStatus(
                framesProcessed: warmupCount,
                warmupFrames: self.config.gmm_history
            )

            if warmupCount >= UInt64(self.config.gmm_history) && self.state == .warmingUp {
                procLog.info("STATE: Transitioning warmingUp → processing (warmup=\(warmupCount))")
                self.state = .processing
            }
        }
    }
    
    private func checkTerminatedTracks() {
        guard let bridge else { return }

        let allIds = bridge.getAllTrackIds()

        if !allIds.isEmpty && allIds.count != lastTerminationTrackCount {
            procLog.info("checkTerminatedTracks: allTrackIds count=\(allIds.count)")
            lastTerminationTrackCount = allIds.count
        }
        let resolution = StreamResolution(
            width: Int(CameraManager.captureWidth),
            height: Int(CameraManager.captureHeight)
        )

        let finalizedTracks = trackBuffer.finalizeTerminatedTracks(
            activeTrackIds: allIds,
            resolution: resolution
        )

        for track in finalizedTracks {
            let isFinal = terminatingTracksLock.withLock {
                terminatingTracks.contains(track.trackId)
            }
            uploadTrack(track, isFinalUpload: isFinal)
            terminatingTracksLock.withLock {
                terminatingTracks.remove(track.trackId)
            }
        }
    }

    // MARK: - Luminance-Based Exposure Release

    /// Fast CPU-based average luminance from a 1080p BGRA pixel buffer.
    /// Samples every 16th pixel for negligible overhead (~8k samples/frame).
    private func computeAverageLuminance(pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixelStep = 16  // Sample every 16th pixel for speed

        var totalLuminance: Float = 0
        var sampleCount: Int = 0

        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        for y in stride(from: 0, to: height, by: pixelStep) {
            let rowStart = y * bytesPerRow
            for x in stride(from: 0, to: width, by: pixelStep) {
                let pixelOffset = rowStart + (x * 4)
                let b = Float(buffer[pixelOffset])
                let g = Float(buffer[pixelOffset + 1])
                let r = Float(buffer[pixelOffset + 2])
                // BT.601 luma, normalized to 0.0-1.0
                let luma = (0.114 * b + 0.587 * g + 0.299 * r) / 255.0
                totalLuminance += luma
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return 0 }
        return totalLuminance / Float(sampleCount)
    }

    /// Compute median of a Float array.
    private func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 {
            return sorted[count / 2]
        } else {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
    }

    /// Check sustained image luminance and request exposure release if overexposed.
    private func checkLuminanceAndReleaseIfNeeded(pixelBuffer: CVPixelBuffer, frameIndex: UInt64) {
        let luminance = computeAverageLuminance(pixelBuffer: pixelBuffer)
        luminanceHistory.append(luminance)
        if luminanceHistory.count > luminanceHistorySize {
            luminanceHistory.removeFirst(luminanceHistory.count - luminanceHistorySize)
        }

        // Log every 30 frames
        if frameIndex % luminanceLogInterval == 0 {
            let medianLuma = median(of: luminanceHistory)
            print("[EXPOSURE] Luminance: current=\(String(format: "%.3f", luminance)), median=\(String(format: "%.3f", medianLuma)), locked=\(cameraManager.isExposureLocked), samples=\(luminanceHistory.count)")
        }

        // Only check release if locked and we have a full 5-second window
        guard cameraManager.isExposureLocked, luminanceHistory.count >= luminanceHistorySize else { return }

        let medianLuma = median(of: luminanceHistory)
        if medianLuma > luminanceReleaseThreshold {
            print("[EXPOSURE] <<< RELEASED (luminance-based): median=\(String(format: "%.3f", medianLuma)) > \(luminanceReleaseThreshold)")
            cameraManager.requestReleaseToAutoExposure()
            // Clear history after release to avoid immediate re-trigger with stale values
            luminanceHistory.removeAll()
        }
    }
}

// MARK: - CameraManagerDelegate

extension TrapjawProcessor: CameraManagerDelegate {
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        // Reject new frames immediately if we are shutting down or not running.
        guard let _ = bridge, isRunning, !isEmergencyStopped, !isShuttingDown else { return }
        
        // Skip processing during cool-down periods (but keep buffering frames)
        if CoolDownManager.shared.isCoolingDown {
            return
        }
        
        // Start frame timing
        timing.startFrame()
        
        DispatchQueue.main.async { [weak self] in
            self?.metrics.recordCameraFrame()
        }

        guard let pixelBuffer4K = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = CMTimeGetSeconds(pts)

        let currentIndex = frameIndex
        frameIndex += 1
        
        // Increment warmup frame counter (for warmup detection)
        warmupFramesProcessed += 1
        
        if currentIndex == 0 {
            procLog.info("First frame received: 4K=\(CVPixelBufferGetWidth(pixelBuffer4K))x\(CVPixelBufferGetHeight(pixelBuffer4K))")
        }
        
        // Debug logging every 30 frames
        if currentIndex % 30 == 0 {
            print("[FRAME] idx=\(currentIndex), warmupCount=\(warmupFramesProcessed), state=\(state.rawValue)")
        }
        
        // Dispatch all heavy work to the serial processingQueue.
        // This ensures pause() can wait for every frame to finish before destroying the bridge.
        processingQueue.async { [weak self] in
            guard let self = self, self.isRunning, !self.isShuttingDown else { return }
            
            // Stage: Buffer storage (skip during motion pause to save ~330MB)
            let t0 = CFAbsoluteTimeGetCurrent()
            let shouldBuffer = self.motionPauseLock.withLock { !self.isMotionPaused }
            if shouldBuffer {
                self.fourKBuffer?.add(pixelBuffer: pixelBuffer4K, frameIndex: currentIndex)
            } else if currentIndex % 60 == 0 {
                print("[BUFFER] Skipping 4K buffer storage during motion pause (frame \(currentIndex))")
            }
            let t1 = CFAbsoluteTimeGetCurrent()
            self.timing.record(stage: &self.timing.bufferStore, durationMs: (t1 - t0) * 1000)
            
            // Async downscale 4K → 1080p
            let t2 = CFAbsoluteTimeGetCurrent()
            self.downscaler?.downscale(inputBuffer: pixelBuffer4K, quality: .average) { [weak self] pixelBuffer1080p in
                // The downscale completion runs on a Metal callback queue.
                // Dispatch back to the serial processingQueue so all downstream work is ordered.
                self?.processingQueue.async { [weak self] in
                    guard let self = self, self.isRunning, !self.isShuttingDown else { return }
                    
                    let t3 = CFAbsoluteTimeGetCurrent()
                    self.timing.record(stage: &self.timing.downscale, durationMs: (t3 - t2) * 1000)
                    
                    guard let pixelBuffer1080p = pixelBuffer1080p else {
                        print("[ERROR] Downscale failed for frame \(currentIndex)")
                        return
                    }
                    
                    // Diagnostic: Check frame processing order
                    if currentIndex <= self.lastProcessedFrame {
                        print("[ORDER] ⚠️ OUT OF ORDER: Frame \(currentIndex) processed after frame \(self.lastProcessedFrame)")
                    } else if currentIndex > self.lastProcessedFrame + 1 {
                        let gap = currentIndex - self.lastProcessedFrame - 1
                        print("[ORDER] Gap detected: Frame \(currentIndex) after \(self.lastProcessedFrame) (missed \(gap) frames)")
                    }
                    self.lastProcessedFrame = currentIndex
                    
                    // Stage: Trapjaw processing
                    let t4 = CFAbsoluteTimeGetCurrent()
                    let result = self.bridge?.processFrame(
                        pixelBuffer: pixelBuffer1080p,
                        frameIndex: currentIndex,
                        timestamp: timestamp
                    )
                    let t5 = CFAbsoluteTimeGetCurrent()
                    self.timing.record(stage: &self.timing.trapjawProcess, durationMs: (t5 - t4) * 1000)
                    
                    if result == TJ_OK || result == TJ_ERROR_NOT_READY || result == TJ_ERROR_MOTION_PAUSE {
                        DispatchQueue.main.async { [weak self] in
                            self?.metrics.recordProcessedFrame()
                        }
                        if result == TJ_ERROR_NOT_READY && self.warmupFramesProcessed < 5 {
                            procLog.info("Frame \(currentIndex): TJ_ERROR_NOT_READY (warmup)")
                        }
                        if result == TJ_ERROR_MOTION_PAUSE {
                            self.motionPauseLock.withLock { self.isMotionPaused = true }
                            if currentIndex % 30 == 0 {
                                procLog.info("Frame \(currentIndex): TJ_ERROR_MOTION_PAUSE (global motion detected)")
                            }
                        } else {
                            self.motionPauseLock.withLock { self.isMotionPaused = false }
                        }
                    } else if let r = result, r != TJ_OK {
                        procLog.error("Frame \(currentIndex): tj_process_frame returned \(r.rawValue)")
                    }
                    
                    // Luminance-based exposure release check
                    self.checkLuminanceAndReleaseIfNeeded(pixelBuffer: pixelBuffer1080p, frameIndex: currentIndex)
                    
                    // End frame timing
                    let _ = self.timing.endFrame()
                    
                    // Log timing summary every 60 frames
                    self.timing.logSummaryIfNeeded(frameIndex: currentIndex, bufferDepth: self.fourKBuffer?.currentCount ?? 0)
                    
                    // Flush Metal texture cache every 60 frames
                    if currentIndex % 60 == 0 {
                        self.downscaler?.flushTextureCache()
                    }

                    if currentIndex % self.statsUpdateInterval == 0 {
                        self.updateStats(warmupCount: self.warmupFramesProcessed)
                    }
                    
                    if currentIndex % self.terminationCheckInterval == 0 {
                        self.checkTerminatedTracks()
                    }
                }
            }
        }
    }

    func cameraManager(_ manager: CameraManager, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.error = error
            self?.state = .failed
        }
    }
}
