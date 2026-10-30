//
//  popup.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 22/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Popup: PopupWrapper {
    private var list: [String: NSView] = [:]
    
    private var unknownSensorsState: Bool { Store.shared.bool(key: "Sensors_unknown", defaultValue: false) }
    private var fanValueState: FanValue = .percentage
    
    private var sensors: [Sensor_p] = []
    private let settingsView: NSStackView = NSStackView()
    
    public init() {
        super.init(ModuleType.sensors, frame: NSRect( x: 0, y: 0, width: Constants.Popup.width, height: 0))
        
        self.fanValueState = FanValue(rawValue: Store.shared.string(key: "Sensors_popup_fanValue", defaultValue: self.fanValueState.rawValue)) ?? .percentage
        
        self.orientation = .vertical
        self.spacing = 0
        self.translatesAutoresizingMaskIntoConstraints = false
        
        self.settingsView.orientation = .vertical
        self.settingsView.spacing = Constants.Settings.margin
        
        self.settingsView.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))
        
        self.settingsView.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Fan value"), component: selectView(
                action: #selector(self.toggleFanValue),
                items: FanValues,
                selected: self.fanValueState.rawValue
            ))
        ]))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // the sensor views are built when the popup is first opened, the settings when they are first displayed
    private var prepared: Bool = false
    private var settingsRequested: Bool = false
    
    internal func setup(_ values: [Sensor_p]? = nil, reload: Bool = false) {
        if !reload, let values {
            self.sensors = values
            if self.settingsRequested {
                self.buildSettings()
            }
        }
        if self.prepared {
            self.buildViews()
        }
    }
    
    public override func prepare() {
        guard !self.prepared else { return }
        self.prepared = true
        self.buildViews()
    }
    
    private var visibleSensors: [Sensor_p] {
        self.unknownSensorsState ? self.sensors : self.sensors.filter({ $0.group != .unknown })
    }
    
    // sensors grouped by type and then by group, in the order they appear
    private func grouped(_ sensors: [Sensor_p]) -> [(type: SensorType, sensors: [Sensor_p])] {
        var types: [SensorType] = []
        sensors.forEach { if !types.contains($0.type) { types.append($0.type) } }
        return types.map { typ in
            let filtered = sensors.filter { $0.type == typ }
            var groups: [SensorGroup] = []
            filtered.forEach { if !groups.contains($0.group) { groups.append($0.group) } }
            return (typ, groups.flatMap { group in filtered.filter { $0.group == group } })
        }
    }
    
    private func buildViews() {
        self.subviews.forEach({ $0.removeFromSuperview() })
        self.list = [:]
        
        let fans = self.sensors.compactMap({ $0 as? Fan }).filter({ $0.popupState })
        if !fans.isEmpty {
            self.addArrangedSubview(separatorView(localizedString("Fans"), width: self.frame.width))
            
            let container = NSStackView()
            container.orientation = .vertical
            container.spacing = Constants.Popup.spacing
            
            fans.forEach { (fan: Fan) in
                let sensor = SensorView(fan, width: self.frame.width, toggleable: false) {}
                self.list[fan.key] = sensor
                container.addArrangedSubview(sensor)
            }
            
            let h = container.arrangedSubviews.map({ $0.bounds.height + container.spacing }).reduce(0, +) - container.spacing
            if container.frame.size.height != h {
                container.setFrameSize(NSSize(width: container.frame.width, height: h))
            }
            self.addArrangedSubview(container)
        }
        
        for (typ, sensors) in self.grouped(self.visibleSensors) where typ != .fan {
            let filtered = sensors.filter{ $0.popupState }
            if filtered.isEmpty { continue }
            
            self.addArrangedSubview(separatorView(localizedString(typ.rawValue), width: self.frame.width))
            filtered.forEach { (s: Sensor_p) in
                let sensor = SensorView(s, width: self.frame.width) { [weak self] in
                    self?.recalculateHeight()
                }
                self.addArrangedSubview(sensor)
                self.list[s.key] = sensor
            }
        }
        
        self.recalculateHeight()
    }
    
    private func buildSettings() {
        self.settingsView.subviews.filter({ $0.identifier == NSUserInterfaceItemIdentifier("sensor") }).forEach { v in
            v.removeFromSuperview()
        }
        
        for (typ, sensors) in self.grouped(self.visibleSensors) {
            let section = PreferencesSection(label: localizedString(typ.rawValue))
            section.identifier = NSUserInterfaceItemIdentifier("sensor")
            sensors.forEach { (s: Sensor_p) in
                let btn = switchView(
                    action: #selector(self.toggleSensor),
                    state: s.popupState
                )
                btn.identifier = NSUserInterfaceItemIdentifier(rawValue: s.key)
                section.add(PreferencesRow(localizedString(s.name), component: btn))
            }
            self.settingsView.addArrangedSubview(section)
        }
    }

    internal func usageCallback(_ values: [Sensor_p]) {
        guard self.prepared else { return }
        values.filter({ $0 is Sensor }).forEach { (s: Sensor_p) in
            if let sensor = self.list[s.key] as? SensorView {
                sensor.addHistoryPoint(s)
            }
        }
        
        if self.window?.isVisible ?? false {
            values.forEach { (s: Sensor_p) in
                switch self.list[s.key] {
                case let sensor as SensorView:
                    sensor.update(s)
                case .none, .some:
                    break
                }
            }
        }
    }
    
    private func recalculateHeight() {
        let h = self.arrangedSubviews.map({ $0.bounds.height + self.spacing }).reduce(0, +) - self.spacing
        if self.frame.size.height != h {
            self.setFrameSize(NSSize(width: self.frame.width, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView? {
        if !self.settingsRequested {
            self.settingsRequested = true
            self.buildSettings()
        }
        return self.settingsView
    }
    
    @objc private func toggleFanValue(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String, let value = FanValue(rawValue: key) {
            self.fanValueState = value
            Store.shared.set(key: "Sensors_popup_fanValue", value: self.fanValueState.rawValue)
        }
    }
    
    // MARK: helpers
    
    @objc private func toggleSensor(_ sender: NSControl) {
        guard let id = sender.identifier else { return }
        Store.shared.set(key: "sensor_\(id.rawValue)_popup", value: controlState(sender))
        self.setup(reload: true)
    }
}

// MARK: - Sensor view

internal class SensorView: NSStackView {
    public var sizeCallback: (() -> Void)
    
    private var valueView: ValueSensorView!
    private var chartView: ChartSensorView!
    
    private var openned: Bool = false
    
    private var fanValueState: FanValue {
        FanValue(rawValue: Store.shared.string(key: "Sensors_popup_fanValue", defaultValue: FanValue.percentage.rawValue)) ?? .percentage
    }
    
    public init(_ sensor: Sensor_p, width: CGFloat, toggleable: Bool = true, callback: @escaping (() -> Void)) {
        self.sizeCallback = callback
        
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        
        self.orientation = .vertical
        self.distribution = .fillProportionally
        self.spacing = 0
        
        self.valueView = ValueSensorView(sensor, width: width, toggleable: toggleable, callback: { [weak self] in
            self?.open()
        })
        self.chartView = ChartSensorView(width: width, suffix: sensor.unit)
        
        self.addArrangedSubview(self.valueView)
        
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: self.bounds.width)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(_ sensor: Sensor_p) {
        var value = sensor.formattedPopupValue
        if let fan = sensor as? Fan {
            value = self.fanValueState == .percentage ? "\(fan.percentage)%" : fan.formattedValue
        }
        self.valueView.update(value)
    }
    
    public func addHistoryPoint(_ sensor: Sensor_p) {
        self.chartView.update(sensor.localValue, sensor.unit)
    }
    
    private func open() {
        if self.openned {
            self.chartView.removeFromSuperview()
        } else {
            self.addArrangedSubview(self.chartView)
        }
        self.openned = !self.openned
        
        let h = self.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
        self.setFrameSize(NSSize(width: self.frame.width, height: h))
        self.sizeCallback()
    }
}

internal class ValueSensorView: NSStackView {
    public var callback: (() -> Void)
    
    private var labelView: LabelField = {
        let view = LabelField(frame: NSRect.zero)
        view.cell?.truncatesLastVisibleLine = true
        return view
    }()
    private var valueView: ValueField = ValueField(frame: NSRect.zero)
    
    private let isToggleable: Bool
    
    public init(_ sensor: Sensor_p, width: CGFloat, toggleable: Bool = true, callback: @escaping (() -> Void)) {
        self.callback = callback
        self.isToggleable = toggleable
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        
        self.wantsLayer = true
        self.orientation = .horizontal
        self.distribution = .fillProportionally
        self.spacing = 0
        self.layer?.cornerRadius = 3
        
        self.labelView.stringValue = sensor.name
        self.labelView.toolTip = sensor.key
        self.valueView.stringValue = sensor.formattedValue
        
        self.addArrangedSubview(self.labelView)
        self.addArrangedSubview(self.valueView)
        
        if self.isToggleable {
            self.addTrackingArea(NSTrackingArea(
                rect: NSRect(x: 0, y: 0, width: self.frame.width, height: 22),
                options: [NSTrackingArea.Options.activeAlways, NSTrackingArea.Options.mouseEnteredAndExited, NSTrackingArea.Options.activeInActiveApp],
                owner: self,
                userInfo: nil
            ))
        }
        
        NSLayoutConstraint.activate([
            self.labelView.heightAnchor.constraint(equalToConstant: 16),
            self.widthAnchor.constraint(equalToConstant: self.bounds.width),
            self.heightAnchor.constraint(equalToConstant: self.bounds.height)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(_ value: String) {
        self.valueView.stringValue = value
    }
    
    override func mouseDown(with theEvent: NSEvent) {
        guard self.isToggleable else { return }
        self.callback()
    }
    
    public override func mouseEntered(with: NSEvent) {
        guard self.isToggleable else { return }
        self.layer?.backgroundColor = .init(gray: 0.01, alpha: 0.05)
    }
    
    public override func mouseExited(with: NSEvent) {
        guard self.isToggleable else { return }
        self.layer?.backgroundColor = .none
    }
}

internal class ChartSensorView: NSStackView {
    private var chart: LineChartView? = nil
    
    public init(width: CGFloat, suffix: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        self.orientation = .horizontal
        self.distribution = .fillProportionally
        self.spacing = 0
        self.layer?.cornerRadius = 3
        
        self.chart = LineChartView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: self.frame.height), num: 120, scale: .linear)
        self.chart?.suffix = suffix
        
        if let view = self.chart {
            self.addArrangedSubview(view)
        }
        
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: self.bounds.width),
            self.heightAnchor.constraint(equalToConstant: self.bounds.height)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(_ value: Double, _ suffix: String) {
        if self.chart?.suffix != suffix {
            self.chart?.suffix = suffix
        }
        self.chart?.addValue(value/100)
    }
}
