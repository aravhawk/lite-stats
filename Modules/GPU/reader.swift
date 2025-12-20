//
//  reader.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 17/08/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public struct device {
    public let model: String
    public let pci: String
    public var used: Bool
}

internal class InfoReader: Reader<GPUs> {
    private var gpus: GPUs = GPUs()
    private var displays: [gpu_s] = []
    private var devices: [device] = []
    
    public override func setup() {
        if let list = SystemKit.shared.device.info.gpu {
            self.displays = list
        }
        
        guard let PCIdevices = fetchIOService("IOPCIDevice") else {
            return
        }
        let devices = PCIdevices.filter{ $0.object(forKey: "IOName") as? String == "display" }
        
        devices.forEach { (dict: NSDictionary) in
            guard let deviceID = dict["device-id"] as? Data, let vendorID = dict["vendor-id"] as? Data else {
                error("device-id or vendor-id not found", log: self.log)
                return
            }
            let pci = "0x" + Data([deviceID[1], deviceID[0], vendorID[1], vendorID[0]]).map { String(format: "%02hhX", $0) }.joined().lowercased()
            
            guard let modelData = dict["model"] as? Data, let modelName = String(data: modelData, encoding: .ascii) else {
                error("GPU model not found", log: self.log)
                return
            }
            let model = modelName.replacingOccurrences(of: "\0", with: "")
            
            self.devices.append(device(
                model: model,
                pci: pci,
                used: false
            ))
        }
    }
    
    public override func read() {
        guard let accelerators = fetchIOService(kIOAcceleratorClassName) else {
            return
        }
        var devices = self.devices
        
        for (index, accelerator) in accelerators.enumerated() {
            guard let IOClass = accelerator.object(forKey: "IOClass") as? String else {
                error("IOClass not found", log: self.log)
                return
            }
            
            guard let stats = accelerator["PerformanceStatistics"] as? [String: Any] else {
                error("PerformanceStatistics not found", log: self.log)
                return
            }
            
            var id: String = ""
            var model: String = ""
            var cores: Int? = nil
            let accMatch = (accelerator["IOPCIMatch"] as? String ?? accelerator["IOPCIPrimaryMatch"] as? String ?? "").lowercased()
            
            for (i, device) in devices.enumerated() {
                if accMatch.range(of: device.pci) != nil && !device.used {
                    model = device.model
                    id = "\(model) #\(index)"
                    devices[i].used = true
                    break
                }
            }
            
            let ioClass = IOClass.lowercased()
            var predictModel = "Unknown"
            var type: GPU_types = .unknown
            
            let utilization: Int? = stats["Device Utilization %"] as? Int ?? stats["GPU Activity(%)"] as? Int ?? nil
            let renderUtilization: Int? = stats["Renderer Utilization %"] as? Int ?? nil
            let tilerUtilization: Int? = stats["Tiler Utilization %"] as? Int ?? nil
            var temperature: Int? = stats["Temperature(C)"] as? Int ?? nil
            let fanSpeed: Int? = stats["Fan Speed(%)"] as? Int ?? nil
            let coreClock: Int? = stats["Core Clock(MHz)"] as? Int ?? nil
            let memoryClock: Int? = stats["Memory Clock(MHz)"] as? Int ?? nil
            
            if ioClass.contains("agx") { // apple
                predictModel = stats["model"] as? String ?? "Apple Graphics"
                if let display = self.displays.first(where: { $0.vendor == "sppci_vendor_Apple" }) {
                    if let name = display.name {
                        predictModel = name
                    }
                    if let num = display.cores {
                        cores = num
                    }
                }
                type = .integrated
            }
            
            if model == "" {
                model = predictModel
            }
            if self.gpus.list.first(where: { $0.id == id }) == nil {
                self.gpus.list.append(GPU_Info(
                    id: id,
                    type: type.rawValue,
                    IOClass: IOClass,
                    vendor: nil,
                    model: model,
                    cores: cores
                ))
            }
            guard let idx = self.gpus.list.firstIndex(where: { $0.id == id }) else {
                return
            }
            
            if let agcInfo = accelerator["AGCInfo"] as? [String: Int], let state = agcInfo["poweredOffByAGC"] {
                self.gpus.list[idx].state = state == 0
            }
            
            if var value = utilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].utilization = Double(value)/100
            }
            if var value = renderUtilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].renderUtilization = Double(value)/100
            }
            if var value = tilerUtilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].tilerUtilization = Double(value)/100
            }
            if let value = temperature {
                self.gpus.list[idx].temperature = Double(value)
            }
            if let value = fanSpeed {
                self.gpus.list[idx].fanSpeed = value
            }
            if let value = coreClock {
                self.gpus.list[idx].coreClock = value
            }
            if let value = memoryClock {
                self.gpus.list[idx].memoryClock = value
            }
        }
        
        self.gpus.list.sort{ !$0.state && $1.state }
        self.callback(self.gpus)
    }
}
