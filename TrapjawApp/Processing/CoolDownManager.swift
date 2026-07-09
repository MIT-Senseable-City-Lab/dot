//
//  CoolDownManager.swift
//  TrapjawApp
//
//  Manages scheduled cool-down periods to prevent device overheating.
//  Pauses processing for 5 minutes every hour at :55 to allow thermal dissipation.
//

import Foundation
import Combine
import os

// MARK: - Notifications

extension Notification.Name {
    static let coolDownStateChanged = Notification.Name("coolDownStateChanged")
}

/// Manages scheduled cool-down periods to prevent device overheating.
/// - Pauses processing for 5 minutes every hour (at :55-:00)
/// - Provides observable state for UI updates
/// - Allows manual override in emergency situations
@Observable
final class CoolDownManager {
    
    // MARK: - Singleton
    
    static let shared = CoolDownManager()
    
    // MARK: - Public State
    
    /// Whether the app is currently in a cool-down period
    @ObservationIgnored private let coolingDownLock = OSAllocatedUnfairLock(initialState: false)
    private(set) var isCoolingDown: Bool {
        get { coolingDownLock.withLock { $0 } }
        set { coolingDownLock.withLock { $0 = newValue } }
    }
    
    /// Time remaining in current cool-down period (in seconds)
    private(set) var coolDownTimeRemaining: Int = 0
    
    /// Total number of cool-down periods completed since app launch
    private(set) var totalCoolDownPeriods: Int = 0
    
    /// Whether cool-down scheduling is enabled
    var isEnabled = true
    
    // MARK: - Internal State
    
    private var timer: Timer?
    private var coolDownEndTime: Date?
    private let calendar = Calendar.current
    
    // Cool-down schedule: 5 minutes before each hour (:55 to :00)
    private let coolDownStartMinute = 55
    private let coolDownDuration: TimeInterval = 5 * 60 // 5 minutes
    
    // MARK: - Init
    
    private init() {
        // Don't start monitoring here - defer to avoid RunLoop issues
        // Monitoring will start on first access via ensureMonitoringStarted
    }
    
    /// Ensures monitoring is started (called lazily)
    private func ensureMonitoringStarted() {
        guard timer == nil else { return }
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    // MARK: - Public Methods
    
    /// Start monitoring for cool-down periods
    func startMonitoring() {
        guard timer == nil else { return }
        
        // Check immediately
        checkCoolDownSchedule()
        
        // Set up timer to check every 10 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkCoolDownSchedule()
        }
        
        // Also add to RunLoop for background execution
        if let timer = timer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    /// Stop monitoring for cool-down periods
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    /// Skip the current cool-down period and resume processing immediately
    func skipCurrentCoolDown() {
        guard isCoolingDown else { return }
        
        isCoolingDown = false
        coolDownTimeRemaining = 0
        coolDownEndTime = nil
        totalCoolDownPeriods += 1 // Count as completed
        
        print("[COOL-DOWN] Manually skipped cool-down period")
    }
    
    /// Force an immediate cool-down period (for manual thermal management)
    func forceCoolDown(duration: TimeInterval = 300) {
        guard !isCoolingDown else { return }
        
        isCoolingDown = true
        coolDownEndTime = Date().addingTimeInterval(duration)
        coolDownTimeRemaining = Int(duration)
        
        print("[COOL-DOWN] Forced cool-down period started for \(Int(duration))s")
    }
    
    // MARK: - Private Methods
    
    private func checkCoolDownSchedule() {
        guard isEnabled else {
            if isCoolingDown {
                endCoolDown()
            }
            return
        }
        
        let now = Date()
        let minute = calendar.component(.minute, from: now)
        let second = calendar.component(.second, from: now)
        
        // Check if we're in the cool-down window (:55 to :00)
        let isInCoolDownWindow = minute >= coolDownStartMinute
        
        if isInCoolDownWindow && !isCoolingDown {
            // Start cool-down period
            startCoolDown()
        } else if !isInCoolDownWindow && isCoolingDown {
            // End cool-down period
            endCoolDown()
        } else if isCoolingDown {
            // Update remaining time
            updateCoolDownTimeRemaining()
        }
    }
    
    private func startCoolDown() {
        isCoolingDown = true
        coolDownEndTime = Date().addingTimeInterval(coolDownDuration)
        coolDownTimeRemaining = Int(coolDownDuration)
        
        NotificationCenter.default.post(name: .coolDownStateChanged, object: nil)
        print("[COOL-DOWN] Cool-down period started at :55, will resume at :00")
    }
    
    private func endCoolDown() {
        isCoolingDown = false
        coolDownTimeRemaining = 0
        coolDownEndTime = nil
        totalCoolDownPeriods += 1
        
        NotificationCenter.default.post(name: .coolDownStateChanged, object: nil)
        print("[COOL-DOWN] Cool-down period ended, resuming normal operation")
    }
    
    private func updateCoolDownTimeRemaining() {
        guard let endTime = coolDownEndTime else { return }
        let remaining = endTime.timeIntervalSinceNow
        coolDownTimeRemaining = max(0, Int(remaining))
    }
}

// MARK: - Convenience Extensions

extension CoolDownManager {
    /// Returns a formatted string of remaining cool-down time
    var coolDownTimeRemainingFormatted: String {
        let minutes = coolDownTimeRemaining / 60
        let seconds = coolDownTimeRemaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}