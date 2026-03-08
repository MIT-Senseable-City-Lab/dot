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

    var body: some Scene {
        WindowGroup {
            ContentView(processor: processor)
        }
    }
}
