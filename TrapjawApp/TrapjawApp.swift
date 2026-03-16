//
//  TrapjawApp.swift
//  TrapjawApp
//
//  Main application entry point. Sets up the SwiftUI app lifecycle
//  and initializes the trapjaw processing pipeline.
//

import SwiftUI

@main
struct TrapjawApp: App {
    @State private var processor = TrapjawProcessor()
    @StateObject private var timeWindow = TimeWindowManager()

    var body: some Scene {
        WindowGroup {
            ContentView(processor: processor, timeWindow: timeWindow)
                .task {
                    timeWindow.checkAndUpdate()
                    
                    if timeWindow.isInOperatingHours {
                        await processor.start()
                    }
                    
                    timeWindow.startMonitoring()
                }
                .onChange(of: timeWindow.isInOperatingHours) { oldValue, newValue in
                    // Only respond to actual changes, not initial values
                    guard oldValue != newValue else { return }
                    
                    Task { @MainActor in
                        if newValue && !processor.isRunning {
                            await processor.resume()
                        } else if !newValue && processor.isRunning {
                            processor.pause()
                        }
                    }
                }
        }
    }
}