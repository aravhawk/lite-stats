//
//  types.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 10/04/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public struct DoubleValue {
    public var ts: Date = Date()
    public let value: Double
    
    public init(_ value: Double = 0) {
        self.value = value
    }
}
extension [DoubleValue] {
    public func max() -> Double? { self.max(by: { $0.value < $1.value })?.value }
}

public struct ColorValue: Equatable {
    public let value: Double
    public let color: NSColor?
    
    public init(_ value: Double, color: NSColor? = nil) {
        self.value = value
        self.color = color
    }
    
    // swiftlint:disable operator_whitespace
    public static func ==(lhs: ColorValue, rhs: ColorValue) -> Bool {
        return lhs.value == rhs.value
    }
    // swiftlint:enable operator_whitespace
}

public let TemperatureUnits: [KeyValue_t] = [
    KeyValue_t(key: "system", value: "System"),
    KeyValue_t(key: "separator", value: "separator"),
    KeyValue_t(key: "celsius", value: "Celsius", additional: UnitTemperature.celsius),
    KeyValue_t(key: "fahrenheit", value: "Fahrenheit", additional: UnitTemperature.fahrenheit)
]

public let CombinedModulesSpacings: [KeyValue_t] = [
    KeyValue_t(key: "none", value: "None"),
    KeyValue_t(key: "1", value: "1", additional: 1),
    KeyValue_t(key: "2", value: "2", additional: 2),
    KeyValue_t(key: "3", value: "3", additional: 3),
    KeyValue_t(key: "4", value: "4", additional: 4),
    KeyValue_t(key: "5", value: "5", additional: 5),
    KeyValue_t(key: "6", value: "6", additional: 6),
    KeyValue_t(key: "7", value: "7", additional: 7),
    KeyValue_t(key: "8", value: "8", additional: 8)
]

public enum DataSizeBase: String {
    case bit
    case byte
}

internal enum StackMode: String {
    case auto = "automatic"
    case oneRow = "oneRow"
    case twoRows = "twoRows"
}

internal let SensorsWidgetMode: [KeyValue_t] = [
    KeyValue_t(key: StackMode.auto.rawValue, value: "Automatic"),
    KeyValue_t(key: "separator", value: "separator"),
    KeyValue_t(key: StackMode.oneRow.rawValue, value: "One row"),
    KeyValue_t(key: StackMode.twoRows.rawValue, value: "Two rows")
]

public let ReaderUpdateIntervals: [KeyValue_t] = [
    KeyValue_t(key: "1", value: "1 sec"),
    KeyValue_t(key: "2", value: "2 sec"),
    KeyValue_t(key: "3", value: "3 sec"),
    KeyValue_t(key: "5", value: "5 sec"),
    KeyValue_t(key: "10", value: "10 sec"),
    KeyValue_t(key: "15", value: "15 sec"),
    KeyValue_t(key: "30", value: "30 sec"),
    KeyValue_t(key: "60", value: "60 sec")
]
public let NumbersOfProcesses: [Int] = [0, 3, 5, 8, 10, 15]

// number of top processes shown by a module, limited to the values offered in the settings
public func numberOfProcesses(_ module: String, defaultValue: Int) -> Int {
    min(max(Store.shared.int(key: "\(module)_processes", defaultValue: defaultValue), 0), NumbersOfProcesses.max() ?? 15)
}

internal let Alignments: [KeyValue_t] = [
    KeyValue_t(key: "left", value: "Left alignment", additional: NSTextAlignment.left),
    KeyValue_t(key: "center", value: "Center alignment", additional: NSTextAlignment.center),
    KeyValue_t(key: "right", value: "Right alignment", additional: NSTextAlignment.right)
]

public struct SColor: KeyValue_p, Equatable {
    public let key: String
    public let value: String
    public var additional: Any?
    
    public static func == (lhs: SColor, rhs: SColor) -> Bool {
        return lhs.key == rhs.key
    }
}

extension SColor: CaseIterable {
    public static let utilization = SColor(key: "utilization", value: "Based on utilization", additional: NSColor.black)
    public static let pressure = SColor(key: "pressure", value: "Based on pressure", additional: NSColor.black)
    public static let cluster = SColor(key: "cluster", value: "Based on cluster", additional: NSColor.controlAccentColor)
    
    public static let separator1 = SColor(key: "separator_1", value: "separator_1", additional: NSColor.black)
    
    public static let systemAccent = SColor(key: "system", value: "System accent", additional: NSColor.controlAccentColor)
    public static let monochrome = SColor(key: "monochrome", value: "Monochrome accent", additional: NSColor.textColor)
    
    public static let separator2 = SColor(key: "separator_2", value: "separator_2", additional: NSColor.black)
    
    public static let clear = SColor(key: "clear", value: "Clear", additional: NSColor.clear)
    public static let white = SColor(key: "white", value: "White", additional: NSColor.white)
    public static let black = SColor(key: "black", value: "Black", additional: NSColor.black)
    public static let gray = SColor(key: "gray", value: "Gray", additional: NSColor.gray)
    public static let secondGray = SColor(key: "secondGray", value: "Second gray", additional: NSColor.systemGray)
    public static let darkGray = SColor(key: "darkGray", value: "Dark gray", additional: NSColor.darkGray)
    public static let lightGray = SColor(key: "lightGray", value: "Light gray", additional: NSColor.lightGray)
    public static let red = SColor(key: "red", value: "Red", additional: NSColor.red)
    public static let secondRed = SColor(key: "secondRed", value: "Second red", additional: NSColor.systemRed)
    public static let green = SColor(key: "green", value: "Green", additional: NSColor.green)
    public static let secondGreen = SColor(key: "secondGreen", value: "Second green", additional: NSColor.systemGreen)
    public static let blue = SColor(key: "blue", value: "Blue", additional: NSColor.blue)
    public static let secondBlue = SColor(key: "secondBlue", value: "Second blue", additional: NSColor.systemBlue)
    public static let yellow = SColor(key: "yellow", value: "Yellow", additional: NSColor.yellow)
    public static let secondYellow = SColor(key: "secondYellow", value: "Second yellow", additional: NSColor.systemYellow)
    public static let orange = SColor(key: "orange", value: "Orange", additional: NSColor.orange)
    public static let secondOrange = SColor(key: "secondOrange", value: "Second orange", additional: NSColor.systemOrange)
    public static let purple = SColor(key: "purple", value: "Purple", additional: NSColor.purple)
    public static let secondPurple = SColor(key: "secondPurple", value: "Second purple", additional: NSColor.systemPurple)
    public static let brown = SColor(key: "brown", value: "Brown", additional: NSColor.brown)
    public static let secondBrown = SColor(key: "secondBrown", value: "Second brown", additional: NSColor.systemBrown)
    public static let cyan = SColor(key: "cyan", value: "Cyan", additional: NSColor.cyan)
    public static let magenta = SColor(key: "magenta", value: "Magenta", additional: NSColor.magenta)
    public static let pink = SColor(key: "pink", value: "Pink", additional: NSColor.systemPink)
    public static let teal = SColor(key: "teal", value: "Teal", additional: NSColor.systemTeal)
    public static let indigo = SColor(key: "indigo", value: "Indigo", additional: NSColor.systemIndigo)
    
    public static let allColors: [SColor] = [
        .systemAccent, .monochrome, .separator2,
        .clear, .white, .black, .gray, .secondGray, .darkGray, .lightGray,
        .red, .secondRed, .green, .secondGreen, .blue, .secondBlue, .yellow, .secondYellow,
        .orange, .secondOrange, .purple, .secondPurple, .brown, .secondBrown,
        .cyan, .magenta, .pink, .teal, .indigo
    ]
    public static let allCases: [SColor] = [.utilization, .pressure, .cluster, .separator1] + allColors
    
    // color stored under `key`, or `defaultValue` if unset/invalid
    public static func stored(_ key: String, defaultValue: SColor) -> NSColor {
        (self.fromString(Store.shared.string(key: key, defaultValue: defaultValue.key), defaultValue: defaultValue).additional as? NSColor) ?? .controlAccentColor
    }
    
    public static func fromString(_ key: String, defaultValue: SColor = .systemAccent) -> SColor {
        return SColor.allCases.first{ $0.key == key } ?? defaultValue
    }
}

public typealias colorZones = (orange: Double, red: Double)

public extension Notification.Name {
    static let toggleSettings = Notification.Name("toggleSettings")
    static let toggleModule = Notification.Name("toggleModule")
    static let togglePopup = Notification.Name("togglePopup")
    static let toggleWidget = Notification.Name("toggleWidget")
    static let openModuleSettings = Notification.Name("openModuleSettings")
    static let clickInSettings = Notification.Name("clickInSettings")
    static let keyboardShortcutsChanged = Notification.Name("keyboardShortcutsChanged")
    static let toggleOneView = Notification.Name("toggleOneView")
    static let widgetRearrange = Notification.Name("widgetRearrange")
    static let moduleRearrange = Notification.Name("moduleRearrange")
    static let pause = Notification.Name("pause")
    static let combinedModulesPopup = Notification.Name("combinedModulesPopup")
}

public let notificationLevels: [KeyValue_t] = [
    KeyValue_t(key: "", value: "Disabled"),
    KeyValue_t(key: "0.03", value: "3%"),
    KeyValue_t(key: "0.05", value: "5%"),
    KeyValue_t(key: "0.1", value: "10%"),
    KeyValue_t(key: "0.15", value: "15%"),
    KeyValue_t(key: "0.2", value: "20%"),
    KeyValue_t(key: "0.25", value: "25%"),
    KeyValue_t(key: "0.3", value: "30%"),
    KeyValue_t(key: "0.35", value: "35%"),
    KeyValue_t(key: "0.4", value: "40%"),
    KeyValue_t(key: "0.45", value: "45%"),
    KeyValue_t(key: "0.5", value: "50%"),
    KeyValue_t(key: "0.55", value: "55%"),
    KeyValue_t(key: "0.6", value: "60%"),
    KeyValue_t(key: "0.65", value: "65%"),
    KeyValue_t(key: "0.7", value: "70%"),
    KeyValue_t(key: "0.75", value: "75%"),
    KeyValue_t(key: "0.8", value: "80%"),
    KeyValue_t(key: "0.85", value: "85%"),
    KeyValue_t(key: "0.9", value: "90%"),
    KeyValue_t(key: "0.95", value: "95%"),
    KeyValue_t(key: "0.97", value: "97%"),
    KeyValue_t(key: "1.0", value: "100%")
]

public struct Scale: KeyValue_p, Equatable {
    public let key: String
    public let value: String
    
    public static func == (lhs: Scale, rhs: Scale) -> Bool {
        return lhs.key == rhs.key
    }
}

extension Scale: CaseIterable {
    public static let none = Scale(key: "none", value: "None")
    public static let separator = Scale(key: "separator", value: "separator")
    public static let linear = Scale(key: "linear", value: "Linear")
    public static let square = Scale(key: "square", value: "Square")
    public static let cube = Scale(key: "cube", value: "Cube")
    public static let logarithmic = Scale(key: "logarithmic", value: "Logarithmic")
    public static let separator2 = Scale(key: "separator", value: "separator")
    public static let fixed = Scale(key: "fixed", value: "Fixed scale")
    
    public static let allCases: [Scale] = [.none, .separator, .linear, .square, .cube, .logarithmic, .separator2, .fixed]
    
    public static func fromString(_ key: String, defaultValue: Scale = .linear) -> Scale {
        return Scale.allCases.first{ $0.key == key } ?? defaultValue
    }
}

public enum FanValue: String {
    case rpm
    case percentage
}
public let FanValues: [KeyValue_t] = [
    KeyValue_t(key: "rpm", value: "RPM", additional: FanValue.rpm),
    KeyValue_t(key: "percentage", value: "Percentage", additional: FanValue.percentage)
]

public var LineChartHistory: [KeyValue_p] = [
    KeyValue_t(key: "60", value: "1 minute"),
    KeyValue_t(key: "120", value: "2 minutes"),
    KeyValue_t(key: "180", value: "3 minutes"),
    KeyValue_t(key: "300", value: "5 minutes"),
    KeyValue_t(key: "600", value: "10 minutes")
]

public struct SizeUnit: KeyValue_p, Equatable {
    public let key: String
    public let value: String
    
    public static func == (lhs: SizeUnit, rhs: SizeUnit) -> Bool {
        return lhs.key == rhs.key
    }
}

extension SizeUnit: CaseIterable {
    public static let byte = SizeUnit(key: "byte", value: "Bytes")
    public static let KB = SizeUnit(key: "KB", value: "KB")
    public static let MB = SizeUnit(key: "MB", value: "MB")
    public static let GB = SizeUnit(key: "GB", value: "GB")
    public static let TB = SizeUnit(key: "TB", value: "TB")
    
    public static let allCases: [SizeUnit] = [.byte, .KB, .MB, .GB, .TB]
    
    public static func fromString(_ key: String, defaultValue: SizeUnit = .byte) -> SizeUnit {
        return SizeUnit.allCases.first{ $0.key == key } ?? defaultValue
    }
}

public enum RAMPressure: String, Codable {
    case normal
    case warning
    case critical
    
    func pressureColor() -> NSColor {
        switch self {
        case .normal:
            return NSColor.systemGreen
        case .warning:
            return NSColor.systemYellow
        case .critical:
            return NSColor.systemRed
        }
    }
}
