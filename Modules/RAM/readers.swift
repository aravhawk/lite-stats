//
//  readers.swift
//  Memory
//
//  Created by Serhiy Mytrovtsiy on 12/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class UsageReader: Reader<RAM_Usage> {
    public var totalSize: Double = 0
    private var pressureMIB: [Int32] = []
    private var swapMIB: [Int32] = []
    
    public override func setup() {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &length, nil, 0)
        self.totalSize = Double(size)
        self.pressureMIB = mib("kern.memorystatus_vm_pressure_level")
        self.swapMIB = mib("vm.swapusage")
    }
    
    public override func read() {
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            error("host_statistics64(): \(String(cString: mach_error_string(result)))", log: self.log)
            return
        }
        
        let pageSize = Double(vm_kernel_page_size)
        let active = Double(stats.active_count) * pageSize
        let speculative = Double(stats.speculative_count) * pageSize
        let inactive = Double(stats.inactive_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let purgeable = Double(stats.purgeable_count) * pageSize
        let external = Double(stats.external_page_count) * pageSize
        let used = active + inactive + speculative + wired + compressed - purgeable - external
        
        var pressureLevel: Int32 = 0
        var length = MemoryLayout<Int32>.size
        sysctl(&self.pressureMIB, UInt32(self.pressureMIB.count), &pressureLevel, &length, nil, 0)
        let pressure: RAMPressure
        switch pressureLevel {
        case 2: pressure = .warning
        case 4: pressure = .critical
        default: pressure = .normal
        }
        
        var swap = xsw_usage()
        length = MemoryLayout<xsw_usage>.size
        sysctl(&self.swapMIB, UInt32(self.swapMIB.count), &swap, &length, nil, 0)
        
        self.callback(RAM_Usage(
            total: self.totalSize,
            used: used,
            free: self.totalSize - used,
            active: active,
            inactive: inactive,
            wired: wired,
            compressed: compressed,
            app: used - wired - compressed,
            cache: purgeable + external,
            swap: Swap(total: Double(swap.xsu_total), used: Double(swap.xsu_used), free: Double(swap.xsu_avail)),
            pressure: Pressure(level: Int(pressureLevel), value: pressure),
            swapins: Int64(stats.swapins),
            swapouts: Int64(stats.swapouts)
        ))
    }
}

private func mib(_ name: String) -> [Int32] {
    var mib = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
    var count = mib.count
    guard sysctlnametomib(name, &mib, &count) == 0 else { return [] }
    return Array(mib.prefix(count))
}

public class ProcessReader: Reader<[TopProcess]> {
    private let title: String = "RAM"
    
    private var numberOfProcesses: Int {
        get { Kit.numberOfProcesses(self.title, defaultValue: 8) }
    }
    
    private var combinedProcesses: Bool{
        get { Store.shared.bool(key: "\(self.title)_combinedProcesses", defaultValue: false) }
    }
    
    private typealias dynGetResponsiblePidFuncType = @convention(c) (CInt) -> CInt
    
    public override func setup() {
        self.popup = true
        self.blocking = true
        self.setInterval(Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: 3))
    }
    
    public override func read() {
        let processes = ProcessSampler.shared.topMemoryProcesses(
            limit: self.numberOfProcesses,
            responsiblePID: self.combinedProcesses ? ProcessReader.getResponsiblePid : nil
        )
        self.callback(processes)
    }
    
    private static let dynGetResponsiblePidFunc: UnsafeMutableRawPointer? = {
        let result = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid")
        if result == nil {
            error("Error loading responsibility_get_pid_responsible_for_pid")
        }
        return result
    }()
    
    static func getResponsiblePid(_ childPid: Int) -> Int {
        guard ProcessReader.dynGetResponsiblePidFunc != nil else {
            return childPid
        }
        let responsiblePid = unsafeBitCast(ProcessReader.dynGetResponsiblePidFunc, to: dynGetResponsiblePidFuncType.self)(CInt(childPid))
        guard responsiblePid != -1 else {
            return childPid
        }
        return Int(responsiblePid)
    }
}
