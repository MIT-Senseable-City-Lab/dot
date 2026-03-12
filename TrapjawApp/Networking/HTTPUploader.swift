//
//  HTTPUploader.swift
//  TrapjawApp
//
//  Multipart HTTP uploader for crop images.
//  Uploads JPEG frames to the Pi server.
//

import Foundation
import UIKit
import os.log

private let logger = Logger(subsystem: "com.trapjaw.upload", category: "HTTPUploader")

final class HTTPUploader {
    
    static let shared = HTTPUploader()
    
    private let config = NetworkConfig.shared
    
    private init() {}
    
    func uploadCrops(
        trackId: String,
        crops: [Data],
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
        
        let task = URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
            if let error = error {
                logger.error("Crop upload failed: \(error.localizedDescription)")
                completion?(false)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type")
                completion?(false)
                return
            }
            
            if httpResponse.statusCode == 200 {
                logger.info("Successfully uploaded \(crops.count) crops for track \(trackId.prefix(8))...")
                completion?(true)
            } else {
                logger.error("Upload failed with status \(httpResponse.statusCode)")
                completion?(false)
            }
        }
        task.resume()
    }
}
