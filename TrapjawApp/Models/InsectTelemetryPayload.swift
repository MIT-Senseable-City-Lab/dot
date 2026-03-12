//
//  InsectTelemetryPayload.swift
//  TrapjawApp
//
//  Full telemetry package sent when a track completes.
//  Matches InsectFilter's payload structure for server compatibility.
//

import Foundation

struct InsectTelemetryPayload: Codable {
    let type: String
    let trackId: String
    let status: String
    let resolution: StreamResolution
    let points: [TrackNode]
    let deviceId: String
    let deviceName: String
    
    init(
        trackId: String,
        status: String,
        resolution: StreamResolution,
        points: [TrackNode],
        deviceId: String,
        deviceName: String
    ) {
        self.type = "track"
        self.trackId = trackId
        self.status = status
        self.resolution = resolution
        self.points = points
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}
