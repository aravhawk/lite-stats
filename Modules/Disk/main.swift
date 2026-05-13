//
//  main.swift
//  Disk
//
//  Created by Serhiy Mytrovtsiy on 07/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import IOKit
import Kit

public struct stats: Codable {
    var read: Int64 = 0
    var write: Int64 = 0
    
    var readBytes: Int64 = 0
    var writeBytes: Int64 = 0
}

public struct smart_t: Codable {
    var temperature: Int = 0
    var life: Int = 0
    var totalRead: Int64 = 0
    var totalWritten: Int64 = 0
    var powerCycles: Int = 0
    var powerOnHours: Int = 0
}

public struct drive: Codable {
    var parent: io_object_t = 0
    
    var uuid: String = ""
    var mediaName: String = ""
    var BSDName: String = ""
    
    var root: Bool = false
    var removable: Bool = false
    
    var model: String = ""
    var path: URL?
    var connectionType: String = ""
    var fileSystem: String = ""
    
    var size: Int64 = 1
    var free: Int64 = 0
    
    var activity: stats = stats()
    var smart: smart_t? = nil

    enum CodingKeys: String, CodingKey {
        case uuid
        case mediaName
        case BSDName
        case root
        case removable
        case model
        case path
        case connectionType
        case fileSystem
        case size
        case free
        case activity
        case smart
    }
    
    public var percentage: Double {
        let total = self.size
        let free = self.free
        var usedSpace = total - free
        if usedSpace < 0 {
            usedSpace = 0
        }
        return Double(usedSpace) / Double(total)
    }
    
    public var popupState: Bool {
        Store.shared.bool(key: "Disk_\(self.uuid)_popup", defaultValue: true)
    }
}

public class Disks: Codable {
    private var queue: DispatchQueue = DispatchQueue(label: "com.aravhawk.lite-stats.Disk.SynchronizedArray")
    private var _array: [drive] = []
    public var array: [drive] {
        get { self.queue.sync { self._array } }
        set {
            self.queue.sync {
                self._array.forEach { releaseParent($0.parent) }
                self._array = newValue
            }
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case array
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.array = try container.decode(Array<drive>.self, forKey: CodingKeys.array)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(array, forKey: .array)
    }
    
    init() {}
    
    public var count: Int {
        self.queue.sync { self._array.count }
    }
    
    // swiftlint:disable empty_count
    public var isEmpty: Bool {
        self.count == 0
    }
    // swiftlint:enable empty_count
    
    public func first(where predicate: (drive) -> Bool) -> drive? {
        self.queue.sync { self._array.first(where: predicate) }
    }
    
    public func index(where predicate: (drive) -> Bool) -> Int? {
        self.queue.sync { self._array.firstIndex(where: predicate) }
    }
    
    public func map<ElementOfResult>(_ transform: (drive) -> ElementOfResult?) -> [ElementOfResult] {
        self.queue.sync { self._array.compactMap(transform) }
    }
    
    public func reversed() -> [drive] {
        self.queue.sync { self._array.reversed() }
    }
    
    func forEach(_ body: (drive) -> Void) {
        self.queue.sync { self._array.forEach(body) }
    }
    
    public func append( _ element: drive) {
        self.queue.sync {
            if !self._array.contains(where: {$0.BSDName == element.BSDName}) {
                self._array.append(element)
            }
        }
    }
    
    public func remove(at index: Int) {
        self.queue.sync {
            let removed = self._array.remove(at: index)
            releaseParent(removed.parent)
        }
    }
    
    public func sort() {
        self.queue.sync { self._array.sort{ $1.removable } }
    }
    
    func updateFreeSize(_ idx: Int, newValue: Int64) {
        self.queue.sync { self._array[idx].free = newValue }
    }
    
    func updateReadWrite(_ idx: Int, read: Int64, write: Int64) {
        self.queue.sync {
            self._array[idx].activity.readBytes = read
            self._array[idx].activity.writeBytes = write
        }
    }
    
    func updateRead(_ idx: Int, newValue: Int64) {
        self.queue.sync { self._array[idx].activity.read = newValue }
    }
    
    func updateWrite(_ idx: Int, newValue: Int64) {
        self.queue.sync { self._array[idx].activity.write = newValue }
    }
    
    func updateSMARTData(_ idx: Int, smart: smart_t?) {
        self.queue.sync { self._array[idx].smart = smart }
    }
}

private func releaseParent(_ parent: io_object_t) {
    if parent != 0 {
        IOObjectRelease(parent)
    }
}

public struct Disk_process: Process_p, Codable {
    public var base: DataSizeBase {
        DataSizeBase(rawValue: Store.shared.string(key: "\(ModuleType.disk.stringValue)_base", defaultValue: "byte")) ?? .byte
    }
    
    public var pid: Int
    public var name: String
    public var icon: NSImage {
        if let app = NSRunningApplication(processIdentifier: pid_t(self.pid)) {
            return app.icon ?? Constants.defaultProcessIcon
        }
        return Constants.defaultProcessIcon
    }
    
    var read: Int
    var write: Int
    
    init(pid: Int, name: String, read: Int, write: Int) {
        self.pid = pid
        self.name = name
        self.read = read
        self.write = write
        
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            if let name = app.localizedName {
                self.name = name
            }
        }
    }
}

public class Disk: Module {
    private let popupView: Popup = Popup(.disk)
    private let settingsView: Settings = Settings(.disk)
    private let portalView: Portal = Portal(.disk)
    private let notificationsView: Notifications = Notifications(.disk)
    
    private var capacityReader: CapacityReader?
    private var activityReader: ActivityReader?
    private var processReader: ProcessReader?
    
    private var selectedDisk: String = ""
    
    private var textValue: String {
        Store.shared.string(key: "\(self.name)_textWidgetValue", defaultValue: "$capacity.free/$capacity.total")
    }

    public init() {
        super.init(
            moduleType: .disk,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }
        
        self.capacityReader = CapacityReader(.disk) { [weak self] value in
            if let value {
                self?.capacityCallback(value)
            }
        }
        self.activityReader = ActivityReader(.disk) { [weak self] value in
            if let value {
                self?.activityCallback(value)
            }
        }
        self.processReader = ProcessReader(.disk) { [weak self] value in
            if let list = value {
                self?.popupView.processCallback(list)
            }
        }
        
        self.selectedDisk = Store.shared.string(key: "\(ModuleType.disk.stringValue)_disk", defaultValue: self.selectedDisk)
        
        self.settingsView.selectedDiskHandler = { [weak self] value in
            self?.selectedDisk = value
            self?.capacityReader?.read()
        }
        self.settingsView.callback = { [weak self] in
            self?.capacityReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.capacityReader?.setInterval(value)
        }
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            self?.popupView.numberOfProcessesUpdated()
            DispatchQueue.global(qos: .background).async {
                self?.processReader?.read()
            }
        }
        
        self.setReaders([self.capacityReader, self.activityReader, self.processReader])
    }
    
    private func capacityCallback(_ value: Disks) {
        guard self.enabled else { return }
        
        DispatchQueue.main.async(execute: {
            self.popupView.capacityCallback(value)
        })
        self.settingsView.setList(value)
        
        guard let d = value.first(where: { $0.mediaName == self.selectedDisk }) ?? value.first(where: { $0.root }) else {
            return
        }
        
        self.portalView.utilizationCallback(d)
        self.notificationsView.utilizationCallback(d.percentage)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini: widget.setValue(d.percentage)
            case let widget as BarChart: widget.setValue([[ColorValue(d.percentage)]])
            case let widget as MemoryWidget:
                widget.setValue((DiskSize(d.free).getReadableMemory(), DiskSize(d.size - d.free).getReadableMemory()), usedPercentage: d.percentage)
            case let widget as PieChart:
                widget.setValue([
                    circle_segment(value: d.percentage, color: NSColor.systemBlue)
                ])
            case let widget as TextWidget:
                var text = "\(self.textValue)"
                let pairs = TextWidget.parseText(text)
                pairs.forEach { pair in
                    var replacement: String? = nil
                    
                    switch pair.key {
                    case "$capacity":
                        switch pair.value {
                        case "total": replacement = DiskSize(d.size).getReadableMemory()
                        case "used": replacement = DiskSize(d.size - d.free).getReadableMemory()
                        case "free": replacement = DiskSize(d.free).getReadableMemory()
                        default: return
                        }
                    case "$percentage":
                        var percentage: Int
                        switch pair.value {
                        case "used": percentage = Int((Double(d.size - d.free) / Double(d.size)) * 100)
                        case "free": percentage = Int((Double(d.free) / Double(d.size)) * 100)
                        default: return
                        }
                        replacement = "\(percentage < 0 ? 0 : percentage)%"
                    default: return
                    }
                    
                    if let replacement {
                        let key = pair.value.isEmpty ? pair.key : "\(pair.key).\(pair.value)"
                        text = text.replacingOccurrences(of: key, with: replacement)
                    }
                }
                widget.setValue(text)
            default: break
            }
        }
    }

    private func activityCallback(_ value: Disks) {
        guard self.enabled else { return }
        
        DispatchQueue.main.async(execute: {
            self.popupView.activityCallback(value)
        })
        
        guard let d = value.first(where: { $0.mediaName == self.selectedDisk }) ?? value.first(where: { $0.root }) else {
            return
        }
        
        self.portalView.activityCallback(d)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            default: break
            }
        }
    }
}
