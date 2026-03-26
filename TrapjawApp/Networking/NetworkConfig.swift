//
//  NetworkConfig.swift
//  TrapjawApp
//
//  Network configuration with configurable server URL.
//  Server URL can be customized via SettingsManager.
//

import Foundation
import UIKit

final class NetworkConfig {
    static let shared = NetworkConfig()
    
    private let deviceIdKey = "NetworkConfig_DeviceId"
    private let dotIdKey = "NetworkConfig_DotId"
    private let sessionStartKey = "NetworkConfig_SessionStart"
    
    private(set) var deviceId: String
    private(set) var dotId: String
    private(set) var sessionStartTime: Date
    
    private init() {
        if let existingId = UserDefaults.standard.string(forKey: deviceIdKey) {
            self.deviceId = existingId
        } else {
            self.deviceId = UUID().uuidString
            UserDefaults.standard.set(self.deviceId, forKey: deviceIdKey)
        }
        
        if let existingDotId = UserDefaults.standard.string(forKey: dotIdKey) {
            self.dotId = existingDotId
        } else {
            let shortUUID = String(self.deviceId.prefix(8))
            self.dotId = shortUUID
            UserDefaults.standard.set(self.dotId, forKey: dotIdKey)
        }
        
        if let savedTime = UserDefaults.standard.object(forKey: sessionStartKey) as? Date {
            self.sessionStartTime = savedTime
        } else {
            self.sessionStartTime = Date()
        }
    }
    
    var deviceName: String { UIDevice.current.name }
    
    var dotDirectoryName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timeStr = formatter.string(from: sessionStartTime)
        return "\(dotId)_\(timeStr)"
    }
    
    /// Returns the configured server URL from SettingsManager
    func getServerURL() -> String {
        return SettingsManager.shared.serverBaseURL
    }
    
    /// Legacy method for compatibility - returns hardcoded default
    /// Use getServerURL() for configurable URL
    func getDefaultServerURL() -> String {
        return "http://192.168.1.150:5001"
    }
    
    func startNewSession() {
        sessionStartTime = Date()
        UserDefaults.standard.set(sessionStartTime, forKey: sessionStartKey)
    }
}
