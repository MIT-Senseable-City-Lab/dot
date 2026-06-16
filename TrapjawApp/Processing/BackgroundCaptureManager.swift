//
//  BackgroundCaptureManager.swift
//  TrapjawApp
//
//  Schedules and uploads background reference images at configurable times.
//  Grabs the latest 4K frame from FourKFrameBuffer, JPEG-encodes it,
//  and uploads to the Pi server via HTTPUploader.
//  Times are stored as minutes since midnight in SettingsManager.
//

import Foundation
import UIKit
import CoreVideo
import os.log

private let logger = Logger(subsystem: "com.trapjaw.background", category: "BackgroundCapture")

final class BackgroundCaptureManager: ObservableObject {
    
    // MARK: - Configuration
    
    /// Maximum retry attempts when buffer is empty
    private let maxRetryAttempts = 2
    /// Delay between retries (seconds)
    private let retryDelay: TimeInterval = 30
    /// Width of the capture window in minutes (fire within N minutes of scheduled time)
    private let captureWindowMinutes = 2
    
    // MARK: - State
    
    @Published private(set) var lastCaptureDate: Date?
    @Published private(set) var isUploading: Bool = false
    
    private var timer: Timer?
    private var lastCapturedKey: String?  // "HH:MM" window key to avoid duplicates
    private let fourKBuffer: FourKFrameBuffer
    private let uploader = HTTPUploader.shared
    private let settings = SettingsManager.shared
    
    // MARK: - Init
    
    init(fourKBuffer: FourKFrameBuffer) {
        self.fourKBuffer = fourKBuffer
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Public API
    
    /// Start periodic background capture scheduling.
    /// Checks every 60 seconds if it's time to capture.
    func start() {
        let times = settings.backgroundCaptureSchedules.sorted().map {
            SettingsManager.formatSchedule($0)
        }.joined(separator: ", ")
        logger.info("Background capture started (times: \(times))")
        
        // Trigger an initial capture immediately on startup
        // This ensures a background image exists before any tracks arrive
        logger.info("Triggering initial background capture on startup")
        performCapture(retryCount: 0) { [weak self] success in
            if success {
                self?.lastCapturedKey = self?.currentWindowKey
            }
        }
        
        // Schedule periodic check every 60 seconds
        timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkAndCapture()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    
    /// Stop periodic background capture.
    func stop() {
        timer?.invalidate()
        timer = nil
        lastCapturedKey = nil
        logger.info("Background capture stopped")
    }
    
    /// Manually trigger a background capture (for testing or on-demand).
    func captureNow() {
        logger.info("Manual background capture triggered")
        performCapture(retryCount: 0) { _ in }
    }
    
    // MARK: - Scheduling
    
    /// Unique key for the current time window to prevent duplicate captures.
    /// Groups time into 2-minute windows: "14:05" → "14_2" (14th hour, 2nd window)
    private var currentWindowKey: String {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let window = minute / captureWindowMinutes
        return "\(hour)_\(window)"
    }
    
    /// Check if current time matches any scheduled capture time (within window).
    private var isAtScheduledTime: Bool {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let currentMinuteOfDay = hour * 60 + minute
        
        return settings.backgroundCaptureSchedules.contains { scheduled in
            let diff = currentMinuteOfDay - scheduled
            return diff >= 0 && diff < captureWindowMinutes
        }
    }
    
    private func checkAndCapture() {
        guard settings.backgroundCaptureEnabled else { return }
        
        guard isAtScheduledTime else {
            // Clear last captured key if we're outside all windows
            lastCapturedKey = nil
            return
        }
        
        let windowKey = currentWindowKey
        
        // Skip if we already captured in this window
        if lastCapturedKey == windowKey {
            return
        }
        
        logger.info("Scheduled background capture at window \(windowKey)")
        
        // Only set lastCapturedKey after successful upload
        performCapture(retryCount: 0) { [weak self] success in
            if success {
                self?.lastCapturedKey = windowKey
            } else {
                logger.info("Background capture failed, will retry on next timer fire")
            }
        }
    }
    
    // MARK: - Capture
    
    private func performCapture(retryCount: Int, completion: ((Bool) -> Void)? = nil) {
        // Check if background capture is still enabled
        guard settings.backgroundCaptureEnabled else {
            logger.info("Background capture disabled, skipping")
            completion?(false)
            return
        }
        
        // Get the latest 4K frame from the buffer
        let latestFrame = fourKBuffer.getLatestFrame()
        
        guard let pixelBuffer = latestFrame else {
            // Buffer is empty — retry if we haven't exceeded max attempts
            if retryCount < self.maxRetryAttempts {
                logger.info("No 4K frame available, retrying in \(Int(self.retryDelay))s (attempt \(retryCount + 1)/\(self.maxRetryAttempts))")
                DispatchQueue.global().asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                    self?.performCapture(retryCount: retryCount + 1, completion: completion)
                }
            } else {
                logger.warning("No 4K frame available after \(self.maxRetryAttempts) retries, skipping background capture")
                completion?(false)
            }
            return
        }
        
        // Convert CVPixelBuffer to JPEG
        guard let jpegData = pixelBufferToJPEG(pixelBuffer, quality: 0.9) else {
            logger.error("Failed to convert 4K frame to JPEG for background capture")
            completion?(false)
            return
        }
        
        let sizeKB = jpegData.count / 1024
        logger.info("Background image prepared: \(sizeKB) KB")
        
        // Upload in background
        isUploading = true
        uploader.uploadBackground(imageData: jpegData) { [weak self] success in
            DispatchQueue.main.async {
                self?.isUploading = false
                if success {
                    self?.lastCaptureDate = Date()
                    logger.info("Background image upload completed successfully")
                } else {
                    logger.error("Background image upload failed")
                }
                completion?(success)
            }
        }
    }
    
    /// Convert CVPixelBuffer to JPEG Data
    private func pixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer, quality: CGFloat) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: quality)
    }
}