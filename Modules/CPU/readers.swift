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
    private var cpuInfo: processor_info_array_t!
    private var prevCpuInfo: processor_info_array_t?
    private var numCpuInfo: mach_msg_type_number_t = 0
    private var numPrevCpuInfo: mach_msg_type_number_t = 0
    private var numCPUs: uint = 0
    private let CPUUsageLock: NSLock = NSLock()
    
    private var response: CPU_Load = CPU_Load()
    private var numCPUsU: natural_t = 0
    private var usagePerCore: [Double] = []
    private var cores: [core_s]? = nil
    private var eCoreIndices: [Int] = []
    private var pCoreIndices: [Int] = []
    
    public override func setup() {
        [CTL_HW, HW_NCPU].withUnsafeBufferPointer { mib in
            var sizeOfNumCPUs: size_t = MemoryLayout<uint>.size
            let status = sysctl(processor_info_array_t(mutating: mib.baseAddress), 2, &numCPUs, &sizeOfNumCPUs, nil, 0)
            if status != 0 {
                self.numCPUs = 1
            }
        }
        self.cores = SystemKit.shared.device.info.cpu?.cores
        if let cores = self.cores {
            self.eCoreIndices = cores.filter { $0.type == .efficiency }.compactMap { Int($0.id) }
            self.pCoreIndices = cores.filter { $0.type == .performance }.compactMap { Int($0.id) }
        }
    }
    
    public override func read() {
        let result: kern_return_t = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &self.numCPUsU, &self.cpuInfo, &self.numCpuInfo)
        if result == KERN_SUCCESS {
            self.CPUUsageLock.lock()
            self.usagePerCore = []
            var userTicks: Int64 = 0
            var systemTicks: Int64 = 0
            var niceTicks: Int64 = 0
            var idleTicks: Int64 = 0
            
            for i in 0 ..< Int32(numCPUs) {
                let base = Int(CPU_STATE_MAX * i)
                let user: Int64
                let system: Int64
                let nice: Int64
                let idle: Int64
                if let prevCpuInfo = self.prevCpuInfo {
                    user = Int64(self.cpuInfo[base + Int(CPU_STATE_USER)] - prevCpuInfo[base + Int(CPU_STATE_USER)])
                    system = Int64(self.cpuInfo[base + Int(CPU_STATE_SYSTEM)] - prevCpuInfo[base + Int(CPU_STATE_SYSTEM)])
                    nice = Int64(self.cpuInfo[base + Int(CPU_STATE_NICE)] - prevCpuInfo[base + Int(CPU_STATE_NICE)])
                    idle = Int64(self.cpuInfo[base + Int(CPU_STATE_IDLE)] - prevCpuInfo[base + Int(CPU_STATE_IDLE)])
                } else {
                    user = Int64(self.cpuInfo[base + Int(CPU_STATE_USER)])
                    system = Int64(self.cpuInfo[base + Int(CPU_STATE_SYSTEM)])
                    nice = Int64(self.cpuInfo[base + Int(CPU_STATE_NICE)])
                    idle = Int64(self.cpuInfo[base + Int(CPU_STATE_IDLE)])
                }

                let inUse = max(user, 0) + max(system, 0) + max(nice, 0)
                let total = inUse + max(idle, 0)
                
                if total != 0 {
                    self.usagePerCore.append(Double(inUse) / Double(total))
                }
                userTicks += max(user, 0)
                systemTicks += max(system, 0)
                niceTicks += max(nice, 0)
                idleTicks += max(idle, 0)
            }
            self.CPUUsageLock.unlock()
            
            self.response.usagePerCore = self.usagePerCore
            let totalTicks = Double(systemTicks + userTicks + niceTicks + idleTicks)
            if totalTicks > 0 {
                self.response.systemLoad = Double(systemTicks) / totalTicks
                self.response.userLoad = Double(userTicks) / totalTicks
                self.response.idleLoad = Double(idleTicks) / totalTicks
                self.response.totalUsage = self.response.systemLoad + self.response.userLoad
            }
            
            if let prevCpuInfo = self.prevCpuInfo {
                let prevCpuInfoSize: size_t = MemoryLayout<integer_t>.stride * Int(self.numPrevCpuInfo)
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prevCpuInfo), vm_size_t(prevCpuInfoSize))
            }
            
            self.prevCpuInfo = self.cpuInfo
            self.numPrevCpuInfo = self.numCpuInfo
            
            self.cpuInfo = nil
            self.numCpuInfo = 0
        } else {
            error("host_processor_info(): \(String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error")", log: self.log)
            self.callback(nil)
            return
        }
        
        if !self.eCoreIndices.isEmpty {
            var sum = 0.0
            var count = 0
            for idx in self.eCoreIndices where self.response.usagePerCore.indices.contains(idx) {
                sum += self.response.usagePerCore[idx]
                count += 1
            }
            self.response.usageECores = count > 0 ? (sum / Double(count)) : nil
        }
        if !self.pCoreIndices.isEmpty {
            var sum = 0.0
            var count = 0
            for idx in self.pCoreIndices where self.response.usagePerCore.indices.contains(idx) {
                sum += self.response.usagePerCore[idx]
                count += 1
            }
            self.response.usagePCores = count > 0 ? (sum / Double(count)) : nil
        }
        
        self.callback(self.response)
    }
}

public class ProcessReader: Reader<[TopProcess]> {
    private let title: String = "CPU"
    
    private var numberOfProcesses: Int {
        get { Store.shared.int(key: "\(self.title)_processes", defaultValue: 8) }
    }
    
    public override func setup() {
        self.popup = true
        self.setInterval(Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: 3))
    }
    
    public override func read() {
        let processes = ProcessSampler.shared.topCPUProcesses(limit: self.numberOfProcesses)
        self.callback(processes)
    }
}

public class TemperatureReader: Reader<Double> {
    var list: [String] = []
    
    public override func setup() {
        self.popup = true
        switch SystemKit.shared.device.platform {
        case .m1, .m1Pro, .m1Max, .m1Ultra:
            self.list = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        case .m2, .m2Pro, .m2Max, .m2Ultra:
        self.list = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        case .m3, .m3Pro, .m3Max, .m3Ultra:
            self.list = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        case .m4, .m4Pro, .m4Max, .m4Ultra:
            self.list = ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        default: break
        }
    }
    
    public override func read() {
        var temperature: Double? = nil
        
        if let value = SMC.shared.getValue("TC0D"), value < 110 {
            temperature = value
        } else if let value = SMC.shared.getValue("TC0E"), value < 110 {
            temperature = value
        } else if let value = SMC.shared.getValue("TC0F"), value < 110 {
            temperature = value
        } else if let value = SMC.shared.getValue("TC0P"), value < 110 {
            temperature = value
        } else if let value = SMC.shared.getValue("TC0H"), value < 110 {
            temperature = value
        } else {
            var total: Double = 0
            var counter: Double = 0
            self.list.forEach { (key: String) in
                if let value = SMC.shared.getValue(key) {
                    total += value
                    counter += 1
                }
            }
            if total != 0 && counter != 0 {
                temperature = total / counter
            }
        }
        
        self.callback(temperature)
    }
}

// inspired by https://github.com/shank03/StatsBar/blob/e175aa71c914ce882ce2e90163f3eb18262a8e25/StatsBar/Service/IOReport.swift
public class FrequencyReader: Reader<CPU_Frequency> {
    private var eCoreFreqs: [Int32] = []
    private var pCoreFreqs: [Int32] = []
    private var eCoreCount: Double = 0
    private var pCoreCount: Double = 0
    
    private var channels: CFMutableDictionary? = nil
    private var subscription: IOReportSubscriptionRef? = nil
    private var prev: (samples: CFDictionary, time: TimeInterval)? = nil
    private var sampleTask: Task<Void, Never>? = nil
    private let sampleTaskLock = NSLock()
    
    private let measurementCount: Int = 4
    private let isReadingQueue = DispatchQueue(label: "com.example.isReadingQueue")
    
    private var _isReading: Bool = false
    private var isReading: Bool {
        get { self.isReadingQueue.sync { self._isReading } }
        set { self.isReadingQueue.sync { self._isReading = newValue } }
    }
    
    private struct IOSample {
        let channel: String
        let delta: CFDictionary
    }
    
    public override func setup() {
        self.popup = true
        self.eCoreFreqs = SystemKit.shared.device.info.cpu?.eCoreFrequencies ?? []
        self.pCoreFreqs = SystemKit.shared.device.info.cpu?.pCoreFrequencies ?? []
        self.eCoreCount = Double(SystemKit.shared.device.info.cpu?.eCores ?? 0)
        self.pCoreCount = Double(SystemKit.shared.device.info.cpu?.pCores ?? 0)
        self.channels = self.getChannels()
        var dict: Unmanaged<CFMutableDictionary>?
        self.subscription = IOReportCreateSubscription(nil, self.channels, &dict, 0, nil)
        dict?.release()
    }
    
    public override func read() {
        guard !self.isReading, !self.eCoreFreqs.isEmpty && !self.pCoreFreqs.isEmpty, self.channels != nil, self.subscription != nil else { return }
        self.isReading = true
        let minECoreFreq = Double(self.eCoreFreqs.min() ?? 0)
        let minPCoreFreq = Double(self.pCoreFreqs.min() ?? 0)
        
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isReading = false
                self.sampleTaskLock.lock()
                self.sampleTask = nil
                self.sampleTaskLock.unlock()
            }

            var eCores: [Double] = []
            var pCores: [Double] = []
            
            for (samples, _) in await self.getSamples() {
                guard !Task.isCancelled else { return }
                var eCore: [Double] = []
                var pCore: [Double] = []
                
                for sample in samples {
                    if sample.channel.starts(with: "ECPU") {
                        eCore.append(self.calculateFrequencies(dict: sample.delta, freqs: self.eCoreFreqs))
                    }
                    if sample.channel.starts(with: "PCPU") {
                        pCore.append(self.calculateFrequencies(dict: sample.delta, freqs: self.pCoreFreqs))
                    }
                }
                
                let eCoresAvgFreq: Double = eCore.isEmpty ? 0 : (eCore.reduce(0.0, { $0 + $1 }) / Double(eCore.count))
                let pCoresAvgFreq: Double = pCore.isEmpty ? 0 : (pCore.reduce(0.0, { $0 + $1 }) / Double(pCore.count))
                eCores.append(max(eCoresAvgFreq, minECoreFreq))
                pCores.append(max(pCoresAvgFreq, minPCoreFreq))
            }
            
            let eFreq: Double = eCores.reduce(0, { $0 + $1 }) / Double(self.measurementCount)
            let pFreq: Double = pCores.reduce(0, { $0 + $1 }) / Double(self.measurementCount)
            let value: Double = ((eFreq * self.eCoreCount) + (pFreq * self.pCoreCount)) / (self.eCoreCount + self.pCoreCount)
            
            guard !Task.isCancelled else { return }
            self.callback(CPU_Frequency(value: value, eCore: eFreq, pCore: pFreq))
        }
        self.sampleTaskLock.lock()
        self.sampleTask = task
        self.sampleTaskLock.unlock()
    }

    public override func pause() {
        self.cancelSampleTask()
        super.pause()
    }

    public override func stop() {
        self.cancelSampleTask()
        super.stop()
    }

    public override func terminate() {
        self.cancelSampleTask()
    }
    
    private func calculateFrequencies(dict: CFDictionary, freqs: [Int32]) -> Double {
        let items = self.getResidencies(dict: dict)
        guard let offset = items.firstIndex(where: { $0.0 != "IDLE" && $0.0 != "DOWN" && $0.0 != "OFF" }) else { return 0 }
        let usage = items.dropFirst(offset).reduce(0.0) { $0 + Double($1.f) }
        let count = freqs.count
        var avgFreq: Double = 0
        
        for i in 0..<count {
            let key = i + offset
            if !items.indices.contains(key) { continue }
            let percent = usage == 0 ? 0 : Double(items[key].f) / usage
            avgFreq += percent * Double(freqs[i])
        }
        
        return avgFreq
    }
    
    func getResidencies(dict: CFDictionary) -> [(ns: String, f: Int64)] {
        let count = IOReportStateGetCount(dict)
        var res: [(String, Int64)] = []
        
        for i in 0..<count {
            let name = IOReportStateGetNameForIndex(dict, i)?.takeUnretainedValue() ?? ("" as CFString)
            let val = IOReportStateGetResidency(dict, i)
            res.append((name as String, val))
        }
        
        return res
    }
    
    private func getChannels() -> CFMutableDictionary? {
        let channelNames = [
            ("CPU Stats", "CPU Complex Performance States"),
            ("CPU Stats", "CPU Core Performance States")
        ]
        
        var channels: [CFDictionary] = []
        for (gname, sname) in channelNames {
            let channel = IOReportCopyChannelsInGroup(gname as CFString?, sname as CFString?, 0, 0, 0)
            guard let channel = channel?.takeRetainedValue() else { continue }
            channels.append(channel)
        }
        
        guard let chan = channels.first else { return nil }
        for channel in channels.dropFirst() {
            IOReportMergeChannels(chan, channel, nil)
        }
        
        let size = CFDictionaryGetCount(chan)
        guard let channel = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, chan),
              let chan = channel as? [String: Any], chan["IOReportChannels"] != nil else {
            return nil
        }
        
        return channel
    }
    
    private func getSamples() async -> [([IOSample], TimeInterval)] {
        let duration = 500
        let step = UInt64(duration / self.measurementCount)
        let tolerance = step == 0 ? UInt64(0) : max(UInt64(1), step / 10)
        let stepDuration = Duration.milliseconds(Int64(step))
        let toleranceDuration = Duration.milliseconds(Int64(tolerance))
        var samples = [([IOSample], TimeInterval)]()
        guard var prev = self.prev ?? self.getSample() else { return samples }
        
        for _ in 0..<self.measurementCount {
            do {
                try await Task.sleep(for: stepDuration, tolerance: toleranceDuration)
            } catch {
                if Task.isCancelled { return [] }
                continue
            }
            
            guard !Task.isCancelled else { return [] }
            guard let next = self.getSample() else { continue }
            
            if let diffCF = IOReportCreateSamplesDelta(prev.samples, next.samples, nil) {
                let diff = diffCF.takeRetainedValue()
                let elapsed = next.time - prev.time
                samples.append((self.collectIOSamples(data: diff), max(elapsed, TimeInterval(1))))
            }
            prev = next
        }
        
        self.prev = prev
        return samples
    }
    
    private func getSample() -> (samples: CFDictionary, time: TimeInterval)? {
        guard let sample = IOReportCreateSamples(self.subscription, self.channels, nil)?.takeRetainedValue() else {
            return nil
        }
        return (sample, Date().timeIntervalSince1970)
    }
    
    private func collectIOSamples(data: CFDictionary) -> [IOSample] {
        let dict = data as! [String: Any]
        let items = dict["IOReportChannels"] as! CFArray
        let itemSize = CFArrayGetCount(items)
        
        var samples = [IOSample]()
        
        for index in 0..<itemSize {
            let dict = CFArrayGetValueAtIndex(items, index)
            let item = unsafeBitCast(dict, to: CFDictionary.self)
            
            let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() ?? ("" as CFString)
            guard group as String == "CPU Stats" else { continue }
            let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() ?? ("" as CFString)
            
            samples.append(IOSample(channel: channel as String, delta: item))
        }
        
        return samples
    }

    private func cancelSampleTask() {
        self.sampleTaskLock.lock()
        let task = self.sampleTask
        self.sampleTask = nil
        self.sampleTaskLock.unlock()
        task?.cancel()
    }
}

public class AverageLoadReader: Reader<CPU_AverageLoad> {
    private let title: String = "CPU"
    private var load: CPU_AverageLoad = CPU_AverageLoad()
    
    public override func setup() {
        self.popup = true
        self.setInterval(15)
    }
    
    public override func read() {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, Int32(averages.count)) == Int32(averages.count) else { return }
        
        self.load.load1 = averages[0]
        self.load.load5 = averages[1]
        self.load.load15 = averages[2]
        
        self.callback(self.load)
    }
}
