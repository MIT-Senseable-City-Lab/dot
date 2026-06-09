//
//  VideoClipManager.swift
//  TrapjawApp
//
//  Schedules and records 1-minute 4K MP4 video clips for upload to the Pi server.
//  Records at configurable times (default: 8:00 AM and 2:00 PM) by encoding
//  CMSampleBuffers from the existing AVCaptureSession into an MP4 via AVAssetWriter.
//  Follows the same scheduling pattern as BackgroundCaptureManager.
//

import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.trapjaw.videoclip", category: "VideoClip")

final class VideoClipManager: ObservableObject {
    
    // MARK: - Configuration
    
    private let clipDuration: TimeInterval = 60.0
    private let captureWindowMinutes = 2
    
    // MARK: - State
    
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isUploading: Bool = false
    @Published private(set) var lastUploadDate: Date?

    /// Thread-safe recording state for camera-output queue reads.
    private let recordingLock = OSAllocatedUnfairLock(initialState: false)

    private var timer: Timer?
    private var lastCapturedKey: String?
    private var recordingStartDate: Date?
    private var recordingTimer: Timer?
    
    // AVAssetWriter state
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerStartTime: CMTime?
    private var lastPresentationTime: CMTime = .zero
    private var frameCount: Int = 0
    private var outputURL: URL?
    
    private let uploader = HTTPUploader.shared
    private let settings = SettingsManager.shared
    private let config = NetworkConfig.shared
    
    private var tempDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("video_clips", isDirectory: true)
    }
    
    // MARK: - Init
    
    init() {
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    deinit {
        stop()
    }

    // MARK: - Thread-safe recording state

    private func setRecordingState(_ value: Bool) {
        recordingLock.withLock { $0 = value }
        DispatchQueue.main.async {
            self.isRecording = value
        }
    }

    func isRecordingActive() -> Bool {
        recordingLock.withLock { $0 }
    }

    // MARK: - Public API

    /// Manually trigger a video clip recording (for UI button).
    func recordNow() {
        guard !isRecording && !isUploading else { return }
        guard settings.videoUploadEnabled else { return }
        print("[VIDEO] Manual video clip recording triggered")
        logger.info("Manual video clip recording triggered")
        startRecording()
    }
    
    func start() {
        let times = settings.videoUploadSchedules.sorted().map {
            SettingsManager.formatSchedule($0)
        }.joined(separator: ", ")
        logger.info("Video clip manager started (times: \(times))")
        print("[VIDEO] Video clip manager started (times: \(times))")
        
        timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkAndRecord()
        }
        RunLoop.main.add(timer!, forMode: .common)
        
        checkAndRecord()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        stopRecording(cancel: true)
        lastCapturedKey = nil
        logger.info("Video clip manager stopped")
    }
    
    // MARK: - Scheduling
    
    private var currentWindowKey: String {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let window = minute / captureWindowMinutes
        return "\(hour)_\(window)"
    }
    
    private var isAtScheduledTime: Bool {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let currentMinuteOfDay = hour * 60 + minute
        
        return settings.videoUploadSchedules.contains { scheduled in
            let diff = currentMinuteOfDay - scheduled
            return diff >= 0 && diff < captureWindowMinutes
        }
    }
    
    private func checkAndRecord() {
        guard settings.videoUploadEnabled else { return }
        guard !isRecording && !isUploading else { return }
        
        guard isAtScheduledTime else {
            lastCapturedKey = nil
            return
        }
        
        let windowKey = currentWindowKey
        guard lastCapturedKey != windowKey else { return }
        
        logger.info("Scheduled video clip recording at window \(windowKey)")
        print("[VIDEO] Scheduled video clip recording at window \(windowKey)")
        lastCapturedKey = windowKey
        startRecording()
    }
    
    // MARK: - Recording
    
    func startRecording() {
        guard !isRecording else { return }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        
        let filename = "\(config.dotId)_\(timestamp).mp4"
        let fileURL = tempDirectory.appendingPathComponent(filename)
        outputURL = fileURL
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: fileURL)
        
        do {
            assetWriter = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        } catch {
            logger.error("Failed to create AVAssetWriter: \(error.localizedDescription)")
            print("[VIDEO] AVAssetWriter failed: \(error.localizedDescription)")
            return
        }
        
        guard let writer = assetWriter else { return }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 3840,
            AVVideoHeightKey: 2160,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 20_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ] as [String: Any]
        ]
        
        assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        assetWriterInput?.expectsMediaDataInRealTime = true
        
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 3840,
            kCVPixelBufferHeightKey as String: 2160,
        ]
        
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: assetWriterInput!,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )
        
        writer.add(assetWriterInput!)
        
        writer.startWriting()
        writerStartTime = nil
        lastPresentationTime = .zero
        frameCount = 0

        setRecordingState(true)
        recordingStartDate = Date()
        
        logger.info("Video recording started: \(filename)")
        print("[VIDEO] Recording started: \(filename)")
        
        // Schedule stop after clipDuration
        recordingTimer = Timer.scheduledTimer(withTimeInterval: clipDuration, repeats: false) { [weak self] _ in
            self?.stopRecordingAndUpload()
        }
    }
    
    /// Append a CMSampleBuffer from the camera to the video recording.
    /// Called from CameraManager's captureOutput delegate when isRecording is true.
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecordingActive(), let writer = assetWriter, let input = assetWriterInput else { return }
        guard writer.status == .writing else { return }
        
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // Set startSessionAtTime on first buffer
        if writerStartTime == nil {
            writer.startSession(atSourceTime: presentationTime)
            writerStartTime = presentationTime
        }
        
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
            frameCount += 1
            lastPresentationTime = presentationTime
        }
    }
    
    /// Stop recording and upload the clip.
    func stopRecordingAndUpload() {
        stopRecording(cancel: false)
    }
    
    private func stopRecording(cancel: Bool) {
        guard isRecordingActive() else { return }

        setRecordingState(false)
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        guard let writer = assetWriter else { return }
        
        if cancel {
            writer.cancelWriting()
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            cleanupWriter()
            logger.info("Video recording cancelled")
            return
        }
        
        assetWriterInput?.markAsFinished()
        
        writer.finishWriting { [weak self] in
            guard let self else { return }
            
            if writer.status == .completed {
                logger.info("Video recording finished: \(self.frameCount) frames")
                print("[VIDEO] Recording finished: \(self.frameCount) frames")
                self.uploadClip()
            } else {
                logger.error("Video writer failed: \(writer.error?.localizedDescription ?? "unknown")")
                if let url = self.outputURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            
            self.cleanupWriter()
        }
    }
    
    private func cleanupWriter() {
        assetWriter = nil
        assetWriterInput = nil
        pixelBufferAdaptor = nil
        writerStartTime = nil
        frameCount = 0
        outputURL = nil
    }
    
    // MARK: - Upload
    
    private func uploadClip() {
        guard let fileURL = outputURL else { return }
        
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            logger.error("Video file not found at \(fileURL.path)")
            return
        }
        
        guard let videoData = try? Data(contentsOf: fileURL) else {
            logger.error("Failed to read video file")
            return
        }
        
        let filename = fileURL.lastPathComponent
        
        // Extract timestamp for header: "YYYYMMDD_HHmmss" -> "YYYYMMDD_HHmmss"
        let timestampWithoutExt = filename.replacingOccurrences(of: ".mp4", with: "")
        // filename is like "dot01_20260423_080000.mp4" -> send just the timestamp part
        let timestampPart: String
        if let underscoreRange = timestampWithoutExt.range(of: "_", options: .backwards) {
            timestampPart = String(timestampWithoutExt[underscoreRange.upperBound...])
        } else {
            timestampPart = timestampWithoutExt
        }
        
        let sizeMB = Double(videoData.count) / (1024.0 * 1024.0)
        logger.info("Uploading video clip: \(filename) (\(String(format: "%.1f", sizeMB)) MB)")
        print("[VIDEO] Uploading clip: \(filename) (\(String(format: "%.1f", sizeMB)) MB)")
        
        DispatchQueue.main.async { [weak self] in
            self?.isUploading = true
        }
        
        uploader.uploadVideo(videoData: videoData, filename: filename, timestamp: timestampPart) { [weak self] success in
            DispatchQueue.main.async {
                self?.isUploading = false
                
                if success {
                    self?.lastUploadDate = Date()
                    logger.info("Video clip uploaded successfully")
                    print("[VIDEO] Upload succeeded: \(filename)")
                } else {
                    logger.error("Video clip upload failed")
                    print("[VIDEO] Upload failed: \(filename)")
                }
                // Clean up temp file regardless of success or failure
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}