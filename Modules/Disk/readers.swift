//
//  readers.swift
//  Disk
//
//  Created by Serhiy Mytrovtsiy on 07/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import IOKit.storage
import CoreServices

let kIONVMeSMARTUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                                  0xAA, 0x0F, 0xA6, 0xF9,
                                                                  0xC2, 0xD6, 0x45, 0x7F,
                                                                  0xB1, 0x0B, 0x59, 0xA1,
                                                                  0x32, 0x53, 0x29, 0x2F
)
let kIONVMeSMARTInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                             0xCC, 0xD1, 0xDB, 0x19,
                                                             0xFD, 0x9A, 0x4D, 0xAF,
                                                             0xBF, 0x95, 0x12, 0x45,
                                                             0x4B, 0x23, 0x0A, 0xB6
)
let kIOCFPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                            0xC2, 0x44, 0xE8, 0x58,
                                                            0x10, 0x9C, 0x11, 0xD4,
                                                            0x91, 0xD4, 0x00, 0x50,
                                                            0xE4, 0xC6, 0x42, 0x6F
)

// Mounted volumes, refreshed only after a mount, unmount or rename notification.
private final class VolumeInventory {
    static let shared = VolumeInventory()
    
    struct Volume {
        let url: URL
        let BSDName: String
        let disk: DADisk
    }
    
    let session: DASession? = DASessionCreate(kCFAllocatorDefault)
    private let lock = NSLock()
    private var dirty: Bool = true
    private var cache: (generation: Int, volumes: [Volume]) = (0, [])
    
    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.dirty = true
                self.lock.unlock()
            }
        }
    }
    
    func volumes() -> (generation: Int, volumes: [Volume]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.dirty, let session = self.session else { return self.cache }
        
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let volumes: [Volume] = urls.compactMap { url in
            guard url.pathComponents.count == 1 || url.pathComponents[1] == "Volumes",
                  let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let name = DADiskGetBSDName(disk) else { return nil }
            return Volume(url: url, BSDName: String(cString: name), disk: disk)
        }
        self.cache = (self.cache.generation + 1, volumes)
        self.dirty = false
        return self.cache
    }
}

internal class CapacityReader: Reader<Disks> {
    private var list: Disks = Disks()
    private var purgeableCache: [URL: (date: Date, value: Int64)] = [:]
    private var smartCache: [String: (date: Date, value: smart_t?)] = [:]
    
    private var SMART: Bool {
        Store.shared.bool(key: "\(ModuleType.disk.stringValue)_SMART", defaultValue: true)
    }
    
    override func setup() {
        self.defaultInterval = 15
        self.blocking = true
    }
    
    public override func read() {
        let removableState = Store.shared.bool(key: "Disk_removable", defaultValue: false)
        var list = Disks()
        
        for volume in VolumeInventory.shared.volumes().volumes {
            var d: drive
            if let existing = self.list.first(where: { $0.BSDName == volume.BSDName }) {
                guard !existing.removable || removableState else { continue }
                d = existing
            } else {
                guard let details = driveDetails(volume.disk, removableState: removableState), let path = details.path else { continue }
                d = details
                d.size = self.totalDiskSpaceInBytes(path)
                guard d.size != 0 else { continue }
            }
            if let path = d.path {
                d.free = self.freeDiskSpaceInBytes(path)
            }
            d.smart = self.getSMARTDetails(for: volume.BSDName)
            list.append(d)
        }
        
        list.sort()
        self.list = list
        self.callback(list)
    }
    
    private func freeDiskSpaceInBytes(_ path: URL) -> Int64 {
        var stat = statfs()
        if statfs(path.path, &stat) == 0 {
            // the purgeable space estimate is expensive to compute and changes slowly
            let now = Date()
            var purgeable = self.purgeableCache[path]
            if purgeable == nil || now.timeIntervalSince(purgeable!.date) > 120 {
                purgeable = (now, Int64(CSDiskSpaceGetRecoveryEstimate(path as NSURL)))
                self.purgeableCache[path] = purgeable
            }
            return Int64(stat.f_bfree) * Int64(stat.f_bsize) + purgeable!.value
        }
        
        if let values = try? path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage, capacity != 0 {
            return capacity
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path.path),
           let freeSpace = (attributes[.systemFreeSize] as? NSNumber)?.int64Value {
            return freeSpace
        }
        error("error retrieving free space for \(path.path)", log: self.log)
        return 0
    }
    
    private func totalDiskSpaceInBytes(_ path: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path.path)
        return (attributes?[.systemSize] as? NSNumber)?.int64Value ?? 0
    }
    
    private func getSMARTDetails(for BSDName: String) -> smart_t? {
        guard self.SMART else { return nil }
        let now = Date()
        if let cached = self.smartCache[BSDName], now.timeIntervalSince(cached.date) < 300 {
            return cached.value
        }

        let value = self.readSMARTDetails(for: BSDName)
        self.smartCache[BSDName] = (now, value)
        return value
    }

    private func readSMARTDetails(for BSDName: String) -> smart_t? {
        
        var disk = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, BSDName.cString(using: .utf8)))
        guard disk != 0 else { return nil }
        defer { IOObjectRelease(disk) }
        
        while IOObjectConformsTo(disk, kIOBlockStorageDeviceClass) == 0 {
            var parent: io_registry_entry_t = 0
            let error = IORegistryEntryGetParentEntry(disk, kIOServicePlane, &parent)
            if error != kIOReturnSuccess || parent == 0 { return nil }
            IOObjectRelease(disk)
            disk = parent
        }
        
        guard IOObjectConformsTo(disk, kIOBlockStorageDeviceClass) > 0,
              let raw = IORegistryEntryCreateCFProperty(disk, "NVMe SMART Capable" as CFString, kCFAllocatorDefault, 0),
              let val = raw.takeRetainedValue() as? Bool, val else {
            return nil
        }
        
        var pluginInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var smartInterface: UnsafeMutablePointer<UnsafeMutablePointer<IONVMeSMARTInterface>?>?
        var score: Int32  = 0
        
        var result = IOCreatePlugInInterfaceForService(disk, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pluginInterface, &score)
        guard result == kIOReturnSuccess else { return nil }
        defer {
            if pluginInterface != nil {
                IODestroyPlugInInterface(pluginInterface)
            }
        }
        
        result = withUnsafeMutablePointer(to: &smartInterface) {
            $0.withMemoryRebound(to: Optional<LPVOID>.self, capacity: 1) {
                pluginInterface?.pointee?.pointee.QueryInterface(pluginInterface, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), $0) ?? KERN_NOT_FOUND
            }
        }
        
        guard result == kIOReturnSuccess else { return nil }
        defer {
            if smartInterface != nil {
                _ = pluginInterface?.pointee?.pointee.Release(smartInterface)
            }
        }
        
        guard let smart = smartInterface?.pointee else { return nil }
        var smartData: nvme_smart_log = nvme_smart_log()
        guard smart.pointee.SMARTReadData(smartInterface, &smartData) == kIOReturnSuccess else { return nil }
        
        // the values come from the device, so none of the conversions are allowed to trap
        let kelvin = Int(smartData.temperature.0) | Int(smartData.temperature.1) << 8
        let bytesPerDataUnit: Int64 = 512 * 1000
        func bytes(_ units: Int64) -> Int64 {
            let (value, overflow) = units.multipliedReportingOverflow(by: bytesPerDataUnit)
            return overflow ? Int64.max : value
        }
        
        let powerCycles = withUnsafeBytes(of: smartData.power_cycles) { $0.loadUnaligned(as: UInt32.self) }
        let powerOnHours = withUnsafeBytes(of: smartData.power_on_hours) { $0.loadUnaligned(as: UInt32.self) }
        
        return smart_t(
            temperature: kelvin > 273 ? kelvin - 273 : 0,
            life: max(100 - Int(smartData.percent_used), 0),
            totalRead: bytes(self.extractUInt128(smartData.data_units_read)),
            totalWritten: bytes(self.extractUInt128(smartData.data_units_written)),
            powerCycles: Int(powerCycles),
            powerOnHours: Int(powerOnHours)
        )
    }
    
    // little-endian 128-bit counter, saturated to Int64
    private func extractUInt128(_ tuple: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> Int64 {
        withUnsafeBytes(of: tuple) { bytes in
            let low = bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self).littleEndian
            let high = bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            return high != 0 || low > UInt64(Int64.max) ? Int64.max : Int64(low)
        }
    }
}

internal class ActivityReader: Reader<Disks> {
    private var list: Disks = Disks()
    private var parents: [String: io_registry_entry_t] = [:]
    private var inventory: (generation: Int, removable: Bool)? = nil
    private var lastStatsRead: [String: Date] = [:]
    
    override func setup() {
        self.popup = true
        self.blocking = true
        self.setInterval(3)
    }
    
    deinit {
        self.parents.values.forEach { IOObjectRelease($0) }
    }
    
    public override func read() {
        let removableState = Store.shared.bool(key: "Disk_removable", defaultValue: false)
        let (generation, volumes) = VolumeInventory.shared.volumes()
        if self.inventory?.generation != generation || self.inventory?.removable != removableState {
            self.refreshInventory(volumes, removableState: removableState)
            self.inventory = (generation, removableState)
        }
        
        let now = Date()
        for i in self.list.array.indices {
            self.driveStats(&self.list.array[i], now: now)
        }
        
        self.callback(self.list)
    }
    
    private func refreshInventory(_ volumes: [VolumeInventory.Volume], removableState: Bool) {
        var list = Disks()
        var parents: [String: io_registry_entry_t] = [:]
        
        for volume in volumes {
            if let existing = self.list.first(where: { $0.BSDName == volume.BSDName }), let parent = self.parents.removeValue(forKey: volume.BSDName) {
                guard !existing.removable || removableState else {
                    IOObjectRelease(parent)
                    continue
                }
                list.append(existing)
                parents[volume.BSDName] = parent
            } else if let d = driveDetails(volume.disk, removableState: removableState), let parent = ioParent(volume.disk, BSDName: d.BSDName) {
                list.append(d)
                parents[volume.BSDName] = parent
            }
        }
        
        self.parents.values.forEach { IOObjectRelease($0) }
        self.parents = parents
        list.sort()
        self.list = list
        self.lastStatsRead = self.lastStatsRead.filter { parents[$0.key] != nil }
    }
    
    private func driveStats(_ d: inout drive, now: Date) {
        guard let parent = self.parents[d.BSDName], let statistics = getIOProperty(parent, "Statistics") as? NSDictionary else { return }
        let readBytes = statistics.object(forKey: "Bytes (Read)") as? Int64 ?? 0
        let writeBytes = statistics.object(forKey: "Bytes (Write)") as? Int64 ?? 0
        
        if let last = self.lastStatsRead[d.BSDName], now > last {
            let elapsed = now.timeIntervalSince(last)
            d.activity.read = Int64(ProcessSampler.bytesPerSecond(current: UInt64(max(readBytes, 0)), previous: UInt64(max(d.activity.readBytes, 0)), elapsed: elapsed))
            d.activity.write = Int64(ProcessSampler.bytesPerSecond(current: UInt64(max(writeBytes, 0)), previous: UInt64(max(d.activity.writeBytes, 0)), elapsed: elapsed))
        }
        self.lastStatsRead[d.BSDName] = now
        d.activity.readBytes = readBytes
        d.activity.writeBytes = writeBytes
    }
}

private func driveDetails(_ disk: DADisk, removableState: Bool) -> drive? {
    var d: drive = drive()
    
    if let bsdName = DADiskGetBSDName(disk) {
        d.BSDName = String(cString: bsdName)
    }
    
    if let diskDescription = DADiskCopyDescription(disk) {
        if let dict = diskDescription as? [String: AnyObject] {
            if let removable = dict[kDADiskDescriptionMediaRemovableKey as String] {
                if removable as! Bool {
                    if !removableState {
                        return nil
                    }
                    d.removable = true
                }
            }
            
            if let mediaUUID = dict[kDADiskDescriptionMediaUUIDKey as String] {
                d.uuid = CFUUIDCreateString(kCFAllocatorDefault, (mediaUUID as! CFUUID)) as String
            }
            if let mediaName = dict[kDADiskDescriptionVolumeNameKey as String] {
                d.mediaName = mediaName as! String
                if d.mediaName == "Recovery" {
                    return nil
                }
            }
            if d.mediaName == "" {
                if let mediaName = dict[kDADiskDescriptionMediaNameKey as String] {
                    d.mediaName = mediaName as! String
                    if d.mediaName == "Recovery" {
                        return nil
                    }
                }
            }
            if let deviceModel = dict[kDADiskDescriptionDeviceModelKey as String] {
                d.model = (deviceModel as! String).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let deviceProtocol = dict[kDADiskDescriptionDeviceProtocolKey as String] {
                d.connectionType = deviceProtocol as! String
            }
            if let volumePath = dict[kDADiskDescriptionVolumePathKey as String] {
                if let url = volumePath as? NSURL {
                    d.path = url as URL
                    
                    if let components = url.pathComponents {
                        d.root = components.count == 1
                        
                        if components.count > 1 && components[1] == "Volumes" {
                            if let name: String = url.lastPathComponent, name != "" {
                                d.mediaName = name
                            }
                        }
                    }
                }
            }
            if let volumeKind = dict[kDADiskDescriptionVolumeKindKey as String] {
                d.fileSystem = volumeKind as! String
            }
        }
    }
    
    if d.path == nil {
        return nil
    }
    if d.uuid == "" || d.uuid == "00000000-0000-0000-0000-000000000000" {
        d.uuid = d.BSDName
    }
    
    return d
}

// the physical device of a volume, where the read/write statistics are kept
private func ioParent(_ disk: DADisk, BSDName: String) -> io_registry_entry_t? {
    let media = DADiskCopyIOMedia(disk)
    guard media != 0 else { return nil }
    defer { IOObjectRelease(media) }
    return getDeviceIOParent(media, level: BSDName.filter { "0"..."9" ~= $0 }.count)
}

// https://opensource.apple.com/source/bless/bless-152/libbless/APFS/BLAPFSUtilities.c.auto.html
public func getDeviceIOParent(_ obj: io_registry_entry_t, level: Int) -> io_registry_entry_t? {
    guard obj != 0 else { return nil }

    var current = obj
    let steps = max(level, 0)

    for _ in 0...steps {
        var parent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS || parent == 0 {
            if current != obj {
                IOObjectRelease(current)
            }
            return nil
        }
        if current != obj {
            IOObjectRelease(current)
        }
        current = parent
    }

    return current
}

public class ProcessReader: Reader<[Disk_process]> {
    private var numberOfProcesses: Int {
        Kit.numberOfProcesses(ModuleType.disk.stringValue, defaultValue: 5)
    }
    
    public override func setup() {
        self.popup = true
        self.blocking = true
        self.setInterval(3)
    }
    
    public override func read() {
        let processes = ProcessSampler.shared.topDiskProcesses(limit: self.numberOfProcesses).map {
            Disk_process(pid: $0.pid, name: $0.name, read: $0.read, write: $0.write)
        }
        self.callback(processes)
    }
}
