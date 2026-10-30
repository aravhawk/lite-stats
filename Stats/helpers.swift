//
//  helpers.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 13/07/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Carbon
import Kit
import UserNotifications

extension AppDelegate {
    internal func parseArguments() {
        let args = CommandLine.arguments
        
        if args.contains("--reset") {
            debug("Receive --reset argument. Resetting store (UserDefaults)...")
            Store.shared.reset()
        }
        
        if let disableIndex = args.firstIndex(of: "--disable") {
            if args.indices.contains(disableIndex+1) {
                let disableModules = args[disableIndex+1].split(separator: ",")
                
                disableModules.forEach { (moduleName: Substring) in
                    if let module = modules.first(where: { $0.config.name.lowercased() == moduleName.lowercased()}) {
                        module.unmount()
                    }
                }
            }
        }
    }
    
    internal func parseVersion() {
        let key = "version"
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String

        if !Store.shared.exist(key: key) {
            Store.shared.reset()
            debug("Previous version not detected. Current version (\(currentVersion) set")
        } else {
            let prevVersion = Store.shared.string(key: key, defaultValue: "")
            if prevVersion == currentVersion {
                return
            }

            if isNewestVersion(currentVersion: prevVersion, latestVersion: currentVersion) {
                let title: String = localizedString("Successfully updated")
                let subtitle: String = localizedString("Lite Stats was updated to v", currentVersion)

                let id = showNotification(title: title, subtitle: subtitle, delegate: self)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    removeNotification(id)
                }
            }

            debug("Detected previous version \(prevVersion). Current version (\(currentVersion) set")
        }

        Store.shared.set(key: key, value: currentVersion)
    }
    
    internal func defaultValues() {
        if Store.shared.exist(key: "runAtLoginInitialized") {
            LaunchAtLogin.migrate()
        }

        if Store.shared.exist(key: "dockIcon") {
            let dockIconStatus = Store.shared.bool(key: "dockIcon", defaultValue: false) ? NSApplication.ActivationPolicy.regular : NSApplication.ActivationPolicy.accessory
            NSApp.setActivationPolicy(dockIconStatus)
        }
    }
    
    internal func setup(completion: @escaping () -> Void) {
        if Store.shared.exist(key: "setupProcess") || Store.shared.exist(key: "runAtLoginInitialized") {
            completion()
            return
        }

        debug("showing the setup window")

        self.setupWindow.show()
        self.setupWindow.finishHandler = {
            debug("setup is finished, starting the app")
            completion()
        }
        Store.shared.set(key: "setupProcess", value: true)
    }

    @objc internal func listenForAppPause() {
        for m in modules {
            if self.pauseState && m.enabled {
                m.disable()
            } else if !self.pauseState && !m.enabled && Store.shared.bool(key: "\(m.config.name)_state", defaultValue: m.config.defaultState) {
                m.enable()
            }
        }
        self.icon()
    }
    
    internal func icon() {
        if self.pauseState {
            self.menuBarItem = NSStatusBar.system.statusItem(withLength: AppIcon.size.width)
            DispatchQueue.main.async(execute: {
                self.menuBarItem?.autosaveName = "Lite Stats"
            })
            self.menuBarItem?.button?.addSubview(AppIcon())
            
            self.menuBarItem?.button?.target = self
            self.menuBarItem?.button?.action = #selector(self.openSettings)
            self.menuBarItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        } else {
            if let item = self.menuBarItem {
                NSStatusBar.system.removeStatusItem(item)
            }
            self.menuBarItem = nil
        }
    }
    
    @objc internal func toggleSettings(_ notification: Notification) {
        self.settingsWindow.toggleSettingsHandler(notification)
    }
    
    @objc internal func openSettings() {
        NotificationCenter.default.post(name: .toggleSettings, object: nil, userInfo: ["module": "Dashboard"])
    }
    
    @objc internal func registerHotKeys() {
        HotKeys.shared.register(modules.map { m in
            (keys: m.popupKeyboardShortcut, action: { [weak m] in
                guard let m, m.enabled,
                      let widget = m.menuBar.widgets.first(where: { $0.isActive }),
                      let window = widget.item.window else { return }
                NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: [
                    "module": m.name,
                    "widget": widget.type,
                    "origin": window.frame.origin,
                    "center": window.frame.width/2
                ])
            })
        })
    }
}

// System-wide popup shortcuts. Carbon hot keys cost nothing until pressed and need no accessibility access, only
// combinations macOS refuses to register as hot keys (Option/Shift only) fall back to keyboard event monitors.
private final class HotKeys {
    static let shared = HotKeys()
    
    private static let modifiers: [UInt16: (flag: NSEvent.ModifierFlags, carbon: Int)] = [
        59: (.control, controlKey), 60: (.shift, shiftKey), 55: (.command, cmdKey), 58: (.option, optionKey)
    ]
    
    private var refs: [EventHotKeyRef] = []
    private var actions: [() -> Void] = []
    private var fallback: [(keys: [UInt16], action: () -> Void)] = []
    private var monitors: [Any] = []
    private var handlerInstalled: Bool = false
    
    func register(_ bindings: [(keys: [UInt16], action: () -> Void)]) {
        self.refs.forEach { UnregisterEventHotKey($0) }
        self.refs = []
        self.actions = []
        self.fallback = []
        self.monitors.forEach { NSEvent.removeMonitor($0) }
        self.monitors = []
        
        for binding in bindings {
            guard let key = binding.keys.last, HotKeys.modifiers[key] == nil else { continue }
            let mods = binding.keys.dropLast().compactMap { HotKeys.modifiers[$0]?.carbon }.reduce(0, |)
            
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4C53484B), id: UInt32(self.actions.count)) // 'LSHK'
            if mods & (cmdKey | controlKey) != 0,
               RegisterEventHotKey(UInt32(key), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                self.refs.append(ref)
                self.actions.append(binding.action)
            } else {
                self.fallback.append(binding)
            }
        }
        
        if !self.actions.isEmpty && !self.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let actions = HotKeys.shared.actions
                if actions.indices.contains(Int(id.id)) {
                    actions[Int(id.id)]()
                }
                return noErr
            }, 1, &spec, nil, nil)
            self.handlerInstalled = true
        }
        
        if !self.fallback.isEmpty {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] in self?.handle($0) }) {
                self.monitors.append(monitor)
            }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] in
                self?.handle($0)
                return $0
            }) {
                self.monitors.append(monitor)
            }
        }
    }
    
    private func handle(_ event: NSEvent) {
        let keys = [59, 60, 55, 58].filter { event.modifierFlags.contains(HotKeys.modifiers[$0]!.flag) } + [event.keyCode]
        self.fallback.first(where: { $0.keys == keys })?.action()
    }
}
