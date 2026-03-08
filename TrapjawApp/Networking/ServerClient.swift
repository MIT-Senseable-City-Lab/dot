//
//  ServerClient.swift
//  TrapjawApp
//
//  Protocol and stub implementation for sending insect crop data
//  to a central ML server. Replace StubServerClient with a concrete
//  implementation (WebSocket, REST, gRPC) when the server is ready.
//

import Foundation

// MARK: - Protocol

/// Interface for sending detected insect crops to the ML server.
protocol ServerClientProtocol: Sendable {
    /// Send a crop to the server for ML classification.
    ///
    /// - Parameter crop: The detected insect crop with pixel data and metadata.
    func sendCrop(_ crop: CropData) async throws

    /// Current connection state.
    var isConnected: Bool { get }
}

// MARK: - Stub Implementation

/// Development stub that logs crop metadata without transmitting data.
/// Replace with a concrete transport implementation for production.
final class StubServerClient: ServerClientProtocol, @unchecked Sendable {

    private(set) var isConnected: Bool = false
    private var cropsReceived: UInt64 = 0
    private let logInterval: UInt64 = 50  // Log every N crops

    func sendCrop(_ crop: CropData) async throws {
        cropsReceived += 1

        if cropsReceived % logInterval == 1 {
            print("""
            [ServerClient:stub] crop #\(cropsReceived) | \
            track=\(crop.trackID) \
            size=\(crop.width)x\(crop.height) \
            frame=\(crop.frameIndex) \
            bytes=\(crop.pixelData.count)
            """)
        }
    }
}

// MARK: - Error Types

enum ServerClientError: LocalizedError {
    case notConnected
    case sendFailed(underlying: Error)
    case invalidResponse(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to ML server."
        case .sendFailed(let err):
            return "Failed to send crop to server: \(err.localizedDescription)"
        case .invalidResponse(let code):
            return "Server returned unexpected status code: \(code)"
        }
    }
}
