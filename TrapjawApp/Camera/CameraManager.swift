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

        session.sessionPreset = .hd1920x1080

        // Camera input — prefer wide-angle back camera
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw CameraError.noCameraAvailable
        }

        // Lock and configure frame rate to 30fps for consistency with trapjaw defaults
        try device.lockForConfiguration()
        let targetFPS = CMTimeMake(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = targetFPS
        device.activeVideoMaxFrameDuration = targetFPS
        device.unlockForConfiguration()

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
