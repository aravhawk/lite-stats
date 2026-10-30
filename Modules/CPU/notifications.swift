//
//  notifications.swift
//  CPU
//
//  Created by Serhiy Mytrovtsiy on 04/12/2023
//  Using Swift 5.0
//  Running on macOS 14.1
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

class Notifications: NotificationsWrapper {
    private let totalLoadID: String = "totalUsage"
    private let systemLoadID: String = "systemUsage"
    private let userLoadID: String = "userUsage"
    private let eCoresLoadID: String = "eCoresUsage"
    private let pCoresLoadID: String = "pCoresUsage"
    
    private var totalLoadState: Bool = false
    private var systemLoadState: Bool = false
    private var userLoadState: Bool = false
    private var eCoresLoadState: Bool = false
    private var pCoresLoadState: Bool = false
    
    private var totalLoad: Int = 75
    private var systemLoad: Int = 75
    private var userLoad: Int = 75
    private var eCoresLoad: Int = 75
    private var pCoresLoad: Int = 75
    
    public override init(_ module: ModuleType) {
        super.init(module)
        
        self.totalLoadState = Store.shared.bool(key: "\(self.module)_notifications_totalLoad_state", defaultValue: self.totalLoadState)
        self.totalLoad = Store.shared.int(key: "\(self.module)_notifications_totalLoad_value", defaultValue: self.totalLoad)
        self.systemLoadState = Store.shared.bool(key: "\(self.module)_notifications_systemLoad_state", defaultValue: self.systemLoadState)
        self.systemLoad = Store.shared.int(key: "\(self.module)_notifications_systemLoad_value", defaultValue: self.systemLoad)
        self.userLoadState = Store.shared.bool(key: "\(self.module)_notifications_userLoad_state", defaultValue: self.userLoadState)
        self.userLoad = Store.shared.int(key: "\(self.module)_notifications_userLoad_value", defaultValue: self.userLoad)
        
        self.eCoresLoadState = Store.shared.bool(key: "\(self.module)_notifications_eCoresLoad_state", defaultValue: self.eCoresLoadState)
        self.eCoresLoad = Store.shared.int(key: "\(self.module)_notifications_eCoresLoad_value", defaultValue: self.eCoresLoad)
        self.pCoresLoadState = Store.shared.bool(key: "\(self.module)_notifications_pCoresLoad_state", defaultValue: self.pCoresLoadState)
        self.pCoresLoad = Store.shared.int(key: "\(self.module)_notifications_pCoresLoad_value", defaultValue: self.pCoresLoad)
    }

    public override func load() {
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Total load"), component: PreferencesSwitch(
                action: self.toggleTotalLoad, state: self.totalLoadState,
                with: StepperInput(self.totalLoad, callback: self.changeTotalLoad)
            )),
            PreferencesRow(localizedString("System load"), component: PreferencesSwitch(
                action: self.toggleSystemLoad, state: self.systemLoadState,
                with: StepperInput(self.systemLoad, callback: self.changeSystemLoad)
            )),
            PreferencesRow(localizedString("User load"), component: PreferencesSwitch(
                action: self.toggleUserLoad, state: self.userLoadState,
                with: StepperInput(self.userLoad, callback: self.changeUserLoad)
            ))
        ]))
        
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Efficiency cores load"), component: PreferencesSwitch(
                action: self.toggleECoresLoad, state: self.eCoresLoadState,
                with: StepperInput(self.eCoresLoad, callback: self.changeECoresLoad)
            )),
            PreferencesRow(localizedString("Performance cores load"), component: PreferencesSwitch(
                action: self.togglePCoresLoad, state: self.pCoresLoadState,
                with: StepperInput(self.pCoresLoad, callback: self.changePCoresLoad)
            ))
        ]))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    internal func loadCallback(_ value: CPU_Load) {
        if self.totalLoadState {
            self.checkDouble(id: self.totalLoadID, value: value.totalUsage, threshold: Double(self.totalLoad)/100,
                             title: localizedString("CPU usage threshold"),
                             subtitle: "\(localizedString("Total load")): \(Int((value.totalUsage)*100))%")
        }
        
        if self.systemLoadState {
            self.checkDouble(id: self.systemLoadID, value: value.systemLoad, threshold: Double(self.systemLoad)/100,
                             title: localizedString("CPU usage threshold"),
                             subtitle: "\(localizedString("System load")): \(Int((value.systemLoad)*100))%")
        }
        
        if self.userLoadState {
            self.checkDouble(id: self.userLoadID, value: value.userLoad, threshold: Double(self.userLoad)/100,
                             title: localizedString("CPU usage threshold"),
                             subtitle: "\(localizedString("User load")): \(Int((value.userLoad)*100))%")
        }
        
        if self.eCoresLoadState, let usage = value.usageECores {
            self.checkDouble(id: self.eCoresLoadID, value: usage, threshold: Double(self.eCoresLoad)/100,
                             title: localizedString("CPU usage threshold"),
                             subtitle: "\(localizedString("Efficiency cores load")): \(Int((usage)*100))%")
        }
        
        if self.pCoresLoadState, let usage = value.usagePCores {
            self.checkDouble(id: self.pCoresLoadID, value: usage, threshold: Double(self.pCoresLoad)/100,
                             title: localizedString("CPU usage threshold"),
                             subtitle: "\(localizedString("Performance cores load")): \(Int((usage)*100))%")
        }
    }
    
    // MARK: - change helpers
    
    @objc private func toggleTotalLoad(_ sender: NSControl) {
        self.totalLoadState = controlState(sender)
        Store.shared.set(key: "\(self.module)_notifications_totalLoad_state", value: self.totalLoadState)
    }
    @objc private func changeTotalLoad(_ newValue: Int) {
        self.totalLoad = newValue
        Store.shared.set(key: "\(self.module)_notifications_totalLoad_value", value: self.totalLoad)
    }
    
    @objc private func toggleSystemLoad(_ sender: NSControl) {
        self.systemLoadState = controlState(sender)
        Store.shared.set(key: "\(self.module)_notifications_systemLoad_state", value: self.systemLoadState)
    }
    @objc private func changeSystemLoad(_ newValue: Int) {
        self.systemLoad = newValue
        Store.shared.set(key: "\(self.module)_notifications_systemLoad_value", value: self.systemLoad)
    }
    
    @objc private func toggleUserLoad(_ sender: NSControl) {
        self.userLoadState = controlState(sender)
        Store.shared.set(key: "\(self.module)_notifications_userLoad_state", value: self.userLoadState)
    }
    @objc private func changeUserLoad(_ newValue: Int) {
        self.userLoad = newValue
        Store.shared.set(key: "\(self.module)_notifications_userLoad_value", value: self.userLoad)
    }
    
    @objc private func toggleECoresLoad(_ sender: NSControl) {
        self.eCoresLoadState = controlState(sender)
        Store.shared.set(key: "\(self.module)_notifications_eCoresLoad_state", value: self.eCoresLoadState)
    }
    @objc private func changeECoresLoad(_ newValue: Int) {
        self.eCoresLoad = newValue
        Store.shared.set(key: "\(self.module)_notifications_eCoresLoad_value", value: self.eCoresLoad)
    }
    
    @objc private func togglePCoresLoad(_ sender: NSControl) {
        self.pCoresLoadState = controlState(sender)
        Store.shared.set(key: "\(self.module)_notifications_pCoresLoad_state", value: self.pCoresLoadState)
    }
    @objc private func changePCoresLoad(_ newValue: Int) {
        self.pCoresLoad = newValue
        Store.shared.set(key: "\(self.module)_notifications_pCoresLoad_value", value: self.pCoresLoad)
    }
}
