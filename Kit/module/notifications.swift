//
//  notifications.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 04/12/2023
//  Using Swift 5.0
//  Running on macOS 14.1
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import UserNotifications

open class NotificationsWrapper: NSStackView {
    public let module: String
    
    private var ids: [String: Bool?] = [:]
    
    public init(_ module: ModuleType) {
        self.module = module.stringValue
        super.init(frame: NSRect.zero)
        
        self.orientation = .vertical
        self.distribution = .gravityAreas
        self.translatesAutoresizingMaskIntoConstraints = false
        self.spacing = Constants.Settings.margin
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // the settings are only built when they are first displayed
    private var loaded: Bool = false
    open func load() {}
    
    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard self.window != nil, !self.loaded else { return }
        self.loaded = true
        self.load()
    }
    
    public func willTerminate() {
        for id in self.ids {
            removeNotification(id.key)
        }
    }
    
    // the texts are only built when a notification is shown
    public func checkDouble(id rid: String, value: Double, threshold: Double, title: @autoclosure () -> String, subtitle: @autoclosure () -> String, less: Bool = false) {
        let id = "Stats_\(self.module)_\(rid)"
        let first = less ? value > threshold : value < threshold
        let second = less ? value <= threshold : value >= threshold
        
        if self.ids[id] != nil, first {
            removeNotification(id)
            self.ids[id] = nil
        }
        
        if self.ids[id] == nil && second {
            self.showNotification(id: id, title: title(), subtitle: subtitle())
            self.ids[id] = true
        }
    }
    
    private func showNotification(id: String, title: String, subtitle: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let value = subtitle {
            content.subtitle = value
        }
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        center.add(request) { (err: Error?) in
            if let err {
                error("add notification: \(err.localizedDescription)")
            }
        }
    }
}
