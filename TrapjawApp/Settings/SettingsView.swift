//
//  SettingsView.swift
//  TrapjawApp
//
//  Settings view for configuring server connection.
//  Allows users to set server IP, port, background capture times, and test connectivity.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var ipInput = ""
    @State private var portInput = ""
    @State private var useHTTPSToggle = false
    @State private var bgCaptureEnabled = true
    @State private var videoUploadEnabled = true
    @State private var wifiSSIDInput = ""
    @State private var wifiPasswordInput = ""
    @State private var showValidationError = false
    @State private var validationMessage = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server Configuration")) {
                    HStack {
                        Text("Protocol")
                        Spacer()
                        Picker("Protocol", selection: $useHTTPSToggle) {
                            Text("HTTP").tag(false)
                            Text("HTTPS").tag(true)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 150)
                    }
                    
                    HStack {
                        Text("Server IP/Host")
                        Spacer()
                        TextField("192.168.1.150", text: $ipInput)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("5001", text: $portInput)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                }
                
                Section(header: Text("Connection Status")) {
                    ConnectionStatusView()
                }
                
                Section(header: Text("WiFi"), footer: Text("WiFi credentials for the Pi's network, stored locally for reference.")) {
                    HStack {
                        Text("Network Name")
                        Spacer()
                        TextField("WiFi SSID", text: $wifiSSIDInput)
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack {
                        Text("Password")
                        Spacer()
                        SecureField("Password", text: $wifiPasswordInput)
                            .multilineTextAlignment(.trailing)
                    }
                }
                
                Section(header: Text("Background Capture"), footer: Text("Reference photos sent to the Pi at scheduled times. Must be within operating hours (5AM\u{2013}10PM).")) {
                    Toggle("Enabled", isOn: $bgCaptureEnabled)
                    
                    if bgCaptureEnabled {
                        NavigationLink(destination: CaptureScheduleView()) {
                            HStack {
                                Text("Capture Times")
                                Spacer()
                                Text(captureSchedulesSummary)
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                
                Section(header: Text("Video Upload"), footer: Text("Upload 1-minute 4K video clips to the Pi at scheduled times. Must be within operating hours (5AM\u{2013}10PM).")) {
                    Toggle("Enabled", isOn: $videoUploadEnabled)
                    
                    if videoUploadEnabled {
                        NavigationLink(destination: VideoUploadScheduleView()) {
                            HStack {
                                Text("Upload Times")
                                Spacer()
                                Text(videoUploadSchedulesSummary)
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                
                Section {
                    Button(action: testConnection) {
                        HStack {
                            Spacer()
                            if settings.isTestingConnection {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            } else {
                                Text("Test Connection")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(settings.isTestingConnection || !isFormValid)
                }
                
                Section {
                    Button(action: saveSettings) {
                        HStack {
                            Spacer()
                            Text("Save")
                                .fontWeight(.bold)
                            Spacer()
                        }
                    }
                    .disabled(!isFormValid)
                }
                
                Section {
                    Button(action: resetToDefaults) {
                        HStack {
                            Spacer()
                            Text("Reset to Defaults")
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Validation Error", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .onAppear {
                ipInput = settings.serverIP
                portInput = String(settings.serverPort)
                useHTTPSToggle = settings.useHTTPS
                bgCaptureEnabled = settings.backgroundCaptureEnabled
                videoUploadEnabled = settings.videoUploadEnabled
                wifiSSIDInput = settings.wifiSSID
                wifiPasswordInput = settings.wifiPassword
            }
        }
    }
    
    private var isFormValid: Bool {
        !ipInput.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Int(portInput) ?? 0) > 0 &&
        (Int(portInput) ?? 0) <= 65535
    }
    
    private var captureSchedulesSummary: String {
        let schedules = settings.backgroundCaptureSchedules.sorted()
        if schedules.isEmpty { return "None" }
        return schedules.map { SettingsManager.formatSchedule($0) }.joined(separator: ", ")
    }
    
    private var videoUploadSchedulesSummary: String {
        let schedules = settings.videoUploadSchedules.sorted()
        if schedules.isEmpty { return "None" }
        return schedules.map { SettingsManager.formatSchedule($0) }.joined(separator: ", ")
    }
    
    private func testConnection() {
        guard validateInput() else { return }
        
        settings.updateServerIP(ipInput)
        settings.updateServerPort(Int(portInput) ?? 5001)
        settings.updateUseHTTPS(useHTTPSToggle)
        
        Task { @MainActor in
            _ = await settings.testConnection()
        }
    }
    
    private func saveSettings() {
        guard validateInput() else { return }
        
        settings.updateServerIP(ipInput)
        settings.updateServerPort(Int(portInput) ?? 5001)
        settings.updateUseHTTPS(useHTTPSToggle)
        settings.updateBackgroundCaptureEnabled(bgCaptureEnabled)
        settings.updateVideoUploadEnabled(videoUploadEnabled)
        settings.updateWifiSSID(wifiSSIDInput)
        settings.updateWifiPassword(wifiPasswordInput)
        
        dismiss()
    }
    
    private func resetToDefaults() {
        settings.resetToDefaults()
        ipInput = settings.serverIP
        portInput = String(settings.serverPort)
        useHTTPSToggle = settings.useHTTPS
        bgCaptureEnabled = settings.backgroundCaptureEnabled
        videoUploadEnabled = settings.videoUploadEnabled
        wifiSSIDInput = settings.wifiSSID
        wifiPasswordInput = settings.wifiPassword
    }
    
    private func validateInput() -> Bool {
        let trimmedIP = ipInput.trimmingCharacters(in: .whitespaces)
        
        if trimmedIP.isEmpty {
            validationMessage = "Please enter a server IP address or hostname"
            showValidationError = true
            return false
        }
        
        if !settings.validateServerIP(trimmedIP) {
            validationMessage = "Invalid IP address or hostname format"
            showValidationError = true
            return false
        }
        
        guard let port = Int(portInput), settings.validatePort(port) else {
            validationMessage = "Port must be between 1 and 65535"
            showValidationError = true
            return false
        }
        
        return true
    }
}

// MARK: - Capture Schedule View

struct CaptureScheduleView: View {
    @Bindable var settings = SettingsManager.shared
    @State private var selectedHour = 12
    @State private var selectedMinute = 0
    
    private let hours = Array(5...22)  // 5AM to 10PM (operating hours)
    private let minutes = stride(from: 0, to: 60, by: 5)  // 0, 5, 10, ..., 55
    
    var body: some View {
        List {
            // Add new schedule
            Section(header: Text("Add Capture Time")) {
                HStack {
                    Picker("Hour", selection: $selectedHour) {
                        ForEach(hours, id: \.self) { hour in
                            Text(hourLabel(hour)).tag(hour)
                        }
                    }
                    .pickerStyle(.wheel)
                    
                    Text(":")
                    
                    Picker("Minute", selection: $selectedMinute) {
                        ForEach(Array(minutes), id: \.self) { minute in
                            Text(String(format: "%02d", minute)).tag(minute)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 80)
                }
                
                Button(action: addSchedule) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Time")
                    }
                }
                .disabled(isAlreadyAdded)
            }
            
            // Current schedules
            Section(header: Text("Scheduled Captures")) {
                if settings.backgroundCaptureSchedules.isEmpty {
                    Text("No capture times set")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(settings.backgroundCaptureSchedules.sorted(), id: \.self) { schedule in
                        HStack {
                            Image(systemName: "calendar")
                                .foregroundColor(.blue)
                            Text(SettingsManager.formatSchedule(schedule))
                            Spacer()
                            Button(action: { removeSchedule(schedule) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Capture Times")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var isAlreadyAdded: Bool {
        let minuteOfDay = SettingsManager.toMinuteOfDay(hour: selectedHour, minute: selectedMinute)
        return settings.backgroundCaptureSchedules.contains(minuteOfDay)
    }
    
    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "12 AM" }
        if hour < 12 { return "\(hour) AM" }
        if hour == 12 { return "12 PM" }
        return "\(hour - 12) PM"
    }
    
    private func addSchedule() {
        let minuteOfDay = SettingsManager.toMinuteOfDay(hour: selectedHour, minute: selectedMinute)
        settings.addBackgroundCaptureSchedule(minuteOfDay: minuteOfDay)
    }
    
    private func removeSchedule(_ minuteOfDay: Int) {
        settings.removeBackgroundCaptureSchedule(minuteOfDay: minuteOfDay)
    }
}

// MARK: - Video Upload Schedule View

struct VideoUploadScheduleView: View {
    @Bindable var settings = SettingsManager.shared
    @State private var selectedHour = 8
    @State private var selectedMinute = 0
    
    private let hours = Array(5...22)  // 5AM to 10PM (operating hours)
    private let minutes = stride(from: 0, to: 60, by: 5)  // 0, 5, 10, ..., 55
    
    var body: some View {
        List {
            Section(header: Text("Add Upload Time")) {
                HStack {
                    Picker("Hour", selection: $selectedHour) {
                        ForEach(hours, id: \.self) { hour in
                            Text(hourLabel(hour)).tag(hour)
                        }
                    }
                    .pickerStyle(.wheel)
                    
                    Text(":")
                    
                    Picker("Minute", selection: $selectedMinute) {
                        ForEach(Array(minutes), id: \.self) { minute in
                            Text(String(format: "%02d", minute)).tag(minute)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 80)
                }
                
                Button(action: addSchedule) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Time")
                    }
                }
                .disabled(isAlreadyAdded)
            }
            
            Section(header: Text("Scheduled Uploads")) {
                if settings.videoUploadSchedules.isEmpty {
                    Text("No upload times set")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(settings.videoUploadSchedules.sorted(), id: \.self) { schedule in
                        HStack {
                            Image(systemName: "video")
                                .foregroundColor(.purple)
                            Text(SettingsManager.formatSchedule(schedule))
                            Spacer()
                            Button(action: { removeSchedule(schedule) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Video Upload Times")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var isAlreadyAdded: Bool {
        let minuteOfDay = SettingsManager.toMinuteOfDay(hour: selectedHour, minute: selectedMinute)
        return settings.videoUploadSchedules.contains(minuteOfDay)
    }
    
    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "12 AM" }
        if hour < 12 { return "\(hour) AM" }
        if hour == 12 { return "12 PM" }
        return "\(hour - 12) PM"
    }
    
    private func addSchedule() {
        let minuteOfDay = SettingsManager.toMinuteOfDay(hour: selectedHour, minute: selectedMinute)
        settings.addVideoUploadSchedule(minuteOfDay: minuteOfDay)
    }
    
    private func removeSchedule(_ minuteOfDay: Int) {
        settings.removeVideoUploadSchedule(minuteOfDay: minuteOfDay)
    }
}

// MARK: - Connection Status View

struct ConnectionStatusView: View {
    @Bindable var settings = SettingsManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Current URL:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            Text(settings.serverBaseURL)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Divider()
            
            if let result = settings.lastConnectionTestResult {
                HStack {
                    connectionStatusIcon(for: result)
                    connectionStatusText(for: result)
                    Spacer()
                }
            } else {
                HStack {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.gray)
                    Text("Not tested")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            
            if settings.isTestingConnection {
                HStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                    Text("Testing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func connectionStatusIcon(for result: SettingsManager.ConnectionTestResult) -> some View {
        switch result {
        case .success:
            return Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failure, .timeout, .invalidURL:
            return Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }
    
    private func connectionStatusText(for result: SettingsManager.ConnectionTestResult) -> some View {
        switch result {
        case .success(let latency):
            return Text("Connected (\(String(format: "%.0f", latency))ms)")
                .font(.caption)
                .foregroundColor(.green)
        case .failure(let error):
            return Text("Failed: \(error)")
                .font(.caption)
                .foregroundColor(.red)
        case .timeout:
            return Text("Connection timed out")
                .font(.caption)
                .foregroundColor(.orange)
        case .invalidURL:
            return Text("Invalid URL")
                .font(.caption)
                .foregroundColor(.red)
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}