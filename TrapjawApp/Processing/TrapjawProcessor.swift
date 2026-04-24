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
    private(set) var isRunning = false
    private(set) var isStarting = false
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
    private var bridge: TrapjawBridge?
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
    
    // MARK: - JPEG Conversion Queue
    
    private let jpegQueue = DispatchQueue(label: "com.trapjaw.jpeg", qos: .utility, attributes: .concurrent)

    // MARK: - Init

init(config: tj_config_t? = nil) {
        self.metalDevice = MTLCreateSystemDefaultDevice()

        // Use C's defaults entirely - avoid Swift/C struct ABI issues
        // The C defaults are already tuned for this use case
        var cfg = config ?? tj_config_defaults()
        
        // Enable debug callback for UI metrics (GPU ms, active tracks)
        cfg.debug_enabled = true
        
        procLog.info("Config initialized with C defaults, debug_enabled=true")
        
        self.config = cfg
        
        // Initialize 4K frame buffer (10 frames ~330MB) - reduced for memory efficiency
        self.fourKBuffer = FourKFrameBuffer(maxFrames: 10)
        
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
        // Reduce 4K buffer from 10 to 5 frames on memory warning
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
        guard !isRunning && !isStarting else { return }
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

            bridge.onDebugFrame = { [weak self] (pipelineMs, activeTracks, frameIdx) in
                guard let self else { return }
                // Debug logging every 30 frames
                if frameIdx % 30 == 0 {
                    print("[DEBUG_FRAME] idx=\(frameIdx), activeTracks=\(activeTracks), pipelineMs=\(pipelineMs)")
                }
                DispatchQueue.main.async {
                    // Update combined GPU time: downscale + trapjaw pipeline
                    let downscaleMs = self.timing.downscale.lastMs
                    self.metrics.updateGpuTime(downscaleMs: downscaleMs, trapjawPipelineMs: pipelineMs)
                    self.metrics.updateActiveTrackCount(activeTracks)
                }
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

        } catch {
            procLog.error("TrapjawBridge init FAILED: \(error.localizedDescription)")
            self.error = error
            state = .failed
        }
        
        isStarting = false
    }

    func stop() {
        guard isRunning else { return }

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
        guard isRunning && !isStarting else { return }
        
        backgroundCaptureManager?.stop()
        videoClipManager?.stop()
        state = .stopping
        
        // Stop camera first to stop new frames
        cameraManager.stop()
        
        // Upload any remaining tracks before pausing
        flushRemainingTracks()
        
        // Stop networking
        dataStreamer.stop()
        
        // Flush and release pipeline
        bridge?.flush()
        bridge = nil
        
        // Clear 4K buffer
        fourKBuffer?.clear()
        
        isRunning = false
        state = .paused
    }
    
    func resume() async {
        guard !isRunning && !isStarting else { return }
        await start()
    }
    
    private func flushRemainingTracks() {
        guard let bridge else { return }
        
        let activeIds = bridge.getActiveTrackIds()
        let resolution = StreamResolution(
            width: Int(CameraManager.captureWidth),
            height: Int(CameraManager.captureHeight)
        )
        
        let finalizedTracks = trackBuffer.finalizeTerminatedTracks(
            activeTrackIds: activeIds,
            resolution: resolution
        )
        
        for track in finalizedTracks {
            uploadTrack(track)
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
        
        jpegQueue.async { [weak self] in
            guard let self else { return }
            
            // Get 4K frame from buffer - drop crop if frame not available
            guard let pixelBuffer4K = self.fourKBuffer?.get(frameIndex: frameIndex) else {
                // Frame was evicted from buffer, drop this crop
                self.cropsDroppedMissingFrame += 1
                if self.totalCropsReceived % 20 == 1 {
                    print("[CROP-DIAG] ❌ Frame \(frameIndex) NOT FOUND in buffer (dropped)")
                }
                return
            }
            
            // Verify we got the right frame
            if self.totalCropsReceived % 20 == 1 {
                print("[CROP-DIAG] ✅ Frame \(frameIndex) retrieved successfully")
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
        
        // Convert to JPEG with maximum quality (no compression artifacts)
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 1.0)
    }
    
    // MARK: - Track Upload
    
    private func uploadTrack(_ track: FinalizedTrack) {
        let hexId = String(format: "%08x", track.stitchedId)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HHmmss"
        let timeStr = dateFormatter.string(from: Date())
        let trackIdString = "\(hexId)_\(timeStr)"
        
        let firstFrameIndex = track.startIndex
        let points = track.crops.map { crop -> TrackNode in
            TrackNode(
                timestamp: Date().addingTimeInterval(Double(crop.frameIndex - UInt64(firstFrameIndex)) / 30.0),
                x: crop.bbox.origin.x,
                y: crop.bbox.origin.y,
                width: crop.bbox.size.width,
                height: crop.bbox.size.height,
                frameIndex: Int(crop.frameIndex)
            )
        }
        
        let payload = InsectTelemetryPayload(
            trackId: trackIdString,
            status: "completed",
            resolution: track.resolution,
            points: points,
            deviceId: networkConfig.deviceId,
            deviceName: networkConfig.deviceName
        )
        
        dataStreamer.sendTrackTelemetry(payload)
        
        let jpegDataArray = track.crops.map { $0.jpegData }
        httpUploader.uploadCrops(trackId: trackIdString, crops: jpegDataArray, startIndex: track.startIndex)
        
        // Signal track completion so receiver can create done.txt
        httpUploader.uploadDone(trackId: trackIdString)
    }

    private func updateStats(warmupCount: UInt64) {
        guard let bridge else { return }
        let stats = bridge.getStats()
        
        if warmupCount <= 5 || warmupCount % 300 == 0 {
            let warmupFrames = config.bg_warmup_frames
            procLog.info("updateStats: warmup=\(warmupCount)/\(warmupFrames) frames=\(stats.frames_processed) tracks=\(stats.total_tracks_created) crops=\(stats.total_crops_emitted) avg_ms=\(String(format: "%.2f", stats.avg_pipeline_time_ms))")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let warmupFrames = self.config.bg_warmup_frames
            self.metrics.updateFromStats(stats)
            
            self.metrics.updateWarmupStatus(
                framesProcessed: warmupCount,
                warmupFrames: self.config.bg_warmup_frames
            )

            if warmupCount >= UInt64(self.config.bg_warmup_frames) && self.state == .warmingUp {
                procLog.info("STATE: Transitioning warmingUp → processing (warmup=\(warmupCount))")
                self.state = .processing
            }
        }
    }
    
    private func checkTerminatedTracks() {
        guard let bridge else { return }
        
        let activeIds = bridge.getActiveTrackIds()
        
        if !activeIds.isEmpty && activeIds.count != lastTerminationTrackCount {
            procLog.info("checkTerminatedTracks: activeIds count=\(activeIds.count)")
            lastTerminationTrackCount = activeIds.count
        }
        let resolution = StreamResolution(
            width: Int(CameraManager.captureWidth),
            height: Int(CameraManager.captureHeight)
        )
        
        let finalizedTracks = trackBuffer.finalizeTerminatedTracks(
            activeTrackIds: activeIds,
            resolution: resolution
        )
        
        for track in finalizedTracks {
            uploadTrack(track)
        }
    }
}

// MARK: - CameraManagerDelegate

extension TrapjawProcessor: CameraManagerDelegate {
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        guard let _ = bridge, isRunning else { return }
        
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
        
        // Stage: Buffer storage
        let t0 = CFAbsoluteTimeGetCurrent()
        fourKBuffer?.add(pixelBuffer: pixelBuffer4K, frameIndex: currentIndex)
        let t1 = CFAbsoluteTimeGetCurrent()
        timing.record(stage: &timing.bufferStore, durationMs: (t1 - t0) * 1000)
        
        // Async downscale 4K → 1080p
        let t2 = CFAbsoluteTimeGetCurrent()
        downscaler?.downscale(inputBuffer: pixelBuffer4K, quality: .average) { [weak self] pixelBuffer1080p in
            guard let self = self else { return }
            
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
            
            if result == TJ_OK || result == TJ_ERROR_NOT_READY {
                DispatchQueue.main.async { [weak self] in
                    self?.metrics.recordProcessedFrame()
                }
                if result == TJ_ERROR_NOT_READY && self.warmupFramesProcessed < 5 {
                    procLog.info("Frame \(currentIndex): TJ_ERROR_NOT_READY (warmup)")
                }
            } else if let r = result, r != TJ_OK {
                procLog.error("Frame \(currentIndex): tj_process_frame returned \(r.rawValue)")
            }
            
            // End frame timing
            let _ = self.timing.endFrame()
            
            // Log timing summary every 60 frames
            self.timing.logSummaryIfNeeded(frameIndex: currentIndex, bufferDepth: self.fourKBuffer?.currentCount ?? 0)

            if currentIndex % self.statsUpdateInterval == 0 {
                self.updateStats(warmupCount: self.warmupFramesProcessed)
            }
            
            if currentIndex % self.terminationCheckInterval == 0 {
                self.checkTerminatedTracks()
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
