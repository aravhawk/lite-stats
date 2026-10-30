//
//  notifications.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 05/12/2023
//  Using Swift 5.0
//  Running on macOS 14.1
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

class Notifications: NotificationsWrapper {
    private let usageID: String = "usage"
    
    private var usageState: Bool = false
    private var usageLevel: Int = 75
    
    public override init(_ module: ModuleType) {
        super.init(module)
        
        self.usageState = Store.shared.bool(key: "\(self.module)_notifications_usage_state", defaultValue: self.usageState)
        self.usageLevel = Store.shared.int(key: "\(self.module)_notifications_usage_value", defaultValue: self.usageLevel)
    }

    public override func load() {
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Usage"), component: PreferencesSwitch(
                action: self.toggleUsage, state: self.usageState,
                with: StepperInput(self.usageLevel, callback: self.changeUsage)
            ))
        ]))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    internal func usageCallback(_ value: Double) {
        if self.usageState {
            self.checkDouble(id: self.usageID, value: value, threshold: Double(self.usageLevel)/100,
                             title: localizedString("GPU usage threshold"),
                             subtitle: localizedString("GPU usage is", "\(Int((value)*100))%"))
        }
    }
    
    @objc private func toggleUsage(_ sender: NSControl) {
        self.usageState = controlState(sender)
        Store.shared.set(key: "\(self.module)_notifications_usage_state", value: self.usageState)
    }
    @objc private func changeUsage(_ newValue: Int) {
        self.usageLevel = newValue
        Store.shared.set(key: "\(self.module)_notifications_usage_value", value: self.usageLevel)
    }
}
