//
//  Repeater.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 27/06/2022.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2022 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

// All repeaters live on the main queue. Repeaters with the same interval share one timer, and every timer is
// phase-aligned to a common origin, so commensurate intervals (e.g. 3s and 15s) tick on the same wakeup.
private enum Scheduler {
    private static let origin = DispatchTime.now().uptimeNanoseconds
    private static var timers: [Int: DispatchSourceTimer] = [:]
    private static var callbacks: [Int: [ObjectIdentifier: () -> Void]] = [:]

    static func add(_ id: ObjectIdentifier, seconds: Int, _ callback: @escaping () -> Void) {
        self.callbacks[seconds, default: [:]][id] = callback
        guard self.timers[seconds] == nil else { return }

        let origin = self.origin
        let period = UInt64(seconds) * NSEC_PER_SEC
        let next = origin + ((DispatchTime.now().uptimeNanoseconds - origin) / period + 1) * period

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: DispatchTime(uptimeNanoseconds: next),
            repeating: .seconds(seconds),
            leeway: .milliseconds(min(seconds * 250, 1000))
        )
        timer.setEventHandler {
            self.callbacks[seconds]?.values.forEach { $0() }
        }
        self.timers[seconds] = timer
        timer.resume()
    }

    static func remove(_ id: ObjectIdentifier, seconds: Int) {
        self.callbacks[seconds]?[id] = nil
        guard self.callbacks[seconds]?.isEmpty ?? true else { return }
        self.callbacks[seconds] = nil
        self.timers.removeValue(forKey: seconds)?.cancel()
    }
}

// settings can be imported from a file, so intervals are kept in a sane range
private func boundedInterval(_ seconds: Int) -> Int {
    min(max(seconds, 1), 3600)
}

internal final class Repeater {
    private let callback: () -> Void
    private var seconds: Int
    private var running: Bool = false

    internal init(seconds: Int, callback: @escaping () -> Void) {
        self.callback = callback
        self.seconds = boundedInterval(seconds)
    }

    deinit {
        self.pause()
    }

    internal func start() {
        guard !self.running else { return }
        self.running = true
        Scheduler.add(ObjectIdentifier(self), seconds: self.seconds) { [unowned self] in self.callback() }
    }

    internal func pause() {
        guard self.running else { return }
        self.running = false
        Scheduler.remove(ObjectIdentifier(self), seconds: self.seconds)
    }

    internal func reset(seconds: Int) {
        let running = self.running
        self.pause()
        self.seconds = boundedInterval(seconds)
        if running {
            self.start()
        }
    }
}
