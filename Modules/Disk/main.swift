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

public struct stats {
    var read: Int64 = 0
    var write: Int64 = 0
    
    var readBytes: Int64 = 0
    var writeBytes: Int64 = 0
}

public struct smart_t {
    var temperature: Int = 0
    var life: Int = 0
    var totalRead: Int64 = 0
    var totalWritten: Int64 = 0
    var powerCycles: Int = 0
    var powerOnHours: Int = 0
}

public struct drive {
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
    
    public var percentage: Double {
        Double(max(self.size - self.free, 0)) / Double(self.size)
    }
    
    public var popupState: Bool {
        Store.shared.bool(key: "Disk_\(self.uuid)_popup", defaultValue: true)
    }
}

public struct Disks {
    public var array: [drive] = []
    
    public var count: Int { self.array.count }
    public var isEmpty: Bool { self.array.isEmpty }
    
    public func first(where predicate: (drive) -> Bool) -> drive? {
        self.array.first(where: predicate)
    }
    
    public func map<ElementOfResult>(_ transform: (drive) -> ElementOfResult?) -> [ElementOfResult] {
        self.array.compactMap(transform)
    }
    
    public func reversed() -> [drive] {
        self.array.reversed()
    }
    
    func forEach(_ body: (drive) -> Void) {
        self.array.forEach(body)
    }
    
    mutating func append(_ element: drive) {
        if !self.array.contains(where: { $0.BSDName == element.BSDName }) {
            self.array.append(element)
        }
    }
    
    // fixed disks first
    mutating func sort() {
        self.array = self.array.filter { !$0.removable } + self.array.filter { $0.removable }
    }
}

public struct Disk_process: Process_p {
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
            self?.capacityReader?.refresh()
        }
        self.settingsView.callback = { [weak self] in
            self?.capacityReader?.refresh()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.capacityReader?.setInterval(value)
        }
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            self?.popupView.numberOfProcessesUpdated()
            self?.processReader?.refresh()
        }
        
        self.setReaders([self.capacityReader, self.activityReader, self.processReader])
    }
    
    // the portal shows the disk activity, only read while the popup or the portal is visible
    public override func portalVisibilityCallback(_ state: Bool) {
        state ? self.activityReader?.start() : self.activityReader?.stop()
    }
    
    private func capacityCallback(_ value: Disks) {
        guard self.enabled else { return }
        
        self.popupView.capacityCallback(value)
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
        
        self.popupView.activityCallback(value)
        
        if let d = value.first(where: { $0.mediaName == self.selectedDisk }) ?? value.first(where: { $0.root }) {
            self.portalView.activityCallback(d)
        }
    }
}
