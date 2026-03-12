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

                // Controls
                controlBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .preferredColorScheme(.dark)
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
        }
    }

    private var statusColor: Color {
        switch processor.state {
        case .idle: .gray
        case .configuring, .stopping: .yellow
        case .warmingUp: .orange
        case .processing: .green
        case .failed: .red
        }
    }

    // MARK: - Metrics Grid

    private var metricsGrid: some View {
        let metrics = processor.metrics

        return VStack(spacing: 12) {
            Text("TRAPJAW")
                .font(.system(.title, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
                .padding(.bottom, 8)

            // Frame rates
            HStack(spacing: 24) {
                metricTile(label: "CAM FPS", value: String(format: "%.1f", metrics.cameraFPS))
                metricTile(label: "PROC FPS", value: String(format: "%.1f", metrics.processingFPS))
            }

            Divider().background(.gray)

            // Pipeline timing
            HStack(spacing: 24) {
                metricTile(label: "AVG MS", value: String(format: "%.2f", metrics.avgPipelineMs))
                metricTile(label: "PEAK MS", value: String(format: "%.2f", metrics.maxPipelineMs))
            }

            HStack(spacing: 24) {
                metricTile(label: "GPU MS", value: String(format: "%.2f", metrics.avgGpuMs))
                metricTile(label: "CPU MS", value: String(format: "%.2f", metrics.avgCpuMs))
            }

            Divider().background(.gray)

            // Detection stats
            HStack(spacing: 24) {
                metricTile(label: "TRACKS", value: "\(metrics.activeTrackCount)")
                metricTile(label: "TOTAL", value: "\(metrics.totalTracks)")
            }

            HStack(spacing: 24) {
                metricTile(label: "CROPS", value: "\(metrics.totalCrops)")
                metricTile(label: "FRAMES", value: "\(metrics.totalFrames)")
            }

            // Network stats
            HStack(spacing: 24) {
                metricTile(label: "SENT", value: "\(processor.tracksSent)")
                metricTile(label: "PENDING", value: "\(processor.pendingUploads)")
            }

            HStack(spacing: 24) {
                metricTile(label: "FAILED", value: "\(processor.uploadErrors)")
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

    // MARK: - Control Bar

    private var controlBar: some View {
        Button(action: {
            if processor.isRunning {
                processor.stop()
            } else {
                Task { await processor.start() }
            }
        }) {
            Text(processor.isRunning ? "STOP" : "START")
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(processor.isRunning ? Color.red.opacity(0.8) : Color.green.opacity(0.8))
                )
        }
    }
}
