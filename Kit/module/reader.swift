//
//  reader.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 10/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

// Readers that may block (disk I/O, process enumeration) share one serial utility queue.
private let blockingQueue = DispatchQueue(label: "com.aravhawk.lite-stats.reader", qos: .utility)

public protocol Reader_p: AnyObject {
    var popup: Bool { get }

    func start()
    func stop()
    func terminate()
    func refresh()
    func setInterval(_ value: Int)
}

// A reader is driven from the main thread: the scheduler ticks on the main queue, `read()` runs inline (one wakeup
// per tick for the whole app), and `callback` delivers to the handler on the main thread. Readers that may block set
// `blocking` and have `read()` run on a background queue instead.
open class Reader<T>: NSObject, Reader_p {
    public private(set) lazy var log: NextLog = NextLog.shared.copy(category: "\(type(of: self))")
    public private(set) var value: T?

    public var defaultInterval: Int = 3
    public var popup: Bool = false
    public var blocking: Bool = false

    public var callbackHandler: (T?) -> Void

    private let module: ModuleType
    private var interval: Int?
    private var repeatTask: Repeater?
    public private(set) var active: Bool = false
    private var inFlight: Bool = false

    public init(_ module: ModuleType, popup: Bool = false, callback: @escaping (T?) -> Void = {_ in }) {
        self.popup = popup
        self.module = module
        self.callbackHandler = callback

        super.init()
        self.setup()
    }

    public func callback(_ value: T?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.callback(value) }
            return
        }
        self.value = value
        if let value {
            self.callbackHandler(value)
        }
    }

    open func read() {}
    open func setup() {}
    open func terminate() {}

    open func start() {
        guard !self.active else { return }
        self.active = true

        if self.repeatTask == nil {
            let interval = self.interval ?? Store.shared.int(key: "\(self.module.stringValue)_updateInterval", defaultValue: self.defaultInterval)
            self.interval = interval
            self.repeatTask = Repeater(seconds: interval) { [weak self] in
                self?.refresh()
            }
        }

        self.refresh()
        self.repeatTask?.start()
    }

    open func stop() {
        self.repeatTask?.pause()
        self.active = false
    }

    public func setInterval(_ value: Int) {
        self.interval = value
        self.repeatTask?.reset(seconds: value)
        if self.active {
            self.refresh()
        }
    }

    public func refresh() {
        guard self.blocking else {
            self.read()
            return
        }
        guard !self.inFlight else { return }
        self.inFlight = true
        blockingQueue.async {
            self.read()
            DispatchQueue.main.async { self.inFlight = false }
        }
    }
}
