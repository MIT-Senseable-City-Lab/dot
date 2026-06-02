//
//  CameraManager.swift
//  TrapjawApp
//
//  Manages AVCaptureSession lifecycle: configures the camera input,
//  video data output, and delivers CMSampleBuffers to a delegate.
//

import AVFoundation
import UIKit

protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer)
    func cameraManager(_ manager: CameraManager, didFailWithError error: Error)
}

final class CameraManager: NSObject {

    weak var delegate: CameraManagerDelegate?
    weak var videoClipManager: VideoClipManager?

    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "com.trapjaw.camera-output", qos: .userInitiated)
    private var isConfigured = false

    // MARK: - Active Device (gets device from running session, not stored reference)
    private var activeDevice: AVCaptureDevice? {
        guard let input = session.inputs.first as? AVCaptureDeviceInput else { return nil }
        return input.device
    }

    // Exposure monitoring
    private let minExposureDuration = CMTime(value: 1, timescale: 1000)  // 1/1000s minimum
    private let minLockDuration: TimeInterval = 5.0  // Minimum time to stay locked (5 seconds)
    private let exposureCheckInterval: TimeInterval = 0.1  // 100ms
    private let exposureTransitionDebounce: TimeInterval = 2.0  // 2000ms (2 second) debounce
    private let isoLockThreshold: Float = 400.0  // Only lock when auto ISO is above this (dark scenes)
    private var exposureMonitorTimer: Timer?
    private var lastExposureModeChange: Date = Date.distantPast
    private(set) var isInMinExposureMode = false
    private var exposureCheckCount: Int = 0
    
    /// Whether the exposure is currently locked to minimum duration (1/1000s).
    var isExposureLocked: Bool { isInMinExposureMode }

    /// The preview layer for displaying the camera feed.
    var previewLayer: AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    /// Whether the capture session is currently running.
    var isRunning: Bool { session.isRunning }
    
    /// The capture resolution (4Kfor this implementation).
    static let captureWidth: Int = 3840
    static let captureHeight: Int = 2160

    // MARK: - Configuration

    /// Request camera authorization and configure the capture session.
    func configure() async throws {
        guard !isConfigured else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                throw CameraError.permissionDenied
            }
        default:
            throw CameraError.permissionDenied
        }

        try configureSession()
        isConfigured = true
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Remove existing inputs/outputs if session was previously configured
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        session.sessionPreset = .hd4K3840x2160

        // Camera input — prefer wide-angle back camera
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw CameraError.noCameraAvailable
        }

        // Lock and configure camera settings for consistent detection
        do {
            try device.lockForConfiguration()
            
            // Frame rate: 30fps for consistent pipeline timing
            let targetFPS = CMTimeMake(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = targetFPS
            device.activeVideoMaxFrameDuration = targetFPS
            
            // Disable HDR for consistent exposure (with capability check)
            if device.automaticallyAdjustsVideoHDREnabled {
                device.automaticallyAdjustsVideoHDREnabled = false
            }

            // Use continuous auto exposure with minimum shutter speed monitoring
            // This allows auto exposure to adapt to brightness, but ensures shutter never goes below 1/1000s
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            // Use continuous autofocus to adapt to scene distance
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            
            // Set white balance to continuous auto (adapts to outdoor lighting)
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            device.unlockForConfiguration()
        } catch {
            // If camera configuration fails, log and continue with default settings
            print("Camera configuration warning: \(error.localizedDescription)")
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        // Video data output — BGRA8 to match trapjaw's preferred format
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)

        guard session.canAddOutput(output) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(output)
    }

    // MARK: - Session Control

func start() {
        guard isConfigured, !session.isRunning else { return }
        outputQueue.async { [weak self] in
            self?.session.startRunning()
            self?.startExposureMonitoring()
        }
    }

    func stop() {
        guard session.isRunning else { return }
        outputQueue.async { [weak self] in
            self?.stopExposureMonitoring()
            self?.session.stopRunning()
        }
    }

    // MARK: - Exposure Monitoring

    private func startExposureMonitoring() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("[EXPOSURE] Monitoring started (interval: \(self.exposureCheckInterval * 1000)ms)")
            self.exposureMonitorTimer = Timer.scheduledTimer(
                withTimeInterval: self.exposureCheckInterval,
                repeats: true
            ) { [weak self] _ in
                self?.checkAndAdjustExposure()
            }
        }
    }

    private func stopExposureMonitoring() {
        DispatchQueue.main.async { [weak self] in
            self?.exposureMonitorTimer?.invalidate()
            self?.exposureMonitorTimer = nil
            print("[EXPOSURE] Monitoring stopped")
        }
    }

    private func checkAndAdjustExposure() {
        guard let device = activeDevice else {
            // Log once every 60 checks if no device
            exposureCheckCount += 1
            if exposureCheckCount % 60 == 0 {
                print("[EXPOSURE] No active device found")
            }
            return
        }

        // Run on the same queue as camera configuration for thread safety
        outputQueue.async { [weak self] in
            guard let self = self else { return }
            self.performExposureCheck(device: device)
        }
    }

    private func performExposureCheck(device: AVCaptureDevice) {
        // Log every 30 checks (3 seconds) to show current state
        exposureCheckCount += 1
        let shouldLogState = exposureCheckCount % 30 == 0

        // Debug: Log device capabilities on first few checks
        if exposureCheckCount <= 3 {
            let minISO = device.activeFormat.minISO
            let maxISO = device.activeFormat.maxISO
            let minDuration = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
            let maxDuration = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
            print("[EXPOSURE] DEBUG: ISO range: \(minISO) - \(maxISO)")
            print("[EXPOSURE] DEBUG: Duration range: 1/\(Int(1/minDuration))s - 1/\(Int(1/maxDuration))s")
            print("[EXPOSURE] DEBUG: Current mode: \(device.exposureMode.rawValue)")
        }

        let now = Date()
        let timeSinceLastChange = now.timeIntervalSince(lastExposureModeChange)

        guard timeSinceLastChange >= exposureTransitionDebounce else { return }

        let currentDuration = device.exposureDuration
        let currentDurationSec = CMTimeGetSeconds(currentDuration)
        let minDurationSec = CMTimeGetSeconds(minExposureDuration)

        let shutterSpeed = currentDurationSec > 0 ? Int(1.0 / currentDurationSec) : 0

        // iOS ISO is already in standard range (32-1600+), no division needed
        // Only use raw value if within valid range
        let currentISO = device.iso

        // Validate ISO is within reasonable range for iPhone camera
        // If invalid (outside 20-2000), show debug info
        let isISOValid = currentISO >= 20 && currentISO <= 2000

        let offset = device.exposureTargetOffset

        if shouldLogState {
            let minISO = device.activeFormat.minISO
            let maxISO = device.activeFormat.maxISO
            let isoDisplay: String

            if isISOValid {
                isoDisplay = String(format: "%.1f", currentISO)
                print("[EXPOSURE] State: 1/\(shutterSpeed)s, ISO \(isoDisplay), offset=\(String(format: "%+.2f", offset)) (range: \(Int(minISO))-\(Int(maxISO)))")
            } else {
                // Show debug when ISO is outside expected range
                isoDisplay = String(format: "%.2f", currentISO)
                print("[EXPOSURE] State: 1/\(shutterSpeed)s, ISO=\(isoDisplay), offset=\(String(format: "%+.2f", offset)) (UNUSUAL - range: \(Int(minISO))-\(Int(maxISO)))")
            }
        }

        // Hysteresis: Lock when auto shutter is slower than 1/1000s AND ISO is high enough.
        // This prevents pointless locks in bright scenes where auto is already fine (ISO < 400).
        // Release is handled externally (luminance-based) via requestReleaseToAutoExposure().
        let shouldBeInMinMode = (currentDurationSec > minDurationSec) && (currentISO > isoLockThreshold)

        let isoStr = isISOValid ? String(format: "%.1f", currentISO) : String(format: "%.2f", currentISO)

        if shouldBeInMinMode && !isInMinExposureMode {
            lockToMinExposure(device: device)
            lastExposureModeChange = now
            isInMinExposureMode = true
            print("[EXPOSURE] >>> LOCKED: shutter=1/\(shutterSpeed)s, ISO=\(isoStr), offset=\(String(format: "%+.2f", offset))")
        } else if isInMinExposureMode {
            // Still locked - show lock duration for diagnostics
            if shouldLogState {
                let timeSinceLock = now.timeIntervalSince(lastExposureModeChange)
                let lockDurationMsg = timeSinceLock >= minLockDuration ? "duration OK" : "waiting \(Int(minLockDuration - timeSinceLock))s more"
                print("[EXPOSURE] STAY LOCKED: offset=\(String(format: "%+.2f", offset)) (\(lockDurationMsg))")
            }
        }
    }

    private func lockToMinExposure(device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.custom) else { return }

        // Sample current auto exposure before changing mode
        let currentDuration = device.exposureDuration
        let currentISO = device.iso
        let currentDurationSec = CMTimeGetSeconds(currentDuration)
        let minDurationSec = CMTimeGetSeconds(minExposureDuration)

        // Compute equivalent ISO for the same exposure at 1/1000s
        // EV is preserved: ISO_new = ISO_auto * (duration_auto / duration_min)
        let equivalentISO = currentISO * Float(currentDurationSec / minDurationSec)

        // Clamp to valid device range
        let minISO = device.activeFormat.minISO
        let maxISO = device.activeFormat.maxISO
        let clampedISO = max(minISO, min(maxISO, equivalentISO))

        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(
                duration: minExposureDuration,
                iso: clampedISO,
                completionHandler: nil
            )
            print("[EXPOSURE] Locked: shutter=1/1000s, ISO=\(Int(clampedISO)) (equivalent from \(Int(currentISO))@1/\(Int(1.0 / currentDurationSec))s, range: \(Int(minISO))-\(Int(maxISO)))")
            device.unlockForConfiguration()
        } catch {
            print("[EXPOSURE] Failed to lock exposure: \(error.localizedDescription)")
        }
    }

    private func releaseToAutoExposure(device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.continuousAutoExposure) else { return }
        do {
            try device.lockForConfiguration()
            device.exposureMode = .continuousAutoExposure
            device.unlockForConfiguration()
        } catch {
            print("[EXPOSURE] Failed to release exposure: \(error.localizedDescription)")
        }
    }

    /// Request release from locked exposure back to auto-exposure.
    /// Called externally (e.g. by TrapjawProcessor when sustained high luminance is detected).
    /// Enforces minLockDuration guard internally.
    func requestReleaseToAutoExposure() {
        outputQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isInMinExposureMode else { return }

            let timeSinceLock = Date().timeIntervalSince(self.lastExposureModeChange)
            guard timeSinceLock >= self.minLockDuration else {
                print("[EXPOSURE] Release request ignored: minimum lock duration not yet passed (\(Int(timeSinceLock))s / \(Int(self.minLockDuration))s)")
                return
            }

            guard let device = self.activeDevice else { return }
            self.releaseToAutoExposure(device: device)
            self.lastExposureModeChange = Date()
            self.isInMinExposureMode = false
            print("[EXPOSURE] <<< RELEASED (luminance-based): releasing to auto after \(Int(timeSinceLock))s locked")
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if videoClipManager?.isRecording == true {
            videoClipManager?.appendSampleBuffer(sampleBuffer)
        }
        delegate?.cameraManager(self, didOutput: sampleBuffer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Frame dropped — could log or increment a counter here
    }
}

// MARK: - Errors

enum CameraError: LocalizedError {
    case permissionDenied
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Camera access was denied. Enable it in Settings > Privacy > Camera."
        case .noCameraAvailable:
            return "No wide-angle back camera found on this device."
        case .cannotAddInput:
            return "Failed to add camera input to capture session."
        case .cannotAddOutput:
            return "Failed to add video output to capture session."
        }
    }
}
