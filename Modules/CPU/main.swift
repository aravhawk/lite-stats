//
//  main.swift
//  CPU
//
//  Created by Serhiy Mytrovtsiy on 09/04/2020.
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public struct CPU_Load {
    public var totalUsage: Double = 0
    var usagePerCore: [Double] = []
    var usageECores: Double? = nil
    var usagePCores: Double? = nil

    var systemLoad: Double = 0
    var userLoad: Double = 0
    var idleLoad: Double = 0
}

public struct CPU_Frequency {
    var value: Double = 0
    var eCore: Double = 0
    var pCore: Double = 0
}

public struct CPU_AverageLoad {
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
}

public class CPU: Module {
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    
    private var loadReader: LoadReader? = nil
    private var processReader: ProcessReader? = nil
    private var temperatureReader: TemperatureReader? = nil
    private var frequencyReader: FrequencyReader? = nil
    private var averageLoadReader: AverageLoadReader? = nil
    
    private var usagePerCoreState: Bool {
        Store.shared.bool(key: "\(self.config.name)_usagePerCore", defaultValue: false)
    }
    private var splitValueState: Bool {
        Store.shared.bool(key: "\(self.config.name)_splitValue", defaultValue: false)
    }
    private var groupByClustersState: Bool {
        Store.shared.bool(key: "\(self.config.name)_clustersGroup", defaultValue: false)
    }
    private var systemColor: NSColor { SColor.stored("\(self.config.name)_systemColor", defaultValue: .secondRed) }
    private var userColor: NSColor { SColor.stored("\(self.config.name)_userColor", defaultValue: .secondBlue) }
    private var eCoreColor: NSColor { SColor.stored("\(self.config.name)_eCoresColor", defaultValue: .teal) }
    private var pCoreColor: NSColor { SColor.stored("\(self.config.name)_pCoresColor", defaultValue: .indigo) }
    private lazy var coreTypesById: [Int32: coreType] = {
        guard let cores = SystemKit.shared.device.info.cpu?.cores else { return [:] }
        return Dictionary(uniqueKeysWithValues: cores.map { ($0.id, $0.type) })
    }()

    public init() {
        self.settingsView = Settings(.CPU)
        self.popupView = Popup(.CPU)
        self.portalView = Portal(.CPU)
        self.notificationsView = Notifications(.CPU)
        
        super.init(
            moduleType: .CPU,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }
        
        self.loadReader = LoadReader(.CPU) { [weak self] value in
            self?.loadCallback(value)
        }
        self.processReader = ProcessReader(.CPU) { [weak self] value in
            self?.popupView.processCallback(value)
        }
        self.averageLoadReader = AverageLoadReader(.CPU, popup: true) { [weak self] value in
            self?.popupView.averageCallback(value)
        }
        self.temperatureReader = TemperatureReader(.CPU, popup: true) { [weak self] value in
            self?.popupView.temperatureCallback(value)
        }
        
        self.frequencyReader = FrequencyReader(.CPU, popup: true) { [weak self] value in
            self?.popupView.frequencyCallback(value)
        }
        
        self.settingsView.callback = { [weak self] in
            self?.loadReader?.refresh()
        }
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            self?.popupView.numberOfProcessesUpdated()
            self?.processReader?.refresh()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.loadReader?.setInterval(value)
        }
        self.settingsView.setTopInterval = { [weak self] value in
            self?.processReader?.setInterval(value)
        }
        
        self.setReaders([
            self.loadReader,
            self.processReader,
            self.temperatureReader,
            self.frequencyReader,
            self.averageLoadReader
        ])
    }
    
    private func loadCallback(_ raw: CPU_Load?) {
        guard let value = raw, self.enabled else { return }
        
        self.popupView.loadCallback(value)
        self.portalView.callback(value)
        self.notificationsView.loadCallback(value)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { [self] (w: SWidget) in
            switch w.item {
            case let widget as Mini: widget.setValue(value.totalUsage)
            case let widget as LineChart: widget.setValue(value.totalUsage)
            case let widget as BarChart:
                var val: [[ColorValue]] = [[ColorValue(value.totalUsage)]]
                if self.usagePerCoreState {
                    if widget.colorState == .cluster {
                        val = []
                        for (i, v) in value.usagePerCore.enumerated() {
                            let coreType = self.coreTypesById[Int32(i)]
                            val.append([ColorValue(v, color: coreType == .efficiency ? self.eCoreColor : self.pCoreColor)])
                        }
                    } else {
                        val = value.usagePerCore.map({ [ColorValue($0)] })
                    }
                } else if self.splitValueState {
                    val = [[
                        ColorValue(value.systemLoad, color: self.systemColor),
                        ColorValue(value.userLoad, color: self.userColor)
                    ]]
                } else if self.groupByClustersState, let e = value.usageECores, let p = value.usagePCores {
                    if widget.colorState == .cluster {
                        val = [
                            [ColorValue(e, color: self.eCoreColor)],
                            [ColorValue(p, color: self.pCoreColor)]
                        ]
                    } else {
                        val = [[ColorValue(e)], [ColorValue(p)]]
                    }
                }
                widget.setValue(val)
            case let widget as PieChart:
                widget.setValue([
                    circle_segment(value: value.systemLoad, color: self.systemColor),
                    circle_segment(value: value.userLoad, color: self.userColor)
                ])
            case let widget as Tachometer:
                widget.setValue([
                    circle_segment(value: value.systemLoad, color: self.systemColor),
                    circle_segment(value: value.userLoad, color: self.userColor)
                ])
            default: break
            }
        }
    }
}
