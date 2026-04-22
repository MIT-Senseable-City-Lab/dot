//
//  SettingsManager.swift
//  TrapjawApp
//
//  Manages configurable server settings for network connections.
//  Stores settings in UserDefaults and provides connection testing.
//

import Foundation
import Combine

@Observable
final class SettingsManager {
    
    static let shared = SettingsManager()
    
    // MARK: - Keys
    private let serverIPKey = "SettingsManager_ServerIP"
    private let serverPortKey = "SettingsManager_ServerPort"
    private let useHTTPSKey = "SettingsManager_UseHTTPS"
    private let backgroundCaptureEnabledKey = "SettingsManager_BackgroundCaptureEnabled"
    private let backgroundCaptureSchedulesKey = "SettingsManager_BackgroundCaptureSchedules"
    private let wifiSSIDKey = "SettingsManager_WifiSSID"
    private let wifiPasswordKey = "SettingsManager_WifiPassword"
    
    // MARK: - Defaults
    static let defaultCaptureSchedules: [Int] = [725, 1205]
    
    // MARK: - State
    var serverIP: String
    var serverPort: Int
    var useHTTPS: Bool
    var backgroundCaptureEnabled: Bool
    var backgroundCaptureSchedules: [Int]
    var wifiSSID: String
    var wifiPassword: String
    
    // MARK: - Connection Testing State
    var isTestingConnection = false
    var lastConnectionTestResult: ConnectionTestResult?
    
    enum ConnectionTestResult {
        case success(latencyMs: Double)
        case failure(error: String)
        case timeout
        case invalidURL
    }
    
    // MARK: - Computed Properties
    
    var serverBaseURL: String {
        let scheme = useHTTPS ? "https" : "http"
        return "\(scheme)://\(serverIP):\(serverPort)"
    }
    
    var isConfigured: Bool {
        !serverIP.isEmpty && serverPort > 0 && serverPort <= 65535
    }
    
    // MARK: - Init
    
    private init() {
        let savedIP = UserDefaults.standard.string(forKey: serverIPKey)
        let savedPort = UserDefaults.standard.integer(forKey: serverPortKey)
        let savedUseHTTPS = UserDefaults.standard.bool(forKey: useHTTPSKey)
        let savedBgEnabled = UserDefaults.standard.object(forKey: backgroundCaptureEnabledKey) as? Bool
        let savedBgSchedules = UserDefaults.standard.object(forKey: backgroundCaptureSchedulesKey) as? [Int]
        let savedWifiSSID = UserDefaults.standard.string(forKey: wifiSSIDKey)
        let savedWifiPassword = UserDefaults.standard.string(forKey: wifiPasswordKey)
        
        self.serverIP = (savedIP?.isEmpty == false) ? savedIP! : "192.168.1.150"
        self.serverPort = (savedPort > 0) ? savedPort : 5001
        self.useHTTPS = savedUseHTTPS
        self.backgroundCaptureEnabled = savedBgEnabled ?? true
        self.backgroundCaptureSchedules = savedBgSchedules ?? Self.defaultCaptureSchedules
        self.wifiSSID = savedWifiSSID ?? ""
        self.wifiPassword = savedWifiPassword ?? ""
    }
    
    // MARK: - Configuration
    
    func updateServerIP(_ ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serverIP = trimmed
        UserDefaults.standard.set(trimmed, forKey: serverIPKey)
        lastConnectionTestResult = nil
    }
    
    func updateServerPort(_ port: Int) {
        let validPort = max(1, min(65535, port))
        self.serverPort = validPort
        UserDefaults.standard.set(validPort, forKey: serverPortKey)
        lastConnectionTestResult = nil
    }
    
    func updateUseHTTPS(_ useHTTPS: Bool) {
        self.useHTTPS = useHTTPS
        UserDefaults.standard.set(useHTTPS, forKey: useHTTPSKey)
        lastConnectionTestResult = nil
    }
    
    func updateBackgroundCaptureEnabled(_ enabled: Bool) {
        self.backgroundCaptureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: backgroundCaptureEnabledKey)
    }
    
    func addBackgroundCaptureSchedule(minuteOfDay: Int) {
        let clamped = max(0, min(1439, minuteOfDay))
        if !backgroundCaptureSchedules.contains(clamped) {
            backgroundCaptureSchedules.append(clamped)
            backgroundCaptureSchedules.sort()
            UserDefaults.standard.set(backgroundCaptureSchedules, forKey: backgroundCaptureSchedulesKey)
        }
    }
    
    func removeBackgroundCaptureSchedule(minuteOfDay: Int) {
        backgroundCaptureSchedules.removeAll { $0 == minuteOfDay }
        UserDefaults.standard.set(backgroundCaptureSchedules, forKey: backgroundCaptureSchedulesKey)
    }
    
    func updateWifiSSID(_ ssid: String) {
        self.wifiSSID = ssid
        UserDefaults.standard.set(ssid, forKey: wifiSSIDKey)
    }
    
    func updateWifiPassword(_ password: String) {
        self.wifiPassword = password
        UserDefaults.standard.set(password, forKey: wifiPasswordKey)
    }
    
    /// Format a minute-of-day value as "h:mm AM/PM"
    static func formatSchedule(_ minuteOfDay: Int) -> String {
        let hours = minuteOfDay / 60
        let minutes = minuteOfDay % 60
        if hours == 0 { return String(format: "12:%02d AM", minutes) }
        if hours < 12 { return String(format: "%d:%02d AM", hours, minutes) }
        if hours == 12 { return String(format: "12:%02d PM", minutes) }
        return String(format: "%d:%02d PM", hours - 12, minutes)
    }
    
    /// Convert hour and minute to minute-of-day
    static func toMinuteOfDay(hour: Int, minute: Int) -> Int {
        return hour * 60 + minute
    }
    
    /// Convert minute-of-day to hour and minute
    static func fromMinuteOfDay(_ minuteOfDay: Int) -> (hour: Int, minute: Int) {
        return (minuteOfDay / 60, minuteOfDay % 60)
    }
    
    // MARK: - Validation
    
    func validateServerIP(_ ip: String) -> Bool {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Empty check
        if trimmed.isEmpty { return false }
        
        // IP address validation (IPv4)
        let ipParts = trimmed.split(separator: ".")
        if ipParts.count == 4 {
            for part in ipParts {
                if let num = Int(part), num >= 0 && num <= 255 {
                    continue
                }
                return false
            }
            return true
        }
        
        // Hostname validation - basic check
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let invalidCharacters = trimmed.unicodeScalars.filter { !allowedCharacters.contains($0) }
        return invalidCharacters.isEmpty && !trimmed.hasPrefix(".") && !trimmed.hasSuffix(".")
    }
    
    func validatePort(_ port: Int) -> Bool {
        return port >= 1 && port <= 65535
    }
    
    // MARK: - Connection Testing
    
    func testConnection() async -> ConnectionTestResult {
        guard isConfigured else {
            let result = ConnectionTestResult.failure(error: "Server not configured")
            await MainActor.run { lastConnectionTestResult = result }
            return result
        }
        
        // Update UI state on main thread
        await MainActor.run { isTestingConnection = true }
        
        let urlString = "\(serverBaseURL)/api/heartbeat"
        
        guard let url = URL(string: urlString) else {
            let result = ConnectionTestResult.invalidURL
            await MainActor.run {
                isTestingConnection = false
                lastConnectionTestResult = result
            }
            return result
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        
        let startTime = Date()
        
        // Perform network request
        let result = await performNetworkTest(url: url, startTime: startTime)
        
        // Update UI with results on main thread
        await MainActor.run {
            isTestingConnection = false
            lastConnectionTestResult = result
        }
        
        return result
    }
    
    private func performNetworkTest(url: URL, startTime: Date) async -> ConnectionTestResult {
        do {
            let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            
            if let httpResponse = response as? HTTPURLResponse {
                let latency = Date().timeIntervalSince(startTime) * 1000
                
                if httpResponse.statusCode == 200 {
                    return .success(latencyMs: latency)
                } else {
                    return .failure(error: "HTTP \(httpResponse.statusCode)")
                }
            } else {
                return .failure(error: "Invalid response type")
            }
        } catch URLError.timedOut {
            return .timeout
        } catch {
            return .failure(error: error.localizedDescription)
        }
    }
    // MARK: - Reset
    
    func resetToDefaults() {
        serverIP = "192.168.1.150"
        serverPort = 5001
        useHTTPS = false
        backgroundCaptureEnabled = true
        backgroundCaptureSchedules = Self.defaultCaptureSchedules
        wifiSSID = ""
        wifiPassword = ""
        
        UserDefaults.standard.set(serverIP, forKey: serverIPKey)
        UserDefaults.standard.set(serverPort, forKey: serverPortKey)
        UserDefaults.standard.set(useHTTPS, forKey: useHTTPSKey)
        UserDefaults.standard.set(backgroundCaptureEnabled, forKey: backgroundCaptureEnabledKey)
        UserDefaults.standard.set(backgroundCaptureSchedules, forKey: backgroundCaptureSchedulesKey)
        UserDefaults.standard.set(wifiSSID, forKey: wifiSSIDKey)
        UserDefaults.standard.set(wifiPassword, forKey: wifiPasswordKey)
        
        lastConnectionTestResult = nil
    }
}
