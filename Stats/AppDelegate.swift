//
//  AppDelegate.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 28.05.2019.
//  Copyright © 2019 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

import Kit
import UserNotifications

import CPU
import RAM
import Disk
import Sensors
import GPU

var modules: [Module] = [
    CPU(),
    GPU(),
    RAM(),
    Disk(),
    Sensors()
]

@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    internal let settingsWindow: SettingsWindow = SettingsWindow()
    internal lazy var setupWindow: SetupWindow = SetupWindow()
    internal var clickInNotification: Bool = false
    internal var menuBarItem: NSStatusItem? = nil
    internal var combinedView: CombinedView = CombinedView()
    
    internal var pauseState: Bool {
        Store.shared.bool(key: "pause", defaultValue: false)
    }
    
    private var startTS: Date?
    
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let startingPoint = Date()
        
        self.parseArguments()
        self.parseVersion()
        self.setup {
            modules.reversed().forEach{ $0.mount() }
            self.settingsWindow.setModules()
        }
        self.defaultValues()
        self.icon()
        
        NotificationCenter.default.addObserver(self, selector: #selector(listenForAppPause), name: .pause, object: nil)
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
        
        info("Lite Stats started in \((startingPoint.timeIntervalSinceNow * -1).rounded(toPlaces: 4)) seconds")
        self.startTS = Date()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        modules.forEach{ $0.terminate() }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if self.clickInNotification {
            self.clickInNotification = false
            return true
        }
        guard let startTS = self.startTS, Date().timeIntervalSince(startTS) > 2 else { return false }
        
        if flag {
            self.settingsWindow.openDefaultIfNeeded()
            self.settingsWindow.makeKeyAndOrderFront(self)
        } else {
            self.settingsWindow.openDefaultIfNeeded()
            self.settingsWindow.setIsVisible(true)
        }
        
        return true
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        self.clickInNotification = true

        completionHandler()
    }
}
