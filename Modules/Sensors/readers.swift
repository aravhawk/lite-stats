//
//  readers.swift
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

internal class SensorsReader: Reader<[Sensor_p]> {
    static let HIDtypes: [SensorType] = [.temperature, .voltage]
    private static let powerSensorKeys: [String] = ["CPU Power", "GPU Power", "ANE Power", "RAM Power", "PCI Power"]
    
    internal private(set) var list: [Sensor_p] = []
    
    private var lastRead: Date = Date()
    private let firstRead: Date = Date()
    
    private var HIDState: Bool {
        Store.shared.bool(key: "Sensors_hid", defaultValue: false)
    }
    private var unknownSensorsState: Bool
    private var popupVisible: Bool = false
    
    private var channels: CFMutableDictionary? = nil
    private var subscription: IOReportSubscriptionRef? = nil
    private var energy: (time: TimeInterval, values: [Double])? = nil
    
    // what has to be read, recomputed only when the settings or the popup visibility change
    private struct Plan {
        var generation: Int
        var popupVisible: Bool
        var smc: [Int] = []
        var hid: Bool = false
        var power: Bool = false
    }
    private var plan: Plan? = nil
    
    init(callback: @escaping ([Sensor_p]?) -> Void = {_ in }) {
        self.unknownSensorsState = Store.shared.bool(key: "Sensors_unknown", defaultValue: false)
        super.init(.sensors, callback: callback)
        self.list = self.sensors()
    }
    
    private func sensors() -> [Sensor_p] {
        var list: [Sensor_p] = []
        var known: Set<String> = []
        
        if let count = SMC.shared.getValue("FNum") {
            list += self.loadFans(Int(count))
        }
        
        let platform = SystemKit.shared.device.platform
        let sensorsList = SensorsList.filter { platform == nil || $0.platforms.contains(platform!) }
        sensorsList.filter { !$0.key.contains("%") }.forEach { s in
            guard !known.contains(s.key), SMC.shared.exists(s.key) else { return }
            list.append(s)
            known.insert(s.key)
        }
        sensorsList.filter { $0.key.contains("%") }.forEach { s in
            var index = 1
            for i in 0..<10 {
                let key = s.key.replacingOccurrences(of: "%", with: "\(i)")
                guard !known.contains(key), SMC.shared.exists(key) else { continue }
                var sensor = s.copy()
                sensor.key = key
                sensor.name = s.name.replacingOccurrences(of: "%", with: "\(index)")
                list.append(sensor)
                known.insert(key)
                index += 1
            }
        }
        
        // enumerating every SMC key is expensive, only done when unknown sensors are requested
        if self.unknownSensorsState {
            SMC.shared.getAllKeys().filter { !known.contains($0) }.forEach { key in
                let type: SensorType
                switch key.prefix(1) {
                case "T": type = .temperature
                case "V": type = .voltage
                case "P": type = .power
                case "I": type = .current
                default: return
                }
                list.append(Sensor(key: key, name: key, group: .unknown, type: type, platforms: []))
            }
        }
        
        for i in list.indices where !(list[i] is Fan) {
            list[i].value = SMC.shared.getValue(list[i].key) ?? 0
        }
        
        var results = list.filter { s in
            switch s.type {
            case .temperature: return s.value != 0 && s.value <= 110
            case .current: return s.value <= 100
            default: return true
            }
        }
        
        if self.HIDState {
            results += self.initHIDSensors()
        }
        results += self.initIOSensors()
        results += self.initCalculatedSensors(results)
        
        return results
    }
    
    internal func setPopupVisible(_ value: Bool) {
        self.popupVisible = value
    }
    
    private func makePlan() -> Plan {
        let selected = Store.shared.string(key: "Sensors_sensor", defaultValue: "Average System Total")
        let popup = self.popupVisible
        func visible(_ s: Sensor_p) -> Bool {
            s.key == selected || s.state || !s.notificationThreshold.isEmpty || (popup && s.popupState)
        }
        
        // every SMC read is a ~0.1ms firmware round trip, so the sources of the computed sensors are only read when shown
        let computed = self.list.filter { $0.isComputed && visible($0) }.map { $0.key }
        let cpuAverages = computed.contains("Average CPU") || computed.contains("Hottest CPU")
        let gpuAverages = computed.contains("Average GPU") || computed.contains("Hottest GPU")
        let fans = computed.contains("Fastest fan")
        let hidSOC = self.list.contains { ($0.key == "Average SOC" || $0.key == "Hottest SOC") && visible($0) }
        
        var plan = Plan(generation: Store.shared.generation, popupVisible: popup)
        plan.smc = self.list.indices.filter { i in
            let s = self.list[i]
            guard s.group != .hid, !s.isComputed, self.unknownSensorsState || s.group != .unknown else { return false }
            let average = s.average && ((cpuAverages && s.group == .CPU) || (gpuAverages && s.group == .GPU))
            return visible(s) || s.key == "PSTR" || average || (fans && s.type == .fan)
        }
        plan.hid = self.HIDState && (cpuAverages || gpuAverages || hidSOC || self.list.contains { $0.group == .hid && visible($0) })
        plan.power = self.list.contains { SensorsReader.powerSensorKeys.contains($0.key) && visible($0) }
        return plan
    }
    
    public override func read() {
        if self.plan?.generation != Store.shared.generation || self.plan?.popupVisible != self.popupVisible {
            self.plan = self.makePlan()
        }
        guard let plan = self.plan else { return }
        var sensors = self.list
        
        for i in plan.smc {
            var newValue = SMC.shared.getValue(sensors[i].key) ?? 0
            if sensors[i].type == .temperature && sensors[i].group == .CPU && (newValue < 10 || newValue > 120) { // fix for m2 broken sensors
                newValue = sensors[i].value
            }
            sensors[i].value = newValue
        }
        
        func set(_ key: String, _ value: Double) {
            if let idx = sensors.firstIndex(where: { $0.key == key }) {
                sensors[idx].value = value
            }
        }
        
        var cpuSensors = sensors.filter({ $0.group == .CPU && $0.type == .temperature && $0.average }).map{ $0.value }
        var gpuSensors = sensors.filter({ $0.group == .GPU && $0.type == .temperature && $0.average }).map{ $0.value }
        
        if plan.hid {
            for typ in SensorsReader.HIDtypes {
                let (page, usage, type) = self.m1Preset(type: typ)
                AppleSiliconSensors(page, usage, type)?.forEach { (key, value) in
                    guard let key = key as? String, let value = value as? Double, value < 300 && value >= 0,
                          let idx = sensors.firstIndex(where: { $0.group == .hid && $0.key == key }) else { return }
                    sensors[idx].value = value
                }
            }
            
            cpuSensors += sensors.filter({ $0.key.hasPrefix("pACC MTR Temp") || $0.key.hasPrefix("eACC MTR Temp") }).map{ $0.value }
            gpuSensors += sensors.filter({ $0.key.hasPrefix("GPU MTR Temp") }).map{ $0.value }
            
            let socSensors = sensors.filter({ $0.key.hasPrefix("SOC MTR Temp") }).map{ $0.value }
            if let max = socSensors.max() {
                set("Average SOC", socSensors.reduce(0, +) / Double(socSensors.count))
                set("Hottest SOC", max)
            }
        }
        
        if plan.power, let powers = self.powerSensors() {
            zip(SensorsReader.powerSensorKeys, powers).forEach { set($0, $1) }
        }
        
        if let max = cpuSensors.max() {
            set("Average CPU", cpuSensors.reduce(0, +) / Double(cpuSensors.count))
            set("Hottest CPU", max)
        }
        if let max = gpuSensors.max() {
            set("Average GPU", gpuSensors.reduce(0, +) / Double(gpuSensors.count))
            set("Hottest GPU", max)
        }
        if let fastest = sensors.compactMap({ $0 as? Fan }).filter({ !$0.isComputed }).max(by: { $0.value < $1.value }),
           let idx = sensors.firstIndex(where: { $0.key == "Fastest fan" }), var fan = sensors[idx] as? Fan {
            fan.value = fastest.value
            fan.minSpeed = fastest.minSpeed
            fan.maxSpeed = fastest.maxSpeed
            sensors[idx] = fan
        }
        
        if let PSTRSensor = sensors.first(where: { $0.key == "PSTR"}), PSTRSensor.value > 0 {
            let now = Date()
            let sinceLastRead = now.timeIntervalSince(self.lastRead)
            let sinceFirstRead = now.timeIntervalSince(self.firstRead)
            
            if let totalIdx = sensors.firstIndex(where: {$0.key == "Total System Consumption"}), sinceLastRead > 0 {
                sensors[totalIdx].value += PSTRSensor.value * sinceLastRead / 3600
                if sinceFirstRead > 0 {
                    set("Average System Total", sensors[totalIdx].value * 3600 / sinceFirstRead)
                }
            }
            self.lastRead = now
        }
        
        // cut off low dc in voltage and current
        if let idx = sensors.firstIndex(where: { $0.key == "VD0R" }), sensors[idx].value < 0.4 {
            sensors[idx].value = 0
        }
        if let idx = sensors.firstIndex(where: { $0.key == "ID0R" }), sensors[idx].value < 0.05 {
            sensors[idx].value = 0
        }
        
        self.list = sensors
        self.callback(sensors)
    }
    
    private func initCalculatedSensors(_ sensors: [Sensor_p]) -> [Sensor_p] {
        var list: [Sensor_p] = []
        
        var cpuSensors = sensors.filter({ $0.group == .CPU && $0.type == .temperature && $0.average }).map{ $0.value }
        var gpuSensors = sensors.filter({ $0.group == .GPU && $0.type == .temperature && $0.average }).map{ $0.value }
        
        if self.HIDState {
            cpuSensors += sensors.filter({ $0.key.hasPrefix("pACC MTR Temp") || $0.key.hasPrefix("eACC MTR Temp") }).map{ $0.value }
            gpuSensors += sensors.filter({ $0.key.hasPrefix("GPU MTR Temp") }).map{ $0.value }
        }
        
        let fanSensors = sensors.compactMap({ $0 as? Fan })
        
        if let max = cpuSensors.max() {
            let value = cpuSensors.reduce(0, +) / Double(cpuSensors.count)
            list.append(Sensor(key: "Average CPU", name: "Average CPU", value: value, group: .CPU, type: .temperature, platforms: Platform.all, isComputed: true))
            list.append(Sensor(key: "Hottest CPU", name: "Hottest CPU", value: max, group: .CPU, type: .temperature, platforms: Platform.all, isComputed: true))
        }
        if let max = gpuSensors.max() {
            let value = gpuSensors.reduce(0, +) / Double(gpuSensors.count)
            list.append(Sensor(key: "Average GPU", name: "Average GPU", value: value, group: .GPU, type: .temperature, platforms: Platform.all, isComputed: true))
            list.append(Sensor(key: "Hottest GPU", name: "Hottest GPU", value: max, group: .GPU, type: .temperature, platforms: Platform.all, isComputed: true))
        }
        if fanSensors.count > 1, let f = fanSensors.max(by: { $0.value < $1.value }) {
            list.append(Fan(id: -1, key: "Fastest fan", name: "Fastest fan", minSpeed: f.minSpeed, maxSpeed: f.maxSpeed, value: f.value, isComputed: true))
        }
        
        // Init total power since launched, only if Total Power sensor is available
        if sensors.contains(where: { $0.key == "PSTR"}) {
            list.append(Sensor(key: "Total System Consumption", name: "Total System Consumption", value: 0, group: .sensor, type: .energy, platforms: Platform.all, isComputed: true))
            list.append(Sensor(key: "Average System Total", name: "Average System Total", value: 0, group: .sensor, type: .power, platforms: Platform.all, isComputed: true))
        }
        
        return list.filter({ (s: Sensor_p) -> Bool in
            switch s.type {
            case .temperature:
                return s.value < 110 && s.value >= 0
            case .voltage:
                return s.value < 300 && s.value >= 0
            case .current:
                return s.value < 100 && s.value >= 0
            default: return true
            }
        }).sorted { $0.key.lowercased() < $1.key.lowercased() }
    }
    
    public func unknownCallback() {
        self.unknownSensorsState = Store.shared.bool(key: "Sensors_unknown", defaultValue: false)
        self.plan = nil
    }
}

// MARK: - Fans

extension SensorsReader {
    private func loadFans(_ count: Int) -> [Sensor_p] {
        debug("Found \(Int(count)) fans", log: self.log)
        
        var list: [Fan] = []
        for i in 0..<Int(count) {
            var name = SMC.shared.getStringValue("F\(i)ID")
            
            if name == nil && count == 2 {
                switch i {
                case 0:
                    name = localizedString("Left fan")
                case 1:
                    name = localizedString("Right fan")
                default: break
                }
            }
            
            list.append(Fan(
                id: i,
                key: "F\(i)Ac",
                name: name ?? "\(localizedString("Fan")) #\(i)",
                minSpeed: SMC.shared.getValue("F\(i)Mn") ?? 1,
                maxSpeed: SMC.shared.getValue("F\(i)Mx") ?? 1,
                value: SMC.shared.getValue("F\(i)Ac") ?? 0
            ))
        }
        
        return list
    }
}

// MARK: - HID sensors

extension SensorsReader {
    private func m1Preset(type: SensorType) -> (Int32, Int32, Int32) {
        var page: Int32 = 0
        var usage: Int32 = 0
        var eventType: Int32 = kIOHIDEventTypeTemperature
        
        //  usagePage:
        //    kHIDPage_AppleVendor                        = 0xff00,
        //    kHIDPage_AppleVendorTemperatureSensor       = 0xff05,
        //    kHIDPage_AppleVendorPowerSensor             = 0xff08,
        //    kHIDPage_GenericDesktop
        //
        //  usage:
        //    kHIDUsage_AppleVendor_TemperatureSensor     = 0x0005,
        //    kHIDUsage_AppleVendorPowerSensor_Current    = 0x0002,
        //    kHIDUsage_AppleVendorPowerSensor_Voltage    = 0x0003,
        //    kHIDUsage_GD_Keyboard
        //
        
        switch type {
        case .temperature:
            page = 0xff00
            usage = 0x0005
            eventType = kIOHIDEventTypeTemperature
        case .current:
            page = 0xff08
            usage = 0x0002
            eventType = kIOHIDEventTypePower
        case .voltage:
            page = 0xff08
            usage = 0x0003
            eventType = kIOHIDEventTypePower
        case .power, .energy, .fan: break
        }
        
        return (page, usage, eventType)
    }
    
    private func initHIDSensors() -> [Sensor] {
        var list: [Sensor] = []
        
        for typ in SensorsReader.HIDtypes {
            let (page, usage, type) = self.m1Preset(type: typ)
            if let sensors = AppleSiliconSensors(page, usage, type) {
                sensors.forEach { (key, value) in
                    guard let key = key as? String, let value = value as? Double else {
                        return
                    }
                    var name: String = key
                    
                    HIDSensorsList.forEach { (s: Sensor) in
                        if s.key.contains("%") {
                            var index = 1
                            for i in 0..<64 {
                                if s.key.replacingOccurrences(of: "%", with: "\(i)") == key {
                                    name = s.name.replacingOccurrences(of: "%", with: "\(index)")
                                }
                                index += 1
                            }
                        } else if s.key == key {
                            name = s.name
                        }
                    }
                    
                    list.append(Sensor(
                        key: key,
                        name: name,
                        value: value,
                        group: .hid,
                        type: typ,
                        platforms: Platform.all
                    ))
                }
            }
        }
        
        let socSensors = list.filter({ $0.key.hasPrefix("SOC MTR Temp") }).map{ $0.value }
        if !socSensors.isEmpty {
            let value = socSensors.reduce(0, +) / Double(socSensors.count)
            list.append(Sensor(key: "Average SOC", name: "Average SOC", value: value, group: .hid, type: .temperature, platforms: Platform.all))
            if let max = socSensors.max() {
                list.append(Sensor(key: "Hottest SOC", name: "Hottest SOC", value: max, group: .hid, type: .temperature, platforms: Platform.all))
            }
        }
        
        return list.filter({ (s: Sensor_p) -> Bool in
            switch s.type {
            case .temperature:
                return s.value < 110 && s.value >= 0
            case .voltage:
                return s.value < 300 && s.value >= 0
            case .current:
                return s.value < 100 && s.value >= 0
            default: return true
            }
        }).sorted { $0.key.lowercased() < $1.key.lowercased() }
    }
    
    public func HIDCallback() {
        self.list = self.list.filter({ $0.group != .hid })
        if self.HIDState {
            self.list += self.initHIDSensors()
        }
        self.plan = nil
    }
}

// MARK: - Apple Silicon power sensors

extension SensorsReader {
    private func initIOSensors() -> [Sensor] {
        return [
            Sensor(key: "CPU Power", name: "CPU Power", group: .CPU, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "GPU Power", name: "GPU Power", group: .GPU, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "ANE Power", name: "ANE Power", group: .system, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "RAM Power", name: "RAM Power", group: .system, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "PCI Power", name: "PCI Power", group: .system, type: .power, platforms: Platform.apple, isComputed: true)
        ]
    }
    
    // average power (W) of CPU, GPU, ANE, DRAM and PCI since the previous call, from the cumulative energy counters
    private func powerSensors() -> [Double]? {
        // the channel lookup takes tens of milliseconds, so it is done once a power sensor is shown
        if self.subscription == nil {
            self.channels = ioReportChannels([("Energy Model", nil)])
            var dict: Unmanaged<CFMutableDictionary>?
            self.subscription = IOReportCreateSubscription(nil, self.channels, &dict, 0, nil)
            dict?.release()
        }
        guard let subscription = self.subscription,
              let sample = IOReportCreateSamples(subscription, self.channels, nil)?.takeRetainedValue(),
              let items = (sample as NSDictionary)["IOReportChannels"] as? [CFDictionary] else {
            return nil
        }
        
        var values: [Double] = [0, 0, 0, 0, 0]
        for item in items {
            guard let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String?,
                  let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as String? else { continue }
            let joules = Double(IOReportSimpleGetIntegerValue(item, 0)).power(unit)
            
            if channel.hasSuffix("CPU Energy") {
                values[0] = joules
            } else if channel.hasSuffix("GPU Energy") {
                values[1] = joules
            } else if channel.hasPrefix("ANE") {
                values[2] = joules
            } else if channel.hasPrefix("DRAM") {
                values[3] = joules
            } else if channel.hasPrefix("PCI") && channel.hasSuffix("Energy") {
                values[4] = joules
            }
        }
        
        let now = ProcessInfo.processInfo.systemUptime
        defer { self.energy = (now, values) }
        guard let prev = self.energy, now > prev.time else { return nil }
        return zip(values, prev.values).map { max($0 - $1, 0) / (now - prev.time) }
    }
}

private func ioReportChannels(_ names: [(group: String, subgroup: String?)]) -> CFMutableDictionary? {
    let channels = names.compactMap { IOReportCopyChannelsInGroup($0.group as CFString, $0.subgroup as CFString?, 0, 0, 0)?.takeRetainedValue() }
    guard let first = channels.first else { return nil }
    channels.dropFirst().forEach { IOReportMergeChannels(first, $0, nil) }
    guard let channel = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(first), first),
          (channel as NSDictionary)["IOReportChannels"] != nil else { return nil }
    return channel
}
