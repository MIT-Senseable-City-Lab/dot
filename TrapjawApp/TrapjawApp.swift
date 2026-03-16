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
                    } else {
                        // Outside operating hours - set to waiting state
                        // UI will show "PAUSED" based on timeWindow
                    }
                    
                    timeWindow.startMonitoring()
                }
                .onReceive(timeWindow.$isInOperatingHours) { isInHours in
                    Task { @MainActor in
                        if isInHours && !processor.isRunning {
                            await processor.resume()
                        } else if !isInHours && processor.isRunning {
                            processor.pause()
                        }
                    }
                }
        }
    }
}