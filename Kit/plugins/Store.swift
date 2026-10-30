//
//  store.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 10/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public class Store {
    public static let shared = Store()
    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var cache: [String: Any] = [:]
    
    // incremented on every change, lets hot paths cache values derived from settings
    private var _generation: Int = 0
    public var generation: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._generation
    }
    
    public init() {
        if let bundleId = Bundle.main.bundleIdentifier {
            self.cache = self.defaults.persistentDomain(forName: bundleId) ?? [:]
            // reader values were persisted in a separate domain by earlier versions
            self.defaults.removePersistentDomain(forName: "\(bundleId).db")
        }
        self.cleanupLegacy()
    }
    
    private func cleanupLegacy() {
        let legacyPrefixes = ["Battery_", "Net_"]
        let legacyKeys: Set<String> = [
            "Sensors_saveFanSpeed",
            "Sensors_syncFansControl",
            "Sensors_fanControl",
            "Sensors_fanControlState",
            "Sensors_fanMode",
            "Sensors_fansMode",
            "Sensors_fanSpeed"
        ]
        self.cache.keys.filter { key in legacyKeys.contains(key) || legacyPrefixes.contains(where: { key.hasPrefix($0) }) }.forEach {
            self.cache.removeValue(forKey: $0)
            self.defaults.removeObject(forKey: $0)
        }
    }
    
    private func getValue<T>(for key: String, type: T.Type) -> T? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cache[key] as? T
    }
    
    private func setValue(_ value: Any?, for key: String) {
        self.lock.lock()
        let changed = !Store.isEqual(self.cache[key], value)
        if changed {
            self.cache[key] = value
            self._generation += 1
        }
        self.lock.unlock()
        
        guard changed else { return }
        if let value {
            self.defaults.set(value, forKey: key)
        } else {
            self.defaults.removeObject(forKey: key)
        }
    }
    
    private static func isEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left as NSObject, right as NSObject): return left.isEqual(right)
        default: return false
        }
    }
    
    public func exist(key: String) -> Bool {
        return self.getValue(for: key, type: Any.self) != nil || self.defaults.object(forKey: key) != nil
    }
    
    public func remove(_ key: String) {
        self.setValue(nil, for: key)
    }
    
    public func bool(key: String, defaultValue value: Bool) -> Bool {
        return self.getValue(for: key, type: Bool.self) ?? value
    }
    
    public func string(key: String, defaultValue value: String) -> String {
        return self.getValue(for: key, type: String.self) ?? value
    }
    
    public func int(key: String, defaultValue value: Int) -> Int {
        return self.getValue(for: key, type: Int.self) ?? value
    }
    
    public func array(key: String, defaultValue value: [Any]) -> [Any] {
        return self.getValue(for: key, type: [Any].self) ?? value
    }
    
    public func data(key: String) -> Data? {
        return self.getValue(for: key, type: Data.self)
    }
    
    public func set(key: String, value: Bool) {
        self.setValue(value, for: key)
    }
    
    public func set(key: String, value: String) {
        self.setValue(value, for: key)
    }
    
    public func set(key: String, value: Int) {
        self.setValue(value, for: key)
    }
    
    public func set(key: String, value: Data) {
        self.setValue(value, for: key)
    }
    
    public func set(key: String, value: [Any]) {
        self.setValue(value, for: key)
    }
    
    public func reset() {
        self.lock.lock()
        self.cache.removeAll()
        self._generation += 1
        self.lock.unlock()
        
        if let bundleId = Bundle.main.bundleIdentifier {
            self.defaults.removePersistentDomain(forName: bundleId)
        }
    }
    
    // keys of the removed telemetry and remote features, never exported or imported
    private static let privateKeys: Set<String> = ["telemetry_id", "remote_id", "access_token", "refresh_token"]
    
    public func export(to url: URL) {
        guard let id = Bundle.main.bundleIdentifier, var dictionary = self.defaults.persistentDomain(forName: id) else { return }
        Store.privateKeys.forEach { dictionary.removeValue(forKey: $0) }
        NSDictionary(dictionary: dictionary).write(to: url, atomically: true)
    }
    
    // the settings are only replaced by a reasonably sized property list with a dictionary at its root,
    // values used for sizes and intervals are bounded where they are read
    public func `import`(from url: URL) {
        guard let id = Bundle.main.bundleIdentifier,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
              let data = try? Data(contentsOf: url),
              var dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            let alert = NSAlert()
            alert.messageText = localizedString("Invalid settings file")
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        Store.privateKeys.forEach { dict.removeValue(forKey: $0) }
        
        self.lock.lock()
        self.cache = dict
        self._generation += 1
        self.lock.unlock()
        self.defaults.setPersistentDomain(dict, forName: id)
        restartApp(self)
    }
}
