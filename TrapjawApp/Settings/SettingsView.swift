//
//  SettingsView.swift
//  TrapjawApp
//
//  Settings view for configuring server connection.
//  Allows users to set server IP, port, and test connectivity.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var ipInput = ""
    @State private var portInput = ""
    @State private var useHTTPSToggle = false
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
            .navigationTitle("Server Settings")
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
            }
        }
    }
    
    private var isFormValid: Bool {
        !ipInput.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Int(portInput) ?? 0) > 0 &&
        (Int(portInput) ?? 0) <= 65535
    }
    
    private func testConnection() {
        guard validateInput() else { return }
        
        // Update settings temporarily for test
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
        
        dismiss()
    }
    
    private func resetToDefaults() {
        settings.resetToDefaults()
        ipInput = settings.serverIP
        portInput = String(settings.serverPort)
        useHTTPSToggle = settings.useHTTPS
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

struct ConnectionStatusView: View {
    @Bindable var settings = SettingsManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Current URL display
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
            
            // Connection test result
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
