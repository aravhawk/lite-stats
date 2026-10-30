//
//  notifications.swift
//  Disk
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
    private let utilizationID: String = "usage"
    
    private var utilizationState: Bool = false
    private var utilization: Int = 80
    
    public override init(_ module: ModuleType) {
        super.init(module)
        
        self.utilizationState = Store.shared.bool(key: "\(self.module)_notifications_utilization_state", defaultValue: self.utilizationState)
        self.utilization = Store.shared.int(key: "\(self.module)_notifications_utilization_value", defaultValue: self.utilization)
    }

    public override func load() {
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Usage"), component: PreferencesSwitch(
                action: self.toggleUtilization, state: self.utilizationState, with: StepperInput(self.utilization, callback: self.changeUtilization)
            ))
        ]))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    internal func utilizationCallback(_ value: Double) {
        if self.utilizationState {
            self.checkDouble(id: self.utilizationID, value: value, threshold: Double(self.utilization)/100,
                             title: localizedString("Disk utilization threshold"),
                             subtitle: localizedString("Disk utilization is", "\(Int((value)*100))%"))
        }
    }
    
    @objc private func toggleUtilization(_ sender: NSControl) {
        self.utilizationState = controlState(sender)
        Store.shared.set(key: "\(self.module)_notifications_utilization_state", value: self.utilizationState)
    }
    @objc private func changeUtilization(_ newValue: Int) {
        self.utilization = newValue
        Store.shared.set(key: "\(self.module)_notifications_utilization_value", value: self.utilization)
    }
}
