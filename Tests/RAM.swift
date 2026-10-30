//
//  RAM.swift
//  Tests
//
//  Created by Serhiy Mytrovtsiy on 16/04/2022.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2022 Serhiy Mytrovtsiy. All rights reserved.
//

import XCTest
@testable import Kit

class RAM: XCTestCase {
    func testProcessSampler_cpuUsagePercent() throws {
        XCTAssertEqual(ProcessSampler.cpuUsagePercent(current: 2_000_000_000, previous: 1_000_000_000, elapsed: 1), 100)
        XCTAssertEqual(ProcessSampler.cpuUsagePercent(current: 1_500_000_000, previous: 1_000_000_000, elapsed: 2), 25)
        XCTAssertEqual(ProcessSampler.cpuUsagePercent(current: 1_000_000_000, previous: 1_000_000_000, elapsed: 1), 0)
        XCTAssertEqual(ProcessSampler.cpuUsagePercent(current: 2_000_000_000, previous: 1_000_000_000, elapsed: 0), 0)
    }

    func testProcessSampler_bytesPerSecond() throws {
        XCTAssertEqual(ProcessSampler.bytesPerSecond(current: 4_000, previous: 1_000, elapsed: 3), 1_000)
        XCTAssertEqual(ProcessSampler.bytesPerSecond(current: 1_000, previous: 1_000, elapsed: 3), 0)
        XCTAssertEqual(ProcessSampler.bytesPerSecond(current: 1_000, previous: 2_000, elapsed: 3), 0)
        XCTAssertEqual(ProcessSampler.bytesPerSecond(current: 4_000, previous: 1_000, elapsed: 0), 0)
    }
}
