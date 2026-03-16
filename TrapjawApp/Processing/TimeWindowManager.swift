//
//  TimeWindowManager.swift
//  TrapjawApp
//
//  Manages operating hours window (5AM - 10PM).
//  Uses a single timer scheduled for the next boundary for power efficiency.
//

import Foundation
import Combine
import UIKit

class TimeWindowManager: ObservableObject {
    @Published var isInOperatingHours: Bool = false
    @Published var nextChangeTime: Date?
    @Published var nextChangeDescription: String = ""
    
    let startHour: Int = 5   // 5AM
    let endHour: Int = 22    // 10PM
    
    private var boundaryTimer: Timer?
    private var foregroundObserver: NSObjectProtocol?
    
    init() {
        // Re-check when app comes to foreground
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkAndUpdate()
            self?.scheduleNextBoundaryTimer()
        }
    }
    
    deinit {
        stopMonitoring()
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Public API
    
    func checkAndUpdate() {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: Date())
        
        let wasInOperatingHours = isInOperatingHours
        isInOperatingHours = (hour >= startHour && hour < endHour)
        nextChangeTime = calculateNextBoundary()
        nextChangeDescription = formatNextChange()
        
        // Notify if state changed
        if wasInOperatingHours != isInOperatingHours {
            objectWillChange.send()
        }
    }
    
    func startMonitoring() {
        checkAndUpdate()
        scheduleNextBoundaryTimer()
    }
    
    func stopMonitoring() {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
    }
    
    // MARK: - Private
    
    private func scheduleNextBoundaryTimer() {
        // Cancel existing timer
        boundaryTimer?.invalidate()
        
        guard let nextBoundary = nextChangeTime else { return }
        
        let interval = nextBoundary.timeIntervalSinceNow
        
        // Schedule single timer for the next boundary
        boundaryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.checkAndUpdate()
            self?.scheduleNextBoundaryTimer()
        }
    }
    
    private func calculateNextBoundary() -> Date {
        let calendar = Calendar.current
        let now = Date()
        
        // Calculate next start boundary (5AM)
        var startComponents = calendar.dateComponents([.year, .month, .day], from: now)
        startComponents.hour = startHour
        startComponents.minute = 0
        startComponents.second = 0
        var nextStart = calendar.date(from: startComponents)!
        if nextStart <= now {
            nextStart = calendar.date(byAdding: .day, value: 1, to: nextStart)!
        }
        
        // Calculate next end boundary (10PM)
        var endComponents = calendar.dateComponents([.year, .month, .day], from: now)
        endComponents.hour = endHour
        endComponents.minute = 0
        endComponents.second = 0
        var nextEnd = calendar.date(from: endComponents)!
        if nextEnd <= now {
            nextEnd = calendar.date(byAdding: .day, value: 1, to: nextEnd)!
        }
        
        // Return whichever is sooner
        return min(nextStart, nextEnd)
    }
    
    private func formatNextChange() -> String {
        guard let next = nextChangeTime else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: next)
    }
    
    // MARK: - Utility
    
    func timeUntilNextChange() -> String {
        guard let next = nextChangeTime else { return "" }
        
        let interval = next.timeIntervalSinceNow
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}