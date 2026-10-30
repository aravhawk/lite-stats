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

internal class InfoReader: Reader<GPUs> {
    // accelerator services are resolved once; each read only fetches their PerformanceStatistics
    private var accelerators: [(service: io_registry_entry_t, info: GPU_Info)] = []
    
    public override func setup() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOAcceleratorClassName), &iterator) == kIOReturnSuccess else {
            error("accelerators not found", log: self.log)
            return
        }
        defer { IOObjectRelease(iterator) }
        
        while case let service = IOIteratorNext(iterator), service != 0 {
            let model = getIOProperty(service, "model") as? String ?? "Apple Graphics"
            self.accelerators.append((service, GPU_Info(
                id: "\(model) #\(self.accelerators.count)",
                IOClass: getIOProperty(service, "IOClass") as? String ?? "",
                model: model,
                cores: getIOProperty(service, "gpu-core-count") as? Int
            )))
        }
    }
    
    deinit {
        self.accelerators.forEach { IOObjectRelease($0.service) }
    }
    
    public override func read() {
        var gpus = GPUs()
        for (service, var gpu) in self.accelerators {
            guard let stats = getIOProperty(service, "PerformanceStatistics") as? [String: Any] else { continue }
            func percentage(_ key: String) -> Double? {
                (stats[key] as? Int).map { Double(min($0, 100)) / 100 }
            }
            gpu.utilization = percentage("Device Utilization %") ?? percentage("GPU Activity(%)")
            gpu.renderUtilization = percentage("Renderer Utilization %")
            gpu.tilerUtilization = percentage("Tiler Utilization %")
            gpu.temperature = (stats["Temperature(C)"] as? Int).map(Double.init)
            gpu.fanSpeed = stats["Fan Speed(%)"] as? Int
            gpu.coreClock = stats["Core Clock(MHz)"] as? Int
            gpu.memoryClock = stats["Memory Clock(MHz)"] as? Int
            gpus.list.append(gpu)
        }
        self.callback(gpus)
    }
}
