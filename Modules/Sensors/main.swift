//
//  main.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 17/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public class Sensors: Module {
    private var sensorsReader: SensorsReader?
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    
    private var fanValueState: FanValue {
        FanValue(rawValue: Store.shared.string(key: "\(self.config.name)_fanValue", defaultValue: "percentage")) ?? .percentage
    }
    
    private var selectedSensor: String
    
    public init() {
        self.settingsView = Settings(.sensors)
        self.popupView = Popup()
        self.portalView = Portal(.sensors)
        self.notificationsView = Notifications(.sensors)
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: "Average System Total")
        
        super.init(
            moduleType: .sensors,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }
        
        self.settingsView.callback = { [weak self] in
            self?.ensureReader()
            self?.sensorsReader?.refresh()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.ensureReader()
            self?.sensorsReader?.setInterval(value)
        }
        self.settingsView.HIDcallback = { [weak self] in
            self?.ensureReader()
            self?.sensorsReader?.HIDCallback()
            self?.reloadSensorViews()
        }
        self.settingsView.unknownCallback = { [weak self] in
            self?.ensureReader()
            self?.sensorsReader?.unknownCallback()
            self?.reloadSensorViews()
        }
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: self.selectedSensor)
        self.settingsView.selectedHandler = { [weak self] value in
            self?.selectedSensor = value
            self?.ensureReader()
            self?.sensorsReader?.refresh()
        }
        self.settingsView.loadCallback = { [weak self] in
            self?.ensureReader()
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
    }
    
    // the popup and the portal show the sensors enabled for the popup, they are only read while one of them is visible
    public override func visibilityCallback(_ state: Bool) {
        super.visibilityCallback(state)
        self.portalVisibilityCallback(state)
    }
    
    public override func portalVisibilityCallback(_ state: Bool) {
        self.sensorsReader?.setPopupVisible(state)
        if state && self.enabled {
            self.sensorsReader?.refresh()
        }
    }

    private func ensureReader() {
        guard self.sensorsReader == nil else { return }

        self.sensorsReader = SensorsReader { [weak self] value in
            self?.usageCallback(value)
        }

        self.reloadSensorViews()
        self.setReaders([self.sensorsReader])
    }

    private func reloadSensorViews() {
        let list = self.sensorsReader?.list
        self.settingsView.setList(list)
        self.popupView.setup(list)
        self.portalView.setup(list)
        self.notificationsView.setup(list)
    }
    
    private func usageCallback(_ raw: [Sensor_p]?) {
        guard let sensors = raw, self.enabled else { return }
        
        self.popupView.usageCallback(sensors)
        self.portalView.usageCallback(sensors)
        self.notificationsView.usageCallback(sensors)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                if let active = sensors.first(where: { $0.key == self.selectedSensor }) {
                    var value: Double = active.localValue/100
                    var unit: String = active.miniUnit
                    if let fan = active as? Fan, self.fanValueState == .percentage {
                        value = Double(fan.percentage)/100
                        unit = "%"
                    }
                    if value > 999 {
                        unit = ""
                    }
                    widget.setValue(value)
                    widget.setSuffix(unit)
                }
            case let widget as StackWidget:
                var list: [Stack_t] = []
                
                sensors.forEach { (s: Sensor_p) in
                    if s.state {
                        var value = s.formattedMiniValue
                        if let f = s as? Fan {
                            if self.fanValueState == .percentage {
                                value = "\(f.percentage)%"
                            }
                        }
                        list.append(Stack_t(key: s.key, value: value))
                    }
                }
                
                widget.setValues(list)
            case let widget as BarChart:
                var flatList: [[ColorValue]] = []
                sensors.filter{ $0 is Fan }.forEach { (s: Sensor_p) in
                    if s.state, let f = s as? Fan {
                        flatList.append([ColorValue(((f.value*100)/f.maxSpeed)/100)])
                    }
                }
                widget.setValue(flatList)
            default: break
            }
        }
    }
}
