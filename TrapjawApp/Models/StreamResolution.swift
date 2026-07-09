//
//  StreamResolution.swift
//  TrapjawApp
//
//  Resolution struct for telemetry payload.
//

import Foundation

struct StreamResolution: Codable {
    let width: Int
    let height: Int

    static var current: StreamResolution {
        StreamResolution(width: 3840, height: 2160)
    }
}
