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

private enum RepeaterState {
    case paused
    case running
}

private final class WeakRepeater {
    weak var value: Repeater?

    init(_ value: Repeater) {
        self.value = value
    }
}

private final class RepeaterScheduler {
    static let shared = RepeaterScheduler()

    private let queue = DispatchQueue(label: "com.aravhawk.lite-stats.RepeaterScheduler", qos: .utility)
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var repeaters: [Int: [ObjectIdentifier: WeakRepeater]] = [:]

    func add(_ repeater: Repeater, seconds: Int) {
        self.queue.async {
            let interval = max(seconds, 1)
            self.repeaters[interval, default: [:]][ObjectIdentifier(repeater)] = WeakRepeater(repeater)
            self.ensureTimer(for: interval)
        }
    }

    func remove(_ repeater: Repeater, seconds: Int) {
        self.queue.async {
            self.removeLocked(ObjectIdentifier(repeater), seconds: max(seconds, 1))
        }
    }

    private func ensureTimer(for interval: Int) {
        guard self.timers[interval] == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(
            deadline: .now() + .seconds(interval),
            repeating: .seconds(interval),
            leeway: .milliseconds(min(max(interval * 250, 100), 1000))
        )
        timer.setEventHandler { [weak self] in
            self?.fire(interval)
        }
        self.timers[interval] = timer
        timer.resume()
    }

    private func fire(_ interval: Int) {
        guard var entries = self.repeaters[interval], !entries.isEmpty else {
            self.cancelTimer(for: interval)
            return
        }

        for (id, entry) in entries {
            guard let repeater = entry.value else {
                entries.removeValue(forKey: id)
                continue
            }
            repeater.fire()
        }

        if entries.isEmpty {
            self.repeaters[interval] = nil
            self.cancelTimer(for: interval)
        } else {
            self.repeaters[interval] = entries
        }
    }

    private func removeLocked(_ id: ObjectIdentifier, seconds: Int) {
        guard var entries = self.repeaters[seconds] else { return }
        entries.removeValue(forKey: id)

        if entries.isEmpty {
            self.repeaters[seconds] = nil
            self.cancelTimer(for: seconds)
        } else {
            self.repeaters[seconds] = entries
        }
    }

    private func cancelTimer(for interval: Int) {
        self.timers[interval]?.cancel()
        self.timers[interval] = nil
    }
}

internal class Repeater {
    private var callback: (() -> Void)
    private var state: RepeaterState = .paused
    private var seconds: Int
    
    internal init(seconds: Int, callback: @escaping (() -> Void)) {
        self.callback = callback
        self.seconds = max(seconds, 1)
    }
    
    deinit {
        self.pause()
    }
    
    internal func start() {
        guard self.state == .paused else { return }
        
        self.state = .running
        RepeaterScheduler.shared.add(self, seconds: self.seconds)
    }
    
    internal func pause() {
        guard self.state == .running else { return }
        
        RepeaterScheduler.shared.remove(self, seconds: self.seconds)
        self.state = .paused
    }
    
    internal func reset(seconds: Int, restart: Bool = false) {
        if self.state == .running {
            self.pause()
        }
        
        self.seconds = max(seconds, 1)
        
        if restart {
            self.fire()
            self.start()
        }
    }

    fileprivate func fire() {
        self.callback()
    }
}
