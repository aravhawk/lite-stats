//
//  notifications.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 05/12/2023
//  Using Swift 5.0
//  Running on macOS 14.1
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

class Notifications: NotificationsWrapper {
    private var unknownSensorsState: Bool {
        Store.shared.bool(key: "Sensors_unknown", defaultValue: false)
    }
    
    private var temperatureLevels: [KeyValue_t] = [
        KeyValue_t(key: "", value: "Disabled")
    ]
    private let temperatureList: [String] = ["30", "35", "40", "45", "50", "55", "60", "65", "70", "75", "80", "85", "90", "96", "100", "105", "110"]
    
    public override init(_ module: ModuleType) {
        super.init(module)
        for p in self.temperatureList {
            if let v = Double(p) {
                self.temperatureLevels.append(KeyValue_t(key: p, value: temperature(v)))
            }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // the rows are only built once the view is displayed, until then the list is kept
    private var pending: [Sensor_p]? = nil
    
    internal func setup(_ values: [Sensor_p]? = nil) {
        guard let values else { return }
        self.pending = values
        if self.window != nil {
            self.build()
        }
    }
    
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window != nil {
            self.build()
        }
    }
    
    private func build() {
        guard var values = self.pending else { return }
        self.pending = nil
        values = values.filter({ $0.type == .fan || $0.type == .temperature })
        if !self.unknownSensorsState {
            values = values.filter({ $0.group != .unknown })
        }
        self.subviews.forEach({ $0.removeFromSuperview() })
        
        var types: [SensorType] = []
        values.forEach { (s: Sensor_p) in
            if !types.contains(s.type) {
                types.append(s.type)
            }
        }
        
        types.forEach { (typ: SensorType) in
            let filtered = values.filter{ $0.type == typ }
            var groups: [SensorGroup] = []
            filtered.forEach { (s: Sensor_p) in
                if !groups.contains(s.group) {
                    groups.append(s.group)
                }
            }
            
            let section = PreferencesSection(label: localizedString(typ.rawValue))
            groups.forEach { (group: SensorGroup) in
                filtered.filter{ $0.group == group }.forEach { (s: Sensor_p) in
                    let btn = selectView(
                        action: #selector(self.changeSensorNotificaion),
                        items: s.type == .temperature ? temperatureLevels : notificationLevels,
                        selected: s.notificationThreshold
                    )
                    btn.identifier = NSUserInterfaceItemIdentifier(rawValue: s.key)
                    section.add(PreferencesRow(localizedString(s.name), component: btn))
                }
            }
            self.addArrangedSubview(section)
        }
    }
    
    // thresholds are read from the settings only after they change
    private var thresholds: (generation: Int, values: [String: Double])? = nil
    
    internal func usageCallback(_ values: [Sensor_p]) {
        let generation = Store.shared.generation
        if self.thresholds?.generation != generation {
            var thresholds: [String: Double] = [:]
            values.forEach { s in thresholds[s.key] = Double(s.notificationThreshold) }
            self.thresholds = (generation, thresholds)
        }
        guard let thresholds = self.thresholds?.values, !thresholds.isEmpty else { return }
        
        for s in values {
            guard let threshold = thresholds[s.key] else { continue }
            self.checkDouble(id: s.key, value: s.value, threshold: threshold, title: localizedString("Sensor threshold"),
                             subtitle: "\(localizedString(s.name)): \(s.formattedPopupValue)")
        }
    }
    
    @objc private func changeSensorNotificaion(_ sender: NSMenuItem) {
        guard let id = sender.identifier, let key = sender.representedObject as? String else { return }
        Store.shared.set(key: "sensor_\(id.rawValue)_notification", value: key)
    }
}
