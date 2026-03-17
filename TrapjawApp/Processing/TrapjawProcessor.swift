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

    enum ProcessorState: String {
        case idle = "Idle"
        case configuring = "Configuring..."
        case warmingUp = "Warming Up"
        case processing = "Processing"
        case stopping = "Stopping..."
        case failed = "Failed"
        case paused = "Paused"
        case waiting = "Waiting..."
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
    private var startTime: CFAbsoluteTime = 0
    private let config: tj_config_t
    private let statsUpdateInterval: UInt64 = 30
    private let terminationCheckInterval: UInt64 = 60
    
    // MARK: - Networking
    
    private let dataStreamer = DataStreamer.shared
    private let httpUploader = HTTPUploader.shared
    private let trackBuffer = TrackBuffer.shared
    private let networkConfig = NetworkConfig.shared
    
    // MARK: - Timing & Diagnostics
    
    private let timing = TimingMetrics()
    private let timingLogInterval: UInt64 = 60
    
    // MARK: - JPEG Conversion Queue
    
    private let jpegQueue = DispatchQueue(label: "com.trapjaw.jpeg", qos: .utility, attributes: .concurrent)

    // MARK: - Init

    init(config: tj_config_t? = nil) {
        self.metalDevice = MTLCreateSystemDefaultDevice()

        var cfg = config ?? tj_config_defaults()
        cfg.frame_width = 1920
        cfg.frame_height = 1080
        cfg.fps = 30.0
        cfg.camera_fov_degrees = 67.0
        cfg.debug_enabled = true
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
        if Thread.isMainThread {
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            DispatchQueue.main.sync {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
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
                    self.metrics.updateActiveTrackCount(activeTracks)
                }
            }

            try await cameraManager.configure()
            cameraManager.delegate = self

            cameraManager.start()
            dataStreamer.start()
            isRunning = true
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            state = .warmingUp

        } catch {
            self.error = error
            state = .failed
        }
        
        isStarting = false
    }

    func stop() {
        guard isRunning else { return }

        state = .stopping
        dataStreamer.stop()
        cameraManager.stop()
        bridge?.flush()
        
        flushRemainingTracks()
        
        bridge = nil
        fourKBuffer?.clear()
        isRunning = false
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        state = .idle
    }
    
    // MARK: - Pause/Resume for Operating Hours
    
    func pause() {
        guard isRunning && !isStarting else { return }
        
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
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
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
            width: Int(config.frame_width),
            height: Int(config.frame_height)
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

    private func handleCrop(_ crop: CropData) {
        guard let bridge else { return }
        
        let stitchedId = bridge.getStitchedId(rawTrackId: crop.trackID)
        trackBuffer.setStitchedId(rawTrackId: crop.trackID, stitchedId: stitchedId)
        
        let trackId = crop.trackID
        let frameIndex = crop.frameIndex
        let timestamp = crop.timestamp
        
        // Scale bbox from1080p to 4K
        let bbox1080p = crop.bbox
        let bbox4K = CGRect(
            x: bbox1080p.origin.x * cropScaleFactor,
            y: bbox1080p.origin.y * cropScaleFactor,
            width: bbox1080p.size.width * cropScaleFactor,
            height: bbox1080p.size.height * cropScaleFactor
        )
        
        jpegQueue.async { [weak self] in
            guard let self else { return }
            
            // Get 4K frame from buffer - drop crop if frame not available
            guard let pixelBuffer4K = self.fourKBuffer?.get(frameIndex: frameIndex) else {
                // Frame was evicted from buffer, drop this crop
                return
            }
            
            // Extract crop from4K frame
            guard let croppedData = self.extractCropFrom4K(
                pixelBuffer: pixelBuffer4K,
                bbox: bbox4K
            ) else {
                // Failed to extract crop, drop
                return
            }
            
            let cropWidth = UInt32(bbox4K.width)
            let cropHeight = UInt32(bbox4K.height)
            
            guard let jpegData = self.convertToJPEG(
                croppedData,
                width: cropWidth,
                height: cropHeight
            ) else {
                return
            }
            
            // Resolution is 4K
            let resolution = StreamResolution(
                width: Int(CameraManager.captureWidth),
                height: Int(CameraManager.captureHeight)
            )
            
            if let trackToUpload = self.trackBuffer.addCrop(
                trackId: trackId,
                bbox: bbox1080p,  // Keep 1080p bbox for telemetry consistency
                frameIndex: frameIndex,
                timestamp: timestamp,
                jpegData: jpegData,
                resolution: resolution
            ) {
                self.uploadTrack(trackToUpload)
            }
        }
    }
    
    /// Extract a cropped region from a 4K CVPixelBuffer.
    private func extractCropFrom4K(pixelBuffer: CVPixelBuffer, bbox: CGRect) -> Data? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Clamp bbox to valid bounds
        let clampedX = max(0, Int(bbox.origin.x))
        let clampedY = max(0, Int(bbox.origin.y))
        let clampedW = min(Int(bbox.size.width), width - clampedX)
        let clampedH = min(Int(bbox.size.height), height - clampedY)
        
        guard clampedW > 0 && clampedH > 0 else { return nil }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        
        // Allocate cropped buffer
        let croppedBytesPerRow = clampedW * 4  // BGRA = 4 bytes per pixel
        let croppedData = UnsafeMutablePointer<UInt8>.allocate(capacity: croppedBytesPerRow * clampedH)
        defer { croppedData.deallocate() }
        
        // Copy cropped region row by row
        for y in 0..<clampedH {
            let srcOffset = (clampedY + y) * bytesPerRow + clampedX * 4
            let dstOffset = y * croppedBytesPerRow
            memcpy(
                croppedData + dstOffset,
                baseAddress!.assumingMemoryBound(to: UInt8.self) + srcOffset,
                croppedBytesPerRow
            )
        }
        
        return Data(bytes: croppedData, count: croppedBytesPerRow * clampedH)
    }
    
    private func convertToJPEG(_ pixelData: Data, width: UInt32, height: UInt32) -> Data? {
        let cgImage = createCGImage(from: pixelData, width: width, height: height)
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.7)
    }
    
    private func createCGImage(from pixelData: Data, width: UInt32, height: UInt32) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = Int(width) * bytesPerPixel
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        
        let context = CGContext(
            data: UnsafeMutablePointer(mutating: (pixelData as NSData).bytes.bindMemory(to: UInt8.self, capacity: pixelData.count)),
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        
        return context.makeImage()!
    }
    
    // MARK: - Track Upload
    
    private func uploadTrack(_ track: FinalizedTrack) {
        let trackIdString = String(track.stitchedId)
        
        let points = track.crops.map { crop -> TrackNode in
            TrackNode(
                timestamp: Date(timeIntervalSince1970: crop.timestamp),
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
    }

    private func updateStats(warmupCount: UInt64) {
        guard let bridge else { return }
        let stats = bridge.getStats()
        
        print("[STATS] warmupCount=\(warmupCount), threshold=\(config.bg_warmup_frames), state=\(state.rawValue)")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metrics.updateFromStats(stats)
            
            self.metrics.updateWarmupStatus(
                framesProcessed: warmupCount,
                warmupFrames: self.config.bg_warmup_frames
            )

            if warmupCount >= UInt64(self.config.bg_warmup_frames) && self.state == .warmingUp {
                print("[STATE] Transitioning: \(self.state.rawValue) → processing")
                self.state = .processing
            }
        }
    }
    
    private func checkTerminatedTracks() {
        guard let bridge else { return }
        
        let activeIds = bridge.getActiveTrackIds()
        let resolution = StreamResolution(
            width: Int(config.frame_width),
            height: Int(config.frame_height)
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
