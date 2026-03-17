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
        retryCount: Int = 0,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !crops.isEmpty else {
            logger.warning("No crops to upload for track \(trackId)")
            completion?(false)
            return
        }
        
        let url = "\(config.getServerURL())/upload_track"
        
        guard let serverURL = URL(string: url) else {
            logger.error("Invalid server URL")
            completion?(false)
            return
        }
        
        pendingUploads += 1
        NotificationCenter.default.post(name: .uploadPendingChanged, object: nil)
        
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
            let filename = String(format: "frame_%06d.jpg", index)
            
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
                        self.uploadCrops(trackId: trackId, crops: crops, retryCount: retryCount + 1, completion: completion)
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
                        self.uploadCrops(trackId: trackId, crops: crops, retryCount: retryCount + 1, completion: completion)
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
                        self.uploadCrops(trackId: trackId, crops: crops, retryCount: retryCount + 1, completion: completion)
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
}
