//
//  smc.swift
//  SMC
//
//  Created by Serhiy Mytrovtsiy on 25/05/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation
import IOKit

private struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private enum Selector: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case readIndex = 8
    case readKeyInfo = 9
}

private func fourCC(_ str: String) -> UInt32 {
    str.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
}

private func string(_ code: UInt32) -> String {
    String(bytes: [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)], encoding: .ascii) ?? ""
}

private let typeFLT = fourCC("flt ")
private let typeUI8 = fourCC("ui8 ")
private let typeUI16 = fourCC("ui16")
private let typeUI32 = fourCC("ui32")
private let typeFDS = fourCC("{fds")
private let keysAllowedToBeZero: Set<UInt32> = [fourCC("FS! "), fourCC("F0Md"), fourCC("F1Md")]

public class SMC {
    public static let shared = SMC()

    private struct KeyInfo {
        let code: UInt32
        let dataSize: IOByteCount32
        let dataType: UInt32
    }

    private var conn: io_connect_t = 0
    private let lock = NSLock()
    private var keyInfoCache: [String: KeyInfo?] = [:]

    public init() {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard device != 0 else { return }
        IOServiceOpen(device, mach_task_self_, 0, &self.conn)
        IOObjectRelease(device)
    }

    deinit {
        IOServiceClose(self.conn)
    }

    public func getValue(_ key: String) -> Double? {
        guard let (info, data) = self.read(key) else { return nil }
        let b = data.bytes
        if !keysAllowedToBeZero.contains(info.code) && withUnsafeBytes(of: b, { !$0.prefix(Int(info.dataSize)).contains { $0 != 0 } }) {
            return nil
        }

        switch info.dataType {
        case typeFLT: return Double(Float(bitPattern: UInt32(b.3) << 24 | UInt32(b.2) << 16 | UInt32(b.1) << 8 | UInt32(b.0)))
        case typeUI8: return Double(b.0)
        case typeUI16: return Double(UInt16(b.0) << 8 | UInt16(b.1))
        case typeUI32: return Double(UInt32(b.0) << 24 | UInt32(b.1) << 16 | UInt32(b.2) << 8 | UInt32(b.3))
        default:
            // unsigned fixed point "spXY" / "fpXY": Y (hex) is the number of fraction bits
            let prefix = info.dataType >> 16
            guard prefix == 0x7370 || prefix == 0x6670, let bits = Int(String(UnicodeScalar(UInt8(info.dataType & 0xff))), radix: 16) else {
                return nil
            }
            return Double(UInt16(b.0) << 8 | UInt16(b.1)) / Double(1 << bits)
        }
    }

    public func getStringValue(_ key: String) -> String? {
        guard let (info, data) = self.read(key), info.dataType == typeFDS else { return nil }
        let chars = withUnsafeBytes(of: data.bytes) { Array($0[4..<16]) }
        guard chars.contains(where: { $0 != 0 }) else { return nil }
        return String(decoding: chars, as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters))
    }

    public func exists(_ key: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.keyInfo(key) != nil
    }

    public func getAllKeys() -> [String] {
        guard let count = self.getValue("#KEY") else { return [] }

        self.lock.lock()
        defer { self.lock.unlock() }

        var list: [String] = []
        list.reserveCapacity(Int(count))
        for i in 0..<UInt32(count) {
            var input = SMCKeyData_t()
            var output = SMCKeyData_t()
            input.data8 = Selector.readIndex.rawValue
            input.data32 = i
            if self.call(&input, &output) == kIOReturnSuccess, output.result == 0, output.keyInfo.dataSize > 0 {
                list.append(string(output.key))
            }
        }
        return list
    }

    // MARK: - internal functions

    private func read(_ key: String) -> (KeyInfo, SMCKeyData_t)? {
        self.lock.lock()
        defer { self.lock.unlock() }

        guard let info = self.keyInfo(key) else { return nil }

        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = info.code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Selector.readBytes.rawValue
        guard self.call(&input, &output) == kIOReturnSuccess else { return nil }

        return (info, output)
    }

    private func keyInfo(_ key: String) -> KeyInfo? {
        if let cached = self.keyInfoCache[key] {
            return cached
        }

        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = fourCC(key)
        input.data8 = Selector.readKeyInfo.rawValue

        var info: KeyInfo? = nil
        if self.call(&input, &output) == kIOReturnSuccess, output.result == 0, output.keyInfo.dataSize > 0 {
            info = KeyInfo(code: input.key, dataSize: output.keyInfo.dataSize, dataType: output.keyInfo.dataType)
        }
        self.keyInfoCache[key] = info
        return info
    }

    private func call(_ input: inout SMCKeyData_t, _ output: inout SMCKeyData_t) -> kern_return_t {
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(self.conn, UInt32(Selector.kernelIndex.rawValue), &input, MemoryLayout<SMCKeyData_t>.stride, &output, &outputSize)
    }
}
