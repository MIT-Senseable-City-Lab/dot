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
            
            // Lock exposure duration to 1/1000 sec (freeze insect motion)
            if device.isExposureModeSupported(.custom) {
                let exposureDuration = CMTime(value: 1, timescale: 1000)
                let currentISO = AVCaptureDevice.currentISO
                let clampedISO = max(device.activeFormat.minISO, min(currentISO, device.activeFormat.maxISO))
                device.setExposureModeCustom(duration: exposureDuration, iso: clampedISO, completionHandler: nil)
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
        }
    }

    func stop() {
        guard session.isRunning else { return }
        outputQueue.async { [weak self] in
            self?.session.stopRunning()
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