//
//  TrackNode.swift
//  TrapjawApp
//
//  Single point in time for an insect's journey.
//  Matches InsectFilter's TrackNode structure for server compatibility.
//

import Foundation
import CoreGraphics

struct TrackNode: Codable {
    let timestamp: Date
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let frameIndex: Int
}
