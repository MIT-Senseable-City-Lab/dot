//
//  HTTPUploader.swift
//  TrapjawApp
//
//  Multipart HTTP uploader for crop images.
//  Uploads JPEG frames to the Pi server with retry logic.
//

import Foundation
import UIKit
import os.log

extension Notification.Name {
    static let uploadPendingChanged = Notification.Name("uploadPendingChanged")
    static let uploadErrorOccurred = Notification.Name("uploadErrorOccurred")
}

private let logger = Logger(subsystem: "com.trapjaw.upload", category: "HTTPUploader")

final class HTTPUploader {
    
    static let shared = HTTPUploader()
    
    private let config = NetworkConfig.shared
    private let maxRetries = 1
    private let baseDelay: TimeInterval = 1.0
    
    private let counterQueue = DispatchQueue(label: "com.trapjaw.uploadcounters")
    private var _pendingUploads: Int = 0
    private var _uploadErrors: Int = 0
    
    private(set) var pendingUploads: Int {
        get { counterQueue.sync { _pendingUploads } }
        set { counterQueue.sync { _pendingUploads = newValue } }
    }
    
    private(set) var uploadErrors: Int {
        get { counterQueue.sync { _uploadErrors } }
        set { counterQueue.sync { _uploadErrors = newValue } }
    }
    
    private init() {}
    
    func uploadCrops(
        trackId: String,
        crops: [Data],
        startIndex: Int = 0,
        retryCount: Int = 0,
        isRetry: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !crops.isEmpty else {
            logger.warning("No crops to upload for track \(trackId)")
            completion?(false)
            return
        }
        
        let url = "\(config.getServerURL())/upload_crops"
        
        guard let serverURL = URL(string: url) else {
            logger.error("Invalid server URL")
            completion?(false)
            return
        }
        
        // Only increment pending on initial upload, not retries
        if !isRetry {
            pendingUploads += 1
            NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
        }
        
        logger.info("Uploading \(crops.count) crops for track \(trackId.prefix(8))...")
        
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(config.deviceId, forHTTPHeaderField: "X-Device-ID")
        request.setValue(config.deviceName, forHTTPHeaderField: "X-Device-Name")
        request.setValue(config.dotDirectoryName, forHTTPHeaderField: "X-DOT-Directory")
        request.setValue(trackId, forHTTPHeaderField: "X-Track-ID")
        
        var body = Data()
        
        for (index, jpegData) in crops.enumerated() {
            let filename = String(format: "frame_%06d.jpg", startIndex + index)
            
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(jpegData)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        let task = URLSession.shared.uploadTask(with: request, from: body) { [weak self] data, response, error in
            guard let self else { return }
            
            if let error = error {
                logger.error("Crop upload failed (attempt \(retryCount + 1)): \(error.localizedDescription)")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    logger.info("Retrying in \(delay)s...")
                    
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadCrops(trackId: trackId, crops: crops, startIndex: startIndex, retryCount: retryCount + 1, isRetry: true, completion: completion)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
                completion?(false)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadCrops(trackId: trackId, crops: crops, startIndex: startIndex, retryCount: retryCount + 1, isRetry: true, completion: completion)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
                completion?(false)
                return
            }
            
            if httpResponse.statusCode == 200 {
                logger.info("Successfully uploaded \(crops.count) crops for track \(trackId.prefix(8))...")
                self.pendingUploads -= 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                completion?(true)
            } else {
                logger.error("Upload failed with status \(httpResponse.statusCode)")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadCrops(trackId: trackId, crops: crops, startIndex: startIndex, retryCount: retryCount + 1, isRetry: true, completion: completion)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
                completion?(false)
            }
        }
        task.resume()
    }
    
    func resetErrorCount() {
        uploadErrors = 0
    }
    
    func uploadDone(
        trackId: String,
        retryCount: Int = 0,
        isRetry: Bool = false
    ) {
        let url = "\(config.getServerURL())/upload_done"
        
        guard let requestURL = URL(string: url) else {
            logger.error("Invalid server URL for done marker")
            return
        }
        
        if !isRetry {
            pendingUploads += 1
            NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
        }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue(config.deviceId, forHTTPHeaderField: "X-Device-ID")
        request.setValue(config.deviceName, forHTTPHeaderField: "X-Device-Name")
        request.setValue(trackId, forHTTPHeaderField: "X-Track-ID")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            
            if let error = error {
                logger.error("Done marker failed (attempt \(retryCount + 1)): \(error.localizedDescription)")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    logger.info("Retrying done marker in \(delay)s...")
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadDone(trackId: trackId, retryCount: retryCount + 1, isRetry: true)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type for done marker")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadDone(trackId: trackId, retryCount: retryCount + 1, isRetry: true)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
                return
            }
            
            if httpResponse.statusCode == 200 {
                logger.info("Done marker sent: \(trackId)")
                self.pendingUploads -= 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
            } else {
                logger.error("Done marker failed with status \(httpResponse.statusCode)")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadDone(trackId: trackId, retryCount: retryCount + 1, isRetry: true)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
            }
        }
        task.resume()
    }
    
    func uploadBackground(
        imageData: Data,
        retryCount: Int = 0,
        isRetry: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        let url = "\(config.getServerURL())/upload_background"
        
        guard let serverURL = URL(string: url) else {
            logger.error("Invalid server URL for background upload")
            completion?(false)
            return
        }
        
        if !isRetry {
            pendingUploads += 1
            NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
        }
        
        logger.info("Uploading background image (\(imageData.count / 1024) KB)...")
        
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(config.deviceId, forHTTPHeaderField: "X-Device-ID")
        request.setValue(config.deviceName, forHTTPHeaderField: "X-Device-Name")
        
        var body = Data()
        
        // Add image file
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "HHmmss"
        let filename = "\(timestampFormatter.string(from: Date()))_background.jpg"
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        let task = URLSession.shared.uploadTask(with: request, from: body) { [weak self] data, response, error in
            guard let self else { return }
            
            if let error = error {
                logger.error("Background upload failed (attempt \(retryCount + 1)): \(error.localizedDescription)")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    logger.info("Retrying background upload in \(delay)s...")
                    
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadBackground(imageData: imageData, retryCount: retryCount + 1, isRetry: true, completion: completion)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
                completion?(false)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type for background upload")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadBackground(imageData: imageData, retryCount: retryCount + 1, isRetry: true, completion: completion)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
                completion?(false)
                return
            }
            
            if httpResponse.statusCode == 200 {
                logger.info("Background image uploaded successfully")
                self.pendingUploads -= 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                completion?(true)
            } else {
                logger.error("Background upload failed with status \(httpResponse.statusCode)")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadBackground(imageData: imageData, retryCount: retryCount + 1, isRetry: true, completion: completion)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
                completion?(false)
            }
        }
        task.resume()
    }
    
    func uploadVideo(
        videoData: Data,
        filename: String,
        timestamp: String,
        retryCount: Int = 0,
        isRetry: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        let url = "\(config.getServerURL())/upload_video"
        
        guard let serverURL = URL(string: url) else {
            logger.error("Invalid server URL for video upload")
            completion?(false)
            return
        }
        
        if !isRetry {
            pendingUploads += 1
            NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
        }
        
        let sizeMB = Double(videoData.count) / (1024.0 * 1024.0)
        logger.info("Uploading video \(filename) (\(String(format: "%.1f", sizeMB)) MB)...")
        
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120.0
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(config.deviceId, forHTTPHeaderField: "X-Device-ID")
        request.setValue(config.deviceName, forHTTPHeaderField: "X-Device-Name")
        request.setValue(timestamp, forHTTPHeaderField: "X-Video-Timestamp")
        
        var body = Data()
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"video\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(videoData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        let task = URLSession.shared.uploadTask(with: request, from: body) { [weak self] data, response, error in
            guard let self else { return }
            
            if let error = error {
                logger.error("Video upload failed (attempt \(retryCount + 1)): \(error.localizedDescription)")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    logger.info("Retrying video upload in \(delay)s...")
                    
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadVideo(videoData: videoData, filename: filename, timestamp: timestamp, retryCount: retryCount + 1, isRetry: true, completion: completion)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
                completion?(false)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type for video upload")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadVideo(videoData: videoData, filename: filename, timestamp: timestamp, retryCount: retryCount + 1, isRetry: true, completion: completion)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
                completion?(false)
                return
            }
            
            if httpResponse.statusCode == 200 {
                logger.info("Video uploaded successfully: \(filename)")
                self.pendingUploads -= 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                completion?(true)
            } else {
                logger.error("Video upload failed with status \(httpResponse.statusCode)")
                
                if retryCount < self.maxRetries {
                    let delay = self.baseDelay * pow(2.0, Double(retryCount))
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.uploadVideo(videoData: videoData, filename: filename, timestamp: timestamp, retryCount: retryCount + 1, isRetry: true, completion: completion)
                    }
                    return
                }
                
                self.pendingUploads -= 1
                self.uploadErrors += 1
                NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
                NotificationCenter.default.post(name: .uploadErrorOccurred, object: nil)
                completion?(false)
            }
        }
        task.resume()
    }
}
