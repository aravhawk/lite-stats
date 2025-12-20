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

internal class Repeater {
    private var callback: (() -> Void)
    private var state: RepeaterState = .paused
    
    private var timer: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.aravhawk.lite-stats.Repeater", qos: .default))
    
    internal init(seconds: Int, callback: @escaping (() -> Void)) {
        self.callback = callback
        self.setupTimer(seconds)
    }
    
    deinit {
        if self.state == .paused {
            self.timer.resume()
        }
        self.timer.cancel()
    }
    
    private func setupTimer(_ interval: Int) {
        let deadline = DispatchTime.now() + .seconds(interval)
        let leeway = DispatchTimeInterval.milliseconds(100)
        self.timer.schedule(
            deadline: deadline,
            repeating: .seconds(interval),
            leeway: leeway
        )
        self.timer.setEventHandler { [weak self] in
            self?.callback()
        }
    }
    
    internal func start() {
        guard self.state == .paused else { return }
        
        self.timer.resume()
        self.state = .running
    }
    
    internal func pause() {
        guard self.state == .running else { return }
        
        self.timer.suspend()
        self.state = .paused
    }
    
    internal func reset(seconds: Int, restart: Bool = false) {
        if self.state == .running {
            self.pause()
        }
        
        self.setupTimer(seconds)
        
        if restart {
            self.callback()
            self.start()
        }
    }
}
