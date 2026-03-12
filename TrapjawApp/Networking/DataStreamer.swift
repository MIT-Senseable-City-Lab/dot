//
//  DataStreamer.swift
//  TrapjawApp
//
//  HTTP client for heartbeat and track telemetry.
//  Sends device status and track data to the Pi server.
//

import Foundation
import UIKit
import os.log

extension Notification.Name {
    static let trackSent = Notification.Name("trackSent")
    static let connectionStatusChanged = Notification.Name("connectionStatusChanged")
}

private let logger = Logger(subsystem: "com.trapjaw.streaming", category: "DataStreamer")

final class DataStreamer: NSObject {
    
    static let shared = DataStreamer()
    
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 10.0
    
    private(set) var isConnected: Bool = false
    private(set) var tracksSentThisSession: Int = 0
    private(set) var lastSentTime: Date?
    
    private let config = NetworkConfig.shared
    
    private override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
    }
    
    func start() {
        startHeartbeat()
    }
    
    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        isConnected = false
    }
    
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        
        DispatchQueue.main.async { [weak self] in
            self?.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: self?.heartbeatInterval ?? 10.0, repeats: true) { [weak self] _ in
                self?.sendHeartbeat()
            }
            self?.heartbeatTimer?.fire()
        }
    }
    
    private func sendHeartbeat() {
        let url = "\(config.getServerURL())/api/heartbeat"
        
        guard let requestURL = URL(string: url) else { return }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.deviceId, forHTTPHeaderField: "X-Device-ID")
        request.setValue(config.deviceName, forHTTPHeaderField: "X-Device-Name")
        
        let payload = buildStatusPayload()
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            logger.error("Failed to encode heartbeat: \(error.localizedDescription)")
            return
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                logger.error("Heartbeat failed: \(error.localizedDescription)")
                self?.isConnected = false
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .connectionStatusChanged, object: nil)
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                self?.isConnected = true
                logger.info("Heartbeat sent")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .connectionStatusChanged, object: nil)
                }
            } else {
                self?.isConnected = false
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .connectionStatusChanged, object: nil)
                }
            }
        }.resume()
    }
    
    func sendTrackTelemetry(_ payload: InsectTelemetryPayload) {
        let url = "\(config.getServerURL())/api/track"
        
        guard let requestURL = URL(string: url) else { return }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.deviceId, forHTTPHeaderField: "X-Device-ID")
        request.setValue(config.deviceName, forHTTPHeaderField: "X-Device-Name")
        request.setValue(payload.trackId, forHTTPHeaderField: "X-Track-ID")
        request.setValue(config.dotId, forHTTPHeaderField: "X-DOT-ID")
        request.setValue(config.dotDirectoryName, forHTTPHeaderField: "X-DOT-Directory")
        
        let encoder = JSONEncoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        formatter.timeZone = TimeZone.current
        encoder.dateEncodingStrategy = .formatted(formatter)
        
        do {
            request.httpBody = try encoder.encode(payload)
        } catch {
            logger.error("Failed to encode track: \(error.localizedDescription)")
            return
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                logger.error("Track telemetry send failed: \(error.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                logger.info("Track telemetry sent: \(payload.trackId)")
                
                DispatchQueue.main.async {
                    self?.tracksSentThisSession += 1
                    self?.lastSentTime = Date()
                    NotificationCenter.default.post(name: .trackSent, object: nil)
                }
            }
        }.resume()
    }
    
    private func buildStatusPayload() -> [String: Any] {
        let device = UIDevice.current
        
        let batteryLevel = device.batteryLevel
        let batteryState: String
        switch device.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "unplugged"
        case .unknown: batteryState = "unknown"
        @unknown default: batteryState = "unknown"
        }
        
        let thermalState: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalState = "nominal"
        case .fair: thermalState = "fair"
        case .serious: thermalState = "serious"
        case .critical: thermalState = "critical"
        @unknown default: thermalState = "unknown"
        }
        
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "foreground"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        
        return [
            "deviceId": config.deviceId,
            "deviceName": device.name,
            "appStatus": appState,
            "batteryLevel": batteryLevel >= 0 ? batteryLevel : -1,
            "batteryState": batteryState,
            "thermalState": thermalState,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }
}
