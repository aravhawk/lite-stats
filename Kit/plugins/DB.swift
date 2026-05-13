//
//  DB.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 03/02/2024
//  Using Swift 5.0
//  Running on macOS 14.3
//
//  Copyright © 2024 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

public class DB {
    public static let shared = DB()
    
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.aravhawk.lite-stats.db")
    private let ttl: Int = 60*60
    private let keyPrefix = "db."
    
    private var writeTS: [String: Date] = [:]
    private var cleanupTS: [String: Date] = [:]
    private var values: [String: Codable] = [:]
    
    init() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.aravhawk.lite-stats"
        self.defaults = UserDefaults(suiteName: "\(bundleId).db") ?? .standard
        self.cleanupLegacyStore()
    }
    
    private func storageKey(_ key: String) -> String {
        return "\(self.keyPrefix)\(key)"
    }

    private func cleanupLegacyStore() {
        let fileManager = FileManager.default
        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        
        let legacyFolders = [
            supportRoot?.appendingPathComponent("Lite Stats").appendingPathComponent("lldb"),
            tempRoot.appendingPathComponent("Lite Stats").appendingPathComponent("lldb")
        ].compactMap { $0 }
        
        legacyFolders.forEach { url in
            guard fileManager.fileExists(atPath: url.path) else { return }
            try? fileManager.removeItem(at: url)
            
            let parent = url.deletingLastPathComponent()
            if let contents = try? fileManager.contentsOfDirectory(atPath: parent.path), contents.isEmpty {
                try? fileManager.removeItem(at: parent)
            }
        }
    }
    
    private func setValue(_ value: Codable, for key: String) {
        self.queue.sync {
            self.values[key] = value
        }
    }
    
    private func getValue<T>(for key: String, type: T.Type) -> T? {
        return self.queue.sync {
            return self.values[key] as? T
        }
    }
    
    private func getWriteTS(for key: String) -> Date? {
        return self.queue.sync {
            return self.writeTS[key]
        }
    }
    
    private func setWriteTS(_ date: Date, for key: String) {
        self.queue.sync {
            self.writeTS[key] = date
        }
    }

    private func shouldClean(_ key: String, now: Date) -> Bool {
        self.queue.sync {
            if let cleanupTS = self.cleanupTS[key], now.timeIntervalSince(cleanupTS) < 600 {
                return false
            }
            self.cleanupTS[key] = now
            return true
        }
    }
    
    public func setup<T: Codable>(_ type: T.Type, _ key: String) {
        if let data = self.defaults.data(forKey: self.storageKey(key)),
           let value = try? JSONDecoder().decode(type, from: data) {
            self.setValue(value, for: key)
        }
    }
    
    public func insert(key: String, value: Codable, ts: Bool = true, force: Bool = false) {
        self.setValue(value, for: key)
        let now = Date()
        if !force, let ts = self.getWriteTS(for: key), now.timeIntervalSince(ts) < 30 { return }

        guard let blobData = try? JSONEncoder().encode(value) else { return }
        
        if ts {
            if self.shouldClean(key, now: now) {
                self.clean(key)
            }
            self.defaults.set(blobData, forKey: self.storageKey("\(key)@\(now.currentTimeSeconds())"))
        }
        
        self.defaults.set(blobData, forKey: self.storageKey(key))
        self.setWriteTS(now, for: key)
    }
    
    public func findOne<T: Decodable>(_ dynamicType: T.Type, key: String) -> T? {
        return self.getValue(for: key, type: T.self)
    }
    
    private func clean(_ key: String) {
        let prefix = self.storageKey("\(key)@")
        let maxLiveTS = Date().currentTimeSeconds() - self.ttl
        var toDeleteKeys: [String] = []
        
        let keys = self.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        keys.forEach { (key: String) in
            guard let ts = key.split(separator: "@").last, let ts = Int(ts) else { return }
            if ts < maxLiveTS { toDeleteKeys.append(key) }
        }
        
        toDeleteKeys.forEach { self.defaults.removeObject(forKey: $0) }
    }
}
