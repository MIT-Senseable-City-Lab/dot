//
//  AtomicBool.swift
//  TrapjawApp
//
//  Thread-safe boolean property wrapper backed by OSAllocatedUnfairLock.
//

import Foundation
import os

@propertyWrapper
struct AtomicBool {
    private let lock: OSAllocatedUnfairLock<Bool>

    init(wrappedValue: Bool) {
        lock = OSAllocatedUnfairLock(initialState: wrappedValue)
    }

    var wrappedValue: Bool {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
