import XCTest
@testable import CapyBuddy

final class HostStatsSamplerTests: XCTestCase {

    // MARK: - CPU computation

    func testComputeCPUPercentWithEvenSplitBetweenUserSystemIdle() {
        let prev = CPUTickSample(user: 100, system: 100, nice: 0, idle: 100)
        let curr = CPUTickSample(user: 200, system: 200, nice: 0, idle: 200)

        let stats = HostStatsSampler.computeCPUPercent(previous: prev, current: curr)

        XCTAssertEqual(stats.userPercent, 100.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(stats.systemPercent, 100.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(stats.idlePercent, 100.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(stats.busyPercent, 200.0 / 3.0, accuracy: 0.01)
    }

    func testComputeCPUPercentTreatsNiceAsUser() {
        let prev = CPUTickSample(user: 0, system: 0, nice: 0, idle: 100)
        let curr = CPUTickSample(user: 50, system: 0, nice: 50, idle: 100)

        let stats = HostStatsSampler.computeCPUPercent(previous: prev, current: curr)

        // user (50) + nice (50) = 100 ticks of "user" diff out of 100 total
        XCTAssertEqual(stats.userPercent, 100.0, accuracy: 0.01)
        XCTAssertEqual(stats.systemPercent, 0.0)
        XCTAssertEqual(stats.idlePercent, 0.0)
    }

    func testComputeCPUPercentZeroDeltaReportsAllIdle() {
        let prev = CPUTickSample(user: 100, system: 100, nice: 0, idle: 100)
        let curr = CPUTickSample(user: 100, system: 100, nice: 0, idle: 100)

        let stats = HostStatsSampler.computeCPUPercent(previous: prev, current: curr)

        XCTAssertEqual(stats, .zero)
        XCTAssertEqual(stats.idlePercent, 100.0)
    }

    func testCPUStatsZeroIsAllIdle() {
        XCTAssertEqual(CPUStats.zero.busyPercent, 0)
        XCTAssertEqual(CPUStats.zero.idlePercent, 100)
    }

    // MARK: - Memory computation

    func testMemoryStatsSumsActiveWiredAndCompressed() {
        let snap = VMSnapshot(
            pageSize: 16384,
            activeCount: 1000,
            wiredCount: 500,
            compressedCount: 500,
            freeCount: 4000,
            inactiveCount: 0,
            speculativeCount: 0
        )
        let total: UInt64 = 16 * 1024 * 1024 * 1024   // 16 GB

        let stats = HostStatsSampler.memoryStats(from: snap, totalBytes: total)

        // (1000 + 500 + 500) * 16384 = 32_768_000
        XCTAssertEqual(stats.usedBytes, 2000 * 16384)
        XCTAssertEqual(stats.compressedBytes, 500 * 16384)
        XCTAssertEqual(stats.totalBytes, total)
    }

    func testMemoryStatsUsedFractionForKnownInputs() {
        let snap = VMSnapshot(
            pageSize: 1000,
            activeCount: 5,
            wiredCount: 5,
            compressedCount: 0,
            freeCount: 90,
            inactiveCount: 0,
            speculativeCount: 0
        )
        let stats = HostStatsSampler.memoryStats(from: snap, totalBytes: 100_000)

        XCTAssertEqual(stats.usedBytes, 10_000)
        XCTAssertEqual(stats.usedFraction, 0.1, accuracy: 0.0001)
    }

    func testMemoryStatsUsedFractionWithZeroTotalIsZero() {
        let stats = MemoryStats(totalBytes: 0, usedBytes: 0, compressedBytes: 0)
        XCTAssertEqual(stats.usedFraction, 0)
    }

    // MARK: - Status bar string

    func testStatusBarStringWithBothMetrics() {
        let cpu = CPUStats(userPercent: 10, systemPercent: 13, idlePercent: 77)
        let mem = MemoryStats(totalBytes: 16_000_000_000, usedBytes: 8_000_000_000, compressedBytes: 0)
        let s = HostStatsSampler.statusBarString(cpu: cpu, memory: mem)

        XCTAssertTrue(s.hasPrefix("CPU 23%"), "unexpected: \(s)")
        XCTAssertTrue(s.contains("·"))
        XCTAssertTrue(s.contains("MEM"))
    }

    func testStatusBarStringOmitsHiddenSides() {
        let cpu = CPUStats(userPercent: 5, systemPercent: 5, idlePercent: 90)
        let cpuOnly = HostStatsSampler.statusBarString(cpu: cpu, memory: nil)
        XCTAssertEqual(cpuOnly, "CPU 10%")

        let mem = MemoryStats(totalBytes: 1_000_000, usedBytes: 500_000, compressedBytes: 0)
        let memOnly = HostStatsSampler.statusBarString(cpu: nil, memory: mem)
        XCTAssertTrue(memOnly.hasPrefix("MEM "))
        XCTAssertFalse(memOnly.contains("CPU"))
    }

    func testStatusBarStringWithBothNilIsEmpty() {
        XCTAssertEqual(HostStatsSampler.statusBarString(cpu: nil, memory: nil), "")
    }

    // MARK: - formatBytes

    func testFormatBytesProducesUnitSuffix() {
        let s = HostStatsSampler.formatBytes(8 * 1024 * 1024 * 1024)   // 8 GB
        XCTAssertTrue(s.contains("GB"))
    }
}
