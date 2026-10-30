//
//  readers.swift
//  CPU
//
//  Created by Serhiy Mytrovtsiy on 10/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class LoadReader: Reader<CPU_Load> {
    private var prevCpuInfo: processor_info_array_t?
    private var numPrevCpuInfo: mach_msg_type_number_t = 0
    private var response: CPU_Load = CPU_Load()
    private var eCoreIndices: [Int] = []
    private var pCoreIndices: [Int] = []
    
    public override func setup() {
        if let cores = SystemKit.shared.device.info.cpu?.cores {
            self.eCoreIndices = cores.filter { $0.type == .efficiency }.map { Int($0.id) }
            self.pCoreIndices = cores.filter { $0.type == .performance }.map { Int($0.id) }
        }
    }
    
    deinit {
        if let prev = self.prevCpuInfo {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), vm_size_t(MemoryLayout<integer_t>.stride * Int(self.numPrevCpuInfo)))
        }
    }
    
    public override func read() {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo)
        guard result == KERN_SUCCESS, let cpuInfo else {
            error("host_processor_info(): \(String(cString: mach_error_string(result)))", log: self.log)
            return
        }
        defer {
            if let prev = self.prevCpuInfo {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), vm_size_t(MemoryLayout<integer_t>.stride * Int(self.numPrevCpuInfo)))
            }
            self.prevCpuInfo = cpuInfo
            self.numPrevCpuInfo = numCpuInfo
        }
        
        var usagePerCore: [Double] = []
        usagePerCore.reserveCapacity(Int(numCPUs))
        var userTicks: Int64 = 0
        var systemTicks: Int64 = 0
        var idleTicks: Int64 = 0
        
        for i in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * i
            func ticks(_ state: Int32) -> Int64 {
                let current = Int64(UInt32(bitPattern: cpuInfo[base + Int(state)]))
                guard let prev = self.prevCpuInfo else { return current }
                return Int64(UInt32(bitPattern: cpuInfo[base + Int(state)]) &- UInt32(bitPattern: prev[base + Int(state)]))
            }
            let user = ticks(CPU_STATE_USER) + ticks(CPU_STATE_NICE)
            let system = ticks(CPU_STATE_SYSTEM)
            let idle = ticks(CPU_STATE_IDLE)
            let total = user + system + idle
            
            usagePerCore.append(total == 0 ? 0 : Double(user + system) / Double(total))
            userTicks += user
            systemTicks += system
            idleTicks += idle
        }
        
        let totalTicks = Double(systemTicks + userTicks + idleTicks)
        if totalTicks > 0 {
            self.response.systemLoad = Double(systemTicks) / totalTicks
            self.response.userLoad = Double(userTicks) / totalTicks
            self.response.idleLoad = Double(idleTicks) / totalTicks
            self.response.totalUsage = self.response.systemLoad + self.response.userLoad
        }
        self.response.usagePerCore = usagePerCore
        self.response.usageECores = average(self.eCoreIndices, usagePerCore)
        self.response.usagePCores = average(self.pCoreIndices, usagePerCore)
        
        self.callback(self.response)
    }
}

private func average(_ indices: [Int], _ values: [Double]) -> Double? {
    let list = indices.filter { values.indices.contains($0) }
    return list.isEmpty ? nil : list.reduce(0) { $0 + values[$1] } / Double(list.count)
}

public class ProcessReader: Reader<[TopProcess]> {
    private let title: String = "CPU"
    
    private var numberOfProcesses: Int {
        get { Kit.numberOfProcesses(self.title, defaultValue: 8) }
    }
    
    public override func setup() {
        self.popup = true
        self.blocking = true
        self.setInterval(Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: 3))
    }
    
    public override func read() {
        let processes = ProcessSampler.shared.topCPUProcesses(limit: self.numberOfProcesses)
        self.callback(processes)
    }
}

public class TemperatureReader: Reader<Double> {
    private var keys: [String] = []
    
    public override func setup() {
        self.popup = true
        
        // a single CPU die sensor if the SMC has one, otherwise the average of the platform's core sensors
        if let key = ["TC0D", "TC0E", "TC0F", "TC0P", "TC0H"].first(where: { SMC.shared.getValue($0) != nil }) {
            self.keys = [key]
            return
        }
        switch SystemKit.shared.device.platform {
        case .m1, .m1Pro, .m1Max, .m1Ultra:
            self.keys = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        case .m2, .m2Pro, .m2Max, .m2Ultra:
            self.keys = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        case .m3, .m3Pro, .m3Max, .m3Ultra:
            self.keys = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        case .m4, .m4Pro, .m4Max, .m4Ultra:
            self.keys = ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        default: break
        }
    }
    
    public override func read() {
        let values = self.keys.compactMap { SMC.shared.getValue($0) }.filter { $0 < 110 }
        guard !values.isEmpty else { return }
        self.callback(values.reduce(0, +) / Double(values.count))
    }
}

// Average cluster frequency from IOReport P-state residencies accumulated between two consecutive reads.
// inspired by https://github.com/shank03/StatsBar/blob/e175aa71c914ce882ce2e90163f3eb18262a8e25/StatsBar/Service/IOReport.swift
public class FrequencyReader: Reader<CPU_Frequency> {
    private var eCoreFreqs: [Int32] = []
    private var pCoreFreqs: [Int32] = []
    private var eCoreCount: Double = 0
    private var pCoreCount: Double = 0
    
    private var channels: CFMutableDictionary? = nil
    private var subscription: IOReportSubscriptionRef? = nil
    private var prev: CFDictionary? = nil
    
    public override func setup() {
        self.popup = true
        let cpu = SystemKit.shared.device.info.cpu
        self.eCoreFreqs = cpu?.eCoreFrequencies ?? []
        self.pCoreFreqs = cpu?.pCoreFrequencies ?? []
        self.eCoreCount = Double(cpu?.eCores ?? 0)
        self.pCoreCount = Double(cpu?.pCores ?? 0)
    }
    
    // looking up the IOReport channels takes tens of milliseconds, so it is done when the popup is first opened
    private func subscribe() -> IOReportSubscriptionRef? {
        if self.subscription == nil, !self.eCoreFreqs.isEmpty, !self.pCoreFreqs.isEmpty {
            self.channels = ioReportChannels([("CPU Stats", "CPU Complex Performance States"), ("CPU Stats", "CPU Core Performance States")])
            var dict: Unmanaged<CFMutableDictionary>?
            self.subscription = IOReportCreateSubscription(nil, self.channels, &dict, 0, nil)
            dict?.release()
        }
        return self.subscription
    }
    
    public override func stop() {
        self.prev = nil
        super.stop()
    }
    
    public override func read() {
        guard let subscription = self.subscribe(),
              let sample = IOReportCreateSamples(subscription, self.channels, nil)?.takeRetainedValue() else { return }
        defer { self.prev = sample }
        
        guard let prev = self.prev else {
            // first sample after (re)start: measure the next half second to show a value right away
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if let self, self.active { self.refresh() }
            }
            return
        }
        guard let delta = IOReportCreateSamplesDelta(prev, sample, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return }
        
        var eCores: [Double] = []
        var pCores: [Double] = []
        for item in items {
            guard let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String? else { continue }
            if channel.hasPrefix("ECPU") {
                eCores.append(self.frequency(item, freqs: self.eCoreFreqs))
            } else if channel.hasPrefix("PCPU") {
                pCores.append(self.frequency(item, freqs: self.pCoreFreqs))
            }
        }
        
        let eFreq = max(eCores.isEmpty ? 0 : eCores.reduce(0, +) / Double(eCores.count), Double(self.eCoreFreqs.min() ?? 0))
        let pFreq = max(pCores.isEmpty ? 0 : pCores.reduce(0, +) / Double(pCores.count), Double(self.pCoreFreqs.min() ?? 0))
        let value = (eFreq * self.eCoreCount + pFreq * self.pCoreCount) / max(self.eCoreCount + self.pCoreCount, 1)
        
        self.callback(CPU_Frequency(value: value, eCore: eFreq, pCore: pFreq))
    }
    
    // residency-weighted average of the active P-states
    private func frequency(_ item: CFDictionary, freqs: [Int32]) -> Double {
        let count = IOReportStateGetCount(item)
        var offset: Int32? = nil
        var residencies: [Int64] = []
        for i in 0..<count {
            if offset == nil {
                let name = IOReportStateGetNameForIndex(item, i)?.takeUnretainedValue() as String? ?? ""
                guard name != "IDLE" && name != "DOWN" && name != "OFF" else { continue }
                offset = i
            }
            residencies.append(IOReportStateGetResidency(item, i))
        }
        let total = residencies.reduce(0, +)
        guard total > 0 else { return 0 }
        return zip(residencies, freqs).reduce(0) { $0 + Double($1.0) / Double(total) * Double($1.1) }
    }
}

public class AverageLoadReader: Reader<CPU_AverageLoad> {
    public override func setup() {
        self.popup = true
        self.setInterval(15)
    }
    
    public override func read() {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) == 3 else { return }
        self.callback(CPU_AverageLoad(load1: averages[0], load5: averages[1], load15: averages[2]))
    }
}

internal func ioReportChannels(_ names: [(group: String, subgroup: String?)]) -> CFMutableDictionary? {
    let channels = names.compactMap { IOReportCopyChannelsInGroup($0.group as CFString, $0.subgroup as CFString?, 0, 0, 0)?.takeRetainedValue() }
    guard let first = channels.first else { return nil }
    channels.dropFirst().forEach { IOReportMergeChannels(first, $0, nil) }
    guard let channel = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(first), first),
          (channel as NSDictionary)["IOReportChannels"] != nil else { return nil }
    return channel
}
