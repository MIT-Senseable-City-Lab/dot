//
//  ContentView.swift
//  TrapjawApp
//
//  Root view showing live performance metrics from the trapjaw pipeline
//  and a minimal camera preview. Designed as a heads-up dashboard for
//  field deployment.
//

import SwiftUI

struct ContentView: View {
    @Bindable var processor: TrapjawProcessor
    @State private var showSettings = false
    @ObservedObject var timeWindow: TimeWindowManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Status bar
                statusBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer()

                // Metrics dashboard
                metricsGrid
                    .padding(.horizontal, 16)

                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            Text(processor.state.rawValue)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            // Operating hours indicator
            if !timeWindow.isInOperatingHours {
                Text("PAUSED")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.trailing, 8)
            }

            // Cool-down indicator
            if processor.isCoolingDown {
                Text("COOLING DOWN")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(.trailing, 8)
            }

            // Connection status
            HStack(spacing: 4) {
                Circle()
                    .fill(processor.isConnected ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(processor.isConnected ? "CONNECTED" : "OFFLINE")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(processor.isConnected ? .green : .red)
            }

            if processor.metrics.isWarmingUp && processor.isRunning {
                Text("BG MODEL WARMUP")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.leading, 8)
            }
            
            // Settings button
            Button(action: { showSettings = true }) {
                Image(systemName: "gear")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.leading, 8)
        }
    }

    private var statusColor: Color {
        switch processor.state {
        case .idle: .gray
        case .configuring, .stopping: .yellow
        case .warmingUp: .orange
        case .processing: .green
        case .failed: .red
        case .paused: .orange
        case .waiting: .yellow
        case .coolingDown: .cyan
        }
    }

    // MARK: - Metrics Grid

    private var metricsGrid: some View {
        let metrics = processor.metrics

        return VStack(spacing: 12) {
            Text("SCL DOT")
                .font(.system(.title, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
                .padding(.bottom, 8)

            // Frame rates
            HStack(spacing: 24) {
                metricTile(label: "CAM FPS", value: String(format: "%.1f", metrics.cameraFPS))
                metricTile(label: "PROC FPS", value: String(format: "%.1f", metrics.processingFPS))
            }

            // Pipeline timing
            HStack(spacing: 24) {
                metricTile(label: "AVG MS", value: String(format: "%.2f", metrics.avgPipelineMs))
                metricTile(label: "GPU MS", value: String(format: "%.2f", metrics.avgGpuMs))
            }

            // Detection stats
            HStack(spacing: 24) {
                metricTile(label: "TRACKS", value: "\(metrics.activeTrackCount)")
                metricTile(label: "CROPS", value: "\(metrics.totalCrops)")
            }

            // Network stats
            HStack(spacing: 24) {
                metricTile(label: "PENDING", value: "\(processor.pendingUploads)")
                metricTile(label: "BUFFERED", value: "\(TrackBuffer.shared.getTotalBufferedCropCount())")
            }

            // Error display
            if let error = processor.error {
                Text(error.localizedDescription)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.gray.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private func metricTile(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
