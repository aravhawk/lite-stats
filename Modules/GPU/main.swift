//
//  main.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 17/08/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public struct GPU_Info {
    public let id: String
    public let IOClass: String
    public var vendor: String? = nil
    public let model: String
    public var cores: Int? = nil
    
    public var state: Bool = true
    
    public var fanSpeed: Int? = nil
    public var coreClock: Int? = nil
    public var memoryClock: Int? = nil
    public var temperature: Double? = nil
    public var utilization: Double? = nil
    public var renderUtilization: Double? = nil
    public var tilerUtilization: Double? = nil
}

public struct GPUs {
    public var list: [GPU_Info] = []
    
    internal func active() -> [GPU_Info] {
        return self.list.filter{ $0.state && $0.utilization != nil }.sorted{ $0.utilization ?? 0 > $1.utilization ?? 0 }
    }
}

public class GPU: Module {
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    
    private var infoReader: InfoReader? = nil
    
    private var selectedGPU: String = ""
    
    public init() {
        self.popupView = Popup()
        self.settingsView = Settings(.GPU)
        self.portalView = Portal(.GPU)
        self.notificationsView = Notifications(.GPU)
        
        super.init(
            moduleType: .GPU,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }
        
        self.selectedGPU = Store.shared.string(key: "\(self.config.name)_gpu", defaultValue: self.selectedGPU)
        
        self.settingsView.selectedGPUHandler = { [weak self] value in
            self?.selectedGPU = value
            self?.ensureReader()
            self?.infoReader?.refresh()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.ensureReader()
            self?.infoReader?.setInterval(value)
        }
        self.settingsView.callback = { [weak self] in
            self?.ensureReader()
            self?.infoReader?.refresh()
        }
        self.settingsView.loadCallback = { [weak self] in
            self?.ensureReader()
            self?.infoReader?.refresh()
        }
        
        if self.enabled {
            self.ensureReader()
        }
    }

    public override func willEnable() {
        self.ensureReader()
    }

    public override func settingsWillOpen() {
        self.ensureReader()
        self.infoReader?.refresh()
    }

    private func ensureReader() {
        guard self.infoReader == nil else { return }

        self.infoReader = InfoReader(.GPU) { [weak self] value in
            self?.infoCallback(value)
        }
        self.setReaders([self.infoReader])
    }
    
    private func infoCallback(_ raw: GPUs?) {
        guard let value = raw, !value.list.isEmpty else { return }
        self.settingsView.setList(value)
        guard self.enabled else { return }
        
        self.popupView.infoCallback(value)
        
        let activeGPUs = value.active()
        guard let activeGPU = activeGPUs.first(where: { $0.state }) ?? activeGPUs.first else {
            return
        }
        let selectedGPU: GPU_Info = activeGPUs.first{ $0.model == self.selectedGPU } ?? activeGPU
        guard let utilization = selectedGPU.utilization else {
            return
        }
        
        self.portalView.callback(selectedGPU)
        self.notificationsView.usageCallback(utilization)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                widget.setValue(utilization)
                widget.setTitle(nil)
            case let widget as LineChart: widget.setValue(utilization)
            case let widget as BarChart: widget.setValue([[ColorValue(utilization)]])
            case let widget as Tachometer:
                widget.setValue([
                    circle_segment(value: utilization, color: NSColor.systemBlue)
                ])
            default: break
            }
        }
    }
}
