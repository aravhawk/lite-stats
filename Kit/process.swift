//
//  process.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 05/01/2024
//  Using Swift 5.0
//  Running on macOS 14.3
//
//  Copyright © 2024 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Darwin

public protocol Process_p {
    var pid: Int { get }
    var name: String { get }
    var icon: NSImage { get }
}

public typealias ProcessHeader = (title: String, color: NSColor?)

public struct DiskProcessUsage {
    public let pid: Int
    public let name: String
    public let read: Int
    public let write: Int
}

public final class ProcessSampler {
    public static let shared = ProcessSampler()

    public struct Snapshot {
        public let pid: Int
        public let name: String
        public let cpuTime: UInt64
        public let residentSize: UInt64
        public let readBytes: UInt64
        public let writtenBytes: UInt64
        public let startTime: UInt64
    }

    private struct PreviousCPU {
        let cpuTime: UInt64
        let startTime: UInt64
    }

    private struct PreviousDisk {
        let readBytes: UInt64
        let writtenBytes: UInt64
        let startTime: UInt64
    }

    private struct RawSnapshot {
        let pid: Int
        let cpuTime: UInt64
        let residentSize: UInt64
        let readBytes: UInt64
        let writtenBytes: UInt64
        let startTime: UInt64
    }

    private let queue = DispatchQueue(label: "com.aravhawk.lite-stats.processSampler")
    private var cpuPrevious: [Int: PreviousCPU] = [:]
    private var cpuPreviousTime: TimeInterval? = nil
    private var diskPrevious: [Int: PreviousDisk] = [:]
    private var diskPreviousTime: TimeInterval? = nil
    private var nameCache: [Int: (name: String, startTime: UInt64)] = [:]
    private var cachedSnapshots: (time: TimeInterval, snapshots: [RawSnapshot])?
    private var pidBuffer: [pid_t] = []
    private let snapshotCacheTTL: TimeInterval = 0.35

    public func topCPUProcesses(limit: Int) -> [TopProcess] {
        guard limit > 0 else { return [] }

        return self.queue.sync {
            let now = Date().timeIntervalSinceReferenceDate
            let snapshots = self.sampleProcessesLocked(now: now)
            let previous = self.cpuPrevious
            let previousTime = self.cpuPreviousTime

            self.cpuPrevious = Dictionary(uniqueKeysWithValues: snapshots.map {
                ($0.pid, PreviousCPU(cpuTime: $0.cpuTime, startTime: $0.startTime))
            })
            self.cpuPreviousTime = now
            self.pruneNameCacheIfNeeded(snapshots: snapshots)

            guard let previousTime, now > previousTime else { return [] }
            let elapsed = now - previousTime

            let candidates = snapshots.compactMap { snapshot -> (snapshot: RawSnapshot, usage: Double)? in
                guard let old = previous[snapshot.pid], old.startTime == snapshot.startTime else { return nil }
                let usage = ProcessSampler.cpuUsagePercent(
                    current: snapshot.cpuTime,
                    previous: old.cpuTime,
                    elapsed: elapsed
                )
                guard usage > 0 else { return nil }
                return (snapshot, usage)
            }
            .sorted { $0.usage > $1.usage }
            .prefix(limit)

            return candidates.map {
                TopProcess(pid: $0.snapshot.pid, name: self.name(for: $0.snapshot.pid, startTime: $0.snapshot.startTime), usage: $0.usage)
            }
        }
    }

    public func topMemoryProcesses(limit: Int, responsiblePID: ((Int) -> Int)? = nil) -> [TopProcess] {
        guard limit > 0 else { return [] }

        return self.queue.sync {
            let now = Date().timeIntervalSinceReferenceDate
            let snapshots = self.sampleProcessesLocked(now: now)
            self.pruneNameCacheIfNeeded(snapshots: snapshots)

            guard let responsiblePID else {
                return snapshots
                    .sorted { $0.residentSize > $1.residentSize }
                    .prefix(limit)
                    .map { TopProcess(pid: $0.pid, name: self.name(for: $0.pid, startTime: $0.startTime), usage: Double($0.residentSize)) }
            }

            let snapshotsByPID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
            var grouped: [Int: UInt64] = [:]

            snapshots.forEach { snapshot in
                let pid = responsiblePID(snapshot.pid)
                grouped[pid, default: 0] += snapshot.residentSize
            }

            return grouped.map { (pid: $0.key, residentSize: $0.value) }
                .sorted { $0.residentSize > $1.residentSize }
                .prefix(limit)
                .map {
                    let snapshot = snapshotsByPID[$0.pid]
                    return TopProcess(
                        pid: $0.pid,
                        name: self.name(for: $0.pid, startTime: snapshot?.startTime),
                        usage: Double($0.residentSize)
                    )
                }
        }
    }

    public func topDiskProcesses(limit: Int) -> [DiskProcessUsage] {
        guard limit > 0 else { return [] }

        return self.queue.sync {
            let now = Date().timeIntervalSinceReferenceDate
            let snapshots = self.sampleProcessesLocked(now: now)
            let previous = self.diskPrevious
            let previousTime = self.diskPreviousTime

            self.diskPrevious = Dictionary(uniqueKeysWithValues: snapshots.map {
                ($0.pid, PreviousDisk(readBytes: $0.readBytes, writtenBytes: $0.writtenBytes, startTime: $0.startTime))
            })
            self.diskPreviousTime = now
            self.pruneNameCacheIfNeeded(snapshots: snapshots)

            guard let previousTime, now > previousTime else { return [] }
            let elapsed = now - previousTime

            let candidates = snapshots.compactMap { snapshot -> (snapshot: RawSnapshot, read: Int, write: Int)? in
                guard let old = previous[snapshot.pid], old.startTime == snapshot.startTime else { return nil }
                let read = ProcessSampler.bytesPerSecond(current: snapshot.readBytes, previous: old.readBytes, elapsed: elapsed)
                let write = ProcessSampler.bytesPerSecond(current: snapshot.writtenBytes, previous: old.writtenBytes, elapsed: elapsed)
                guard read != 0 || write != 0 else { return nil }
                return (snapshot, read, write)
            }
            .sorted {
                let firstMax = max($0.read, $0.write)
                let secondMax = max($1.read, $1.write)
                let firstMin = min($0.read, $0.write)
                let secondMin = min($1.read, $1.write)

                if firstMax == secondMax && firstMin != secondMin {
                    return firstMin > secondMin
                }
                return firstMax > secondMax
            }
            .prefix(limit)

            return candidates.map {
                DiskProcessUsage(
                    pid: $0.snapshot.pid,
                    name: self.name(for: $0.snapshot.pid, startTime: $0.snapshot.startTime),
                    read: $0.read,
                    write: $0.write
                )
            }
        }
    }

    static func cpuUsagePercent(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double {
        guard current > previous, elapsed > 0 else { return 0 }
        return (Double(current - previous) / 1_000_000_000 / elapsed) * 100
    }

    private static func saturatingInt(_ value: UInt64) -> Int {
        Int(min(value, UInt64(Int.max)))
    }

    public static func bytesPerSecond(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Int {
        guard current > previous, elapsed > 0 else { return 0 }
        return saturatingInt(UInt64(Double(current - previous) / elapsed))
    }

    private func sampleProcessesLocked(now: TimeInterval) -> [RawSnapshot] {
        if let cachedSnapshots, now - cachedSnapshots.time < self.snapshotCacheTTL {
            return cachedSnapshots.snapshots
        }

        let estimated = max(Int(proc_listallpids(nil, 0)), 1024)
        if self.pidBuffer.count < estimated + 256 {
            self.pidBuffer = [pid_t](repeating: 0, count: estimated + 256)
        }

        let result = self.pidBuffer.withUnsafeMutableBytes { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard result > 0 else { return [] }

        let count = min(Int(result), self.pidBuffer.count)
        var snapshots: [RawSnapshot] = []
        snapshots.reserveCapacity(count)

        for idx in 0..<count {
            let pid = self.pidBuffer[idx]
            guard pid > 0, let usage = self.rusage(pid) else { continue }
            snapshots.append(RawSnapshot(
                pid: Int(pid),
                cpuTime: usage.ri_user_time + usage.ri_system_time,
                residentSize: usage.ri_resident_size,
                readBytes: usage.ri_diskio_bytesread,
                writtenBytes: usage.ri_diskio_byteswritten,
                startTime: usage.ri_proc_start_abstime
            ))
        }

        self.cachedSnapshots = (now, snapshots)
        return snapshots
    }

    private func rusage(_ pid: pid_t) -> rusage_info_current? {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: (rusage_info_t?.self), capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result != -1 else { return nil }
        return usage
    }

    private func name(for pid: Int, startTime: UInt64?) -> String {
        if let startTime, let cached = self.nameCache[pid], cached.startTime == startTime {
            return cached.name
        }

        let name: String
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let localizedName = app.localizedName {
            name = localizedName
        } else if let pathName = self.pathName(for: pid) {
            name = pathName
        } else {
            name = self.procName(for: pid) ?? "\(pid)"
        }

        if let startTime {
            self.nameCache[pid] = (name, startTime)
        }
        return name
    }

    private func procName(for pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let result = proc_name(Int32(pid), &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private func pathName(for pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        let path = String(cString: buffer)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private func pruneNameCacheIfNeeded(snapshots: [RawSnapshot]) {
        guard self.nameCache.count > 256 else { return }
        let activePIDs = Set(snapshots.map(\.pid))
        self.nameCache = self.nameCache.filter { activePIDs.contains($0.key) }
    }
}

public class ProcessesView: NSStackView {
    public var count: Int {
        self.list.count
    }
    private var list: [ProcessView] = []
    private var colorViews: [ColorView] = []

    public init(frame: NSRect, values: [ProcessHeader], n: Int = 0) {
        super.init(frame: frame)

        self.orientation = .vertical
        self.spacing = 0

        let header = self.generateHeaderView(values)
        self.addArrangedSubview(header)

        for _ in 0..<n {
            let view = ProcessView(n: values.count)
            self.addArrangedSubview(view)
            self.list.append(view)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func generateHeaderView(_ values: [ProcessHeader]) -> NSView {
        let view = NSStackView()
        view.widthAnchor.constraint(equalToConstant: self.bounds.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: ProcessView.height).isActive = true
        view.orientation = .horizontal
        view.distribution = .fillProportionally
        view.spacing = 0

        let iconView: NSImageView = NSImageView()
        iconView.widthAnchor.constraint(equalToConstant: ProcessView.height).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: ProcessView.height).isActive = true
        view.addArrangedSubview(iconView)

        let titleField = LabelField()
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.toolTip = localizedString("Process")
        titleField.stringValue = localizedString("Process")
        titleField.textColor = .tertiaryLabelColor
        titleField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        view.addArrangedSubview(titleField)

        if values.count == 1, let v = values.first {
            let field = LabelField()
            field.cell?.truncatesLastVisibleLine = true
            field.toolTip = v.title
            field.stringValue = v.title
            field.alignment = .right
            field.textColor = .tertiaryLabelColor
            field.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            view.addArrangedSubview(field)
        } else {
            for v in values {
                if let color = v.color {
                    let container: NSView = NSView()
                    container.widthAnchor.constraint(equalToConstant: 60).isActive = true
                    container.heightAnchor.constraint(equalToConstant: ProcessView.height).isActive = true
                    let colorBlock: ColorView = ColorView(frame: NSRect(x: 48, y: 5, width: 12, height: 12), color: color, state: true, radius: 4)
                    colorBlock.toolTip = v.title
                    colorBlock.widthAnchor.constraint(equalToConstant: 12).isActive = true
                    colorBlock.heightAnchor.constraint(equalToConstant: 12).isActive = true
                    self.colorViews.append(colorBlock)
                    container.addSubview(colorBlock)
                    view.addArrangedSubview(container)
                }
            }
        }

        return view
    }

    public func setLock(_ newValue: Bool) {
        self.list.forEach{ $0.setLock(newValue) }
    }

    public func clear(_ symbol: String = "") {
        self.list.forEach{ $0.clear(symbol) }
    }

    public func set(_ idx: Int, _ process: Process_p, _ values: [String]) {
        if self.list.indices.contains(idx) {
            self.list[idx].set(process, values)
        }
    }

    public func setColor(_ idx: Int, _ newColor: NSColor) {
        if self.colorViews.indices.contains(idx) {
            self.colorViews[idx].setColor(newColor)
        }
    }
}

public class ProcessView: NSStackView {
    static let height: CGFloat = 22

    private var pid: Int? = nil
    private var lock: Bool = false

    private var imageView: NSImageView = NSImageView()
    private var killView: NSButton = NSButton()
    private var labelView: LabelField = {
        let view = LabelField()
        view.cell?.truncatesLastVisibleLine = true
        return view
    }()
    private var valueViews: [ValueField] = []

    public init(size: CGSize = CGSize(width: 264, height: 22), n: Int = 1) {
        var rect = NSRect(x: 2, y: 5, width: 12, height: 12)
        if size.height != 22 {
            rect = NSRect(x: 1, y: 3, width: 12, height: 12)
        }
        self.imageView = NSImageView(frame: rect)
        self.killView = NSButton(frame: rect)

        super.init(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))

        self.wantsLayer = true
        self.orientation = .horizontal
        self.distribution = .fillProportionally
        self.spacing = 0
        self.layer?.cornerRadius = 3

        let imageBox: NSView = {
            let view = NSView()

            self.killView.bezelStyle = .regularSquare
            self.killView.translatesAutoresizingMaskIntoConstraints = false
            self.killView.imageScaling = .scaleNone
            self.killView.image = Bundle(for: type(of: self)).image(forResource: "cancel")!
            self.killView.contentTintColor = .lightGray
            self.killView.isBordered = false
            self.killView.action = #selector(self.kill)
            self.killView.target = self
            self.killView.toolTip = localizedString("Kill process")
            self.killView.focusRingType = .none
            self.killView.isHidden = true

            view.addSubview(self.imageView)
            view.addSubview(self.killView)

            return view
        }()

        self.addArrangedSubview(imageBox)
        self.addArrangedSubview(self.labelView)
        self.valuesViews(n).forEach{ self.addArrangedSubview($0) }

        self.addTrackingArea(NSTrackingArea(
            rect: NSRect(x: 0, y: 0, width: self.frame.width, height: self.frame.height),
            options: [NSTrackingArea.Options.activeAlways, NSTrackingArea.Options.mouseEnteredAndExited, NSTrackingArea.Options.activeInActiveApp],
            owner: self,
            userInfo: nil
        ))

        NSLayoutConstraint.activate([
            imageBox.widthAnchor.constraint(equalToConstant: self.bounds.height),
            imageBox.heightAnchor.constraint(equalToConstant: self.bounds.height),
            self.labelView.heightAnchor.constraint(equalToConstant: 16),
            self.widthAnchor.constraint(equalToConstant: self.bounds.width),
            self.heightAnchor.constraint(equalToConstant: self.bounds.height)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func valuesViews(_ n: Int) -> [NSView] {
        var list: [ValueField] = []

        for _ in 0..<n {
            let view: ValueField = ValueField()
            view.widthAnchor.constraint(equalToConstant: 68).isActive = true
            if n != 1 {
                view.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            }
            list.append(view)
        }

        self.valueViews = list
        return list
    }

    public override func mouseEntered(with: NSEvent) {
        if self.lock {
            self.imageView.isHidden = true
            self.killView.isHidden = false
            return
        }
        self.layer?.backgroundColor = .init(gray: 0.01, alpha: 0.05)
    }

    public override func mouseExited(with: NSEvent) {
        if self.lock {
            self.imageView.isHidden = false
            self.killView.isHidden = true
            return
        }
        self.layer?.backgroundColor = .none
    }

    public override func mouseDown(with: NSEvent) {
        self.setLock(!self.lock)
    }

    fileprivate func set(_ process: Process_p, _ values: [String]) {
        if self.lock && process.pid != self.pid { return }

        let processChanged = self.pid != process.pid || self.labelView.stringValue != process.name
        if processChanged {
            self.labelView.stringValue = process.name
            self.imageView.image = process.icon
            self.pid = process.pid
        }
        values.enumerated().forEach {
            guard self.valueViews.indices.contains($0.offset),
                  self.valueViews[$0.offset].stringValue != $0.element else {
                return
            }
            self.valueViews[$0.offset].stringValue = $0.element
        }
        let tooltip = "pid: \(process.pid)"
        if self.toolTip != tooltip {
            self.toolTip = tooltip
        }
    }

    fileprivate func clear(_ symbol: String = "") {
        if self.labelView.stringValue != symbol {
            self.labelView.stringValue = symbol
        }
        self.valueViews.forEach {
            if $0.stringValue != symbol {
                $0.stringValue = symbol
            }
        }
        if self.imageView.image != nil {
            self.imageView.image = nil
        }
        self.pid = nil
        self.setLock(false)
        if self.toolTip != symbol {
            self.toolTip = symbol
        }
    }

    fileprivate func setLock(_ state: Bool) {
        guard self.lock != state else { return }
        self.lock = state
        if self.lock {
            self.imageView.isHidden = true
            self.killView.isHidden = false
            self.layer?.backgroundColor = .init(gray: 0.01, alpha: 0.1)
        } else {
            self.imageView.isHidden = false
            self.killView.isHidden = true
            self.layer?.backgroundColor = .none
        }
    }

    @objc private func kill() {
        guard let pid = self.pid else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = Darwin.kill(pid_t(pid), SIGTERM)
        }
    }
}
