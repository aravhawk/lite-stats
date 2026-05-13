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
            self?.sensorsReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.ensureReader()
            self?.sensorsReader?.setInterval(value)
        }
        self.settingsView.HIDcallback = { [weak self] in
            self?.ensureReader()
            DispatchQueue.global(qos: .background).async {
                self?.sensorsReader?.HIDCallback()
                DispatchQueue.main.async {
                    self?.reloadSensorViews()
                }
            }
        }
        self.settingsView.unknownCallback = { [weak self] in
            self?.ensureReader()
            DispatchQueue.global(qos: .background).async {
                self?.sensorsReader?.unknownCallback()
                DispatchQueue.main.async {
                    self?.reloadSensorViews()
                }
            }
        }
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: self.selectedSensor)
        self.settingsView.selectedHandler = { [weak self] value in
            self?.selectedSensor = value
            self?.ensureReader()
            self?.sensorsReader?.read()
        }
        self.settingsView.loadCallback = { [weak self] in
            self?.ensureReader()
        }
        self.popupView.visibilityHandler = { [weak self] visible in
            self?.sensorsReader?.setPopupVisible(visible)
            guard visible else { return }
            DispatchQueue.global(qos: .utility).async {
                self?.sensorsReader?.read()
            }
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

    private func ensureReader() {
        guard self.sensorsReader == nil else { return }

        self.sensorsReader = SensorsReader { [weak self] value in
            self?.usageCallback(value)
        }

        self.reloadSensorViews()
        self.setReaders([self.sensorsReader])
    }

    private func reloadSensorViews() {
        self.settingsView.setList(self.sensorsReader?.list.sensors)
        self.popupView.setup(self.sensorsReader?.list.sensors)
        self.portalView.setup(self.sensorsReader?.list.sensors)
        self.notificationsView.setup(self.sensorsReader?.list.sensors)
    }
    
    private func usageCallback(_ raw: Sensors_List?) {
        guard let value = raw, self.enabled else { return }
        
        self.popupView.usageCallback(value.sensors)
        self.portalView.usageCallback(value.sensors)
        self.notificationsView.usageCallback(value.sensors)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                if let active = value.sensors.first(where: { $0.key == self.selectedSensor }) {
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
                
                value.sensors.forEach { (s: Sensor_p) in
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
                value.sensors.filter{ $0 is Fan }.forEach { (s: Sensor_p) in
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
