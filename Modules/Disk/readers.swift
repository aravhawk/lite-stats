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

internal class CapacityReader: Reader<Disks> {
    private struct MountedVolume {
        let url: URL
        let BSDName: String
    }

    internal var list: Disks = Disks()
    private lazy var session: DASession? = DASessionCreate(kCFAllocatorDefault)
    private let volumeInventoryLock = NSLock()
    private var volumeInventoryDirty: Bool = true
    private var mountedVolumes: [MountedVolume] = []
    private var observingVolumes: Bool = false

    override func setup() {
        self.defaultInterval = 10
    }

    override func start() {
        self.startObservingVolumes()
        self.markVolumeInventoryDirty()
        super.start()
    }

    override func stop() {
        super.stop()
        self.stopObservingVolumes()
    }

    deinit {
        self.stopObservingVolumes()
    }

    private var SMART: Bool {
        Store.shared.bool(key: "\(ModuleType.disk.stringValue)_SMART", defaultValue: true)
    }
    private var purgableSpace: [URL: (Date, Int64)] = [:]
    private var smartCache: [String: (date: Date, value: smart_t?)] = [:]
    
    public override func read() {
        let removableState = Store.shared.bool(key: "Disk_removable", defaultValue: false)
        
        guard let session = self.session else {
            error("cannot create main DASessionCreate()", log: self.log)
            return
        }
        
        var active: [String] = []
        for volume in self.mountedVolumeSnapshot(session: session) {
            let BSDName = volume.BSDName
            active.append(BSDName)

            if let d = self.list.first(where: { $0.BSDName == BSDName}), let idx = self.list.index(where: { $0.BSDName == BSDName}) {
                if d.removable && !removableState {
                    self.list.remove(at: idx)
                    continue
                }

                if let path = d.path {
                    self.list.updateFreeSize(idx, newValue: self.freeDiskSpaceInBytes(path))
                    self.list.updateSMARTData(idx, smart: self.getSMARTDetails(for: BSDName))
                }

                continue
            }

            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume.url as CFURL),
                  var d = driveDetails(disk, removableState: removableState, includeParent: false) else {
                continue
            }

            if let path = d.path {
                d.free = self.freeDiskSpaceInBytes(path)
                d.size = self.totalDiskSpaceInBytes(path)
            }
            d.smart = self.getSMARTDetails(for: BSDName)
            guard d.size != 0 else { continue }
            self.list.append(d)
            self.list.sort()
        }
        
        active.difference(from: self.list.map{ $0.BSDName }).forEach { (BSDName: String) in
            if let idx = self.list.index(where: { $0.BSDName == BSDName }) {
                self.list.remove(at: idx)
            }
        }
        
        self.callback(self.list)
    }

    @objc private func markVolumeInventoryDirty() {
        self.volumeInventoryLock.lock()
        self.volumeInventoryDirty = true
        self.volumeInventoryLock.unlock()
    }

    private func startObservingVolumes() {
        guard !self.observingVolumes else { return }
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(self, selector: #selector(markVolumeInventoryDirty), name: NSWorkspace.didMountNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(markVolumeInventoryDirty), name: NSWorkspace.didUnmountNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(markVolumeInventoryDirty), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        self.observingVolumes = true
    }

    private func stopObservingVolumes() {
        guard self.observingVolumes else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        self.observingVolumes = false
    }

    private func mountedVolumeSnapshot(session: DASession) -> [MountedVolume] {
        self.volumeInventoryLock.lock()
        let dirty = self.volumeInventoryDirty
        let cached = self.mountedVolumes
        self.volumeInventoryLock.unlock()

        guard dirty || cached.isEmpty else { return cached }

        let keys: [URLResourceKey] = [.volumeNameKey]
        let paths = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes: [MountedVolume] = paths.compactMap { url in
            guard url.pathComponents.count == 1 || (url.pathComponents.count > 1 && url.pathComponents[1] == "Volumes"),
                  let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let diskName = DADiskGetBSDName(disk) else {
                return nil
            }
            return MountedVolume(url: url, BSDName: String(cString: diskName))
        }

        self.volumeInventoryLock.lock()
        self.mountedVolumes = volumes
        self.volumeInventoryDirty = false
        self.volumeInventoryLock.unlock()

        return volumes
    }
    
    private func freeDiskSpaceInBytes(_ path: URL) -> Int64 {
        var stat = statfs()
        if statfs(path.path, &stat) == 0 {
            var purgeable: Int64 = 0
            if self.purgableSpace[path] == nil {
                let value = CSDiskSpaceGetRecoveryEstimate(path as NSURL)
                purgeable = Int64(value)
                self.purgableSpace[path] = (Date(), purgeable)
            } else if let pair = self.purgableSpace[path] {
                let delta = Date().timeIntervalSince(pair.0)
                if delta > 30 {
                    let value = CSDiskSpaceGetRecoveryEstimate(path as NSURL)
                    purgeable = Int64(value)
                    self.purgableSpace[path] = (Date(), purgeable)
                } else {
                    purgeable = pair.1
                }
            }
            return (Int64(stat.f_bfree) * Int64(stat.f_bsize)) + Int64(purgeable)
        }
        
        do {
            if let url = URL(string: path.absoluteString) {
                let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity != 0 {
                    return capacity
                }
            }
        } catch let err {
            error("error retrieving free space #1: \(err.localizedDescription)", log: self.log)
        }
        
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: path.path)
            if let freeSpace = (systemAttributes[FileAttributeKey.systemFreeSize] as? NSNumber)?.int64Value {
                return freeSpace
            }
        } catch let err {
            error("error retrieving free space: \(err.localizedDescription)", log: self.log)
        }
        
        return 0
    }
    
    private func totalDiskSpaceInBytes(_ path: URL) -> Int64 {
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: path.path)
            if let totalSpace = (systemAttributes[FileAttributeKey.systemSize] as? NSNumber)?.int64Value {
                return totalSpace
            }
        } catch let err {
            error("error retrieving total space: \(err.localizedDescription)", log: self.log)
        }
        
        return 0
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
        
        var disk = IOServiceGetMatchingService(kIOMasterPortDefault, IOBSDNameMatching(kIOMasterPortDefault, 0, BSDName.cString(using: .utf8)))
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
        
        let temperatures: [UInt8] = [UInt8(smartData.temperature.1), UInt8(smartData.temperature.0)]
        var temperature: UInt16 = 0
        let data = NSData(bytes: temperatures, length: 2)
        data.getBytes(&temperature, length: 2)
        
        let dataUnitsRead = self.extractUInt128(smartData.data_units_read)
        let dataUnitsWritten = self.extractUInt128(smartData.data_units_written)
        let bytesPerDataUnit: Int64 = 512 * 1000
        
        let powerCycles = withUnsafeBytes(of: smartData.power_cycles) { $0.load(as: UInt32.self) }
        let powerOnHours = withUnsafeBytes(of: smartData.power_on_hours) { $0.load(as: UInt32.self) }
        
        return smart_t(
            temperature: Int(UInt16(bigEndian: temperature) - 273),
            life: 100 - Int(smartData.percent_used),
            totalRead: dataUnitsRead * bytesPerDataUnit,
            totalWritten: dataUnitsWritten * bytesPerDataUnit,
            powerCycles: Int(powerCycles),
            powerOnHours: Int(powerOnHours)
        )
    }
    
    private func extractUInt128(_ tuple: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> Int64 {
        let byteArray: [UInt8] = [
            tuple.0, tuple.1, tuple.2, tuple.3, tuple.4, tuple.5, tuple.6, tuple.7,
            tuple.8, tuple.9, tuple.10, tuple.11, tuple.12, tuple.13, tuple.14, tuple.15
        ]
        
        let uint64Value = byteArray.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) }
        let hasHigherBytes = byteArray.suffix(8).contains(where: { $0 != 0 })
        
        if hasHigherBytes || uint64Value > UInt64(Int64.max) {
            return Int64.max
        }
        
        return Int64(uint64Value)
    }
}

internal class ActivityReader: Reader<Disks> {
    internal var list: Disks = Disks()
    private lazy var session: DASession? = DASessionCreate(kCFAllocatorDefault)
    private let inventoryLock = NSLock()
    private var inventoryDirty = true
    private var lastInventoryRefresh: Date?
    private var lastRemovableState: Bool?
    private var lastStatsRead: [String: Date] = [:]
    private var observingVolumes: Bool = false
    
    override func setup() {
        self.setInterval(3)
    }

    override func start() {
        self.startObservingVolumes()
        self.markInventoryDirty()
        super.start()
    }

    override func stop() {
        super.stop()
        self.stopObservingVolumes()
    }
    
    override func terminate() {
        self.stopObservingVolumes()
    }

    public override func read() {
        let removableState = Store.shared.bool(key: "Disk_removable", defaultValue: false)
        let now = Date()

        if self.shouldRefreshInventory(removableState: removableState, now: now) {
            self.refreshInventory(removableState: removableState, now: now)
        }

        self.list.array.enumerated().forEach { (idx, disk) in
            self.driveStats(idx, disk, now: now)
        }

        self.callback(self.list)
    }

    @objc private func markInventoryDirty() {
        self.inventoryLock.lock()
        self.inventoryDirty = true
        self.inventoryLock.unlock()
    }

    private func startObservingVolumes() {
        guard !self.observingVolumes else { return }
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(self, selector: #selector(markInventoryDirty), name: NSWorkspace.didMountNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(markInventoryDirty), name: NSWorkspace.didUnmountNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(markInventoryDirty), name: NSWorkspace.didRenameVolumeNotification, object: nil)
        self.observingVolumes = true
    }

    private func stopObservingVolumes() {
        guard self.observingVolumes else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        self.observingVolumes = false
    }

    private func shouldRefreshInventory(removableState: Bool, now: Date) -> Bool {
        self.inventoryLock.lock()
        let inventoryDirty = self.inventoryDirty
        let lastInventoryRefresh = self.lastInventoryRefresh
        let lastRemovableState = self.lastRemovableState
        self.inventoryLock.unlock()

        if inventoryDirty || self.list.isEmpty || lastRemovableState != removableState {
            return true
        }
        guard let lastInventoryRefresh else { return true }
        return now.timeIntervalSince(lastInventoryRefresh) > 30
    }

    private func refreshInventory(removableState: Bool, now: Date) {
        let keys: [URLResourceKey] = [.volumeNameKey]
        let paths = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys)!
        
        guard let session = self.session else {
            error("cannot create a DASessionCreate()", log: self.log)
            return
        }
        
        var active: [String] = []
        for url in paths {
            if url.pathComponents.count == 1 || (url.pathComponents.count > 1 && url.pathComponents[1] == "Volumes") {
                if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) {
                    if let diskName = DADiskGetBSDName(disk) {
                        let BSDName: String = String(cString: diskName)
                        active.append(BSDName)
                        
                        if let d = self.list.first(where: { $0.BSDName == BSDName}), let idx = self.list.index(where: { $0.BSDName == BSDName}) {
                            if d.removable && !removableState {
                                self.list.remove(at: idx)
                                continue
                            }
                            
                            continue
                        }
                        
                        if let d = driveDetails(disk, removableState: removableState) {
                            self.list.append(d)
                            self.list.sort()
                        }
                    }
                }
            }
        }
        
        active.difference(from: self.list.map{ $0.BSDName }).forEach { (BSDName: String) in
            if let idx = self.list.index(where: { $0.BSDName == BSDName }) {
                self.list.remove(at: idx)
            }
        }
        let activeSet = Set(active)
        self.lastStatsRead = self.lastStatsRead.filter { activeSet.contains($0.key) }

        self.inventoryLock.lock()
        self.inventoryDirty = false
        self.lastInventoryRefresh = now
        self.lastRemovableState = removableState
        self.inventoryLock.unlock()
    }
    
    private func driveStats(_ idx: Int, _ d: drive, now: Date) {
        if let statistics = getIOProperty(d.parent, "Statistics") as? NSDictionary {
            let readBytes = statistics.object(forKey: "Bytes (Read)") as? Int64 ?? 0
            let writeBytes = statistics.object(forKey: "Bytes (Write)") as? Int64 ?? 0
            let elapsed = self.lastStatsRead[d.BSDName].map { now.timeIntervalSince($0) } ?? 0
            
            if d.activity.readBytes != 0 && elapsed > 0 {
                let read = ProcessSampler.bytesPerSecond(
                    current: UInt64(max(readBytes, 0)),
                    previous: UInt64(max(d.activity.readBytes, 0)),
                    elapsed: elapsed
                )
                self.list.updateRead(idx, newValue: Int64(read))
            }
            if d.activity.writeBytes != 0 && elapsed > 0 {
                let write = ProcessSampler.bytesPerSecond(
                    current: UInt64(max(writeBytes, 0)),
                    previous: UInt64(max(d.activity.writeBytes, 0)),
                    elapsed: elapsed
                )
                self.list.updateWrite(idx, newValue: Int64(write))
            }
            self.lastStatsRead[d.BSDName] = now
            
            self.list.updateReadWrite(idx, read: readBytes, write: writeBytes)
        }
        
        return
    }
}

private func driveDetails(_ disk: DADisk, removableState: Bool, includeParent: Bool = true) -> drive? {
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
    
    if includeParent {
        let partitionLevel = d.BSDName.filter { "0"..."9" ~= $0 }.count
        let media = DADiskCopyIOMedia(disk)
        if media != 0 {
            defer { IOObjectRelease(media) }
            if let parent = getDeviceIOParent(media, level: Int(partitionLevel)) {
                d.parent = parent
            }
        }
    }
    
    return d
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

struct io {
    var read: Int
    var write: Int
}

public class ProcessReader: Reader<[Disk_process]> {
    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(ModuleType.disk.stringValue)_processes", defaultValue: 5)
    }
    
    public override func setup() {
        self.popup = true
        self.setInterval(3)
    }
    
    public override func read() {
        let processes = ProcessSampler.shared.topDiskProcesses(limit: self.numberOfProcesses).map {
            Disk_process(pid: $0.pid, name: $0.name, read: $0.read, write: $0.write)
        }
        self.callback(processes)
    }
}
