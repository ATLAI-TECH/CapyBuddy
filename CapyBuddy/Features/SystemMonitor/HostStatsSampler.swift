import Darwin
import Foundation

struct CPUStats: Equatable {
    var userPercent: Double
    var systemPercent: Double
    var idlePercent: Double

    var busyPercent: Double { userPercent + systemPercent }

    static let zero = CPUStats(userPercent: 0, systemPercent: 0, idlePercent: 100)
}

struct MemoryStats: Equatable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var compressedBytes: UInt64

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

struct SystemStats: Equatable {
    var cpu: CPUStats
    var memory: MemoryStats
}

/// Raw CPU tick counts read from `host_cpu_load_info`. We compare two
/// consecutive samples to compute a percentage — a single snapshot is
/// meaningless because the counters are monotonically increasing totals.
struct CPUTickSample: Equatable {
    var user: UInt64
    var system: UInt64
    var nice: UInt64
    var idle: UInt64

    var total: UInt64 { user &+ system &+ nice &+ idle }
}

/// Snapshot of `vm_statistics64` plus the system page size.
struct VMSnapshot: Equatable {
    var pageSize: UInt64
    var activeCount: UInt64
    var wiredCount: UInt64
    var compressedCount: UInt64
    var freeCount: UInt64
    var inactiveCount: UInt64
    var speculativeCount: UInt64
}

@MainActor
final class HostStatsSampler {

    private var lastCPUSample: CPUTickSample?

    /// Total physical RAM. `nonisolated let` so it's captured at construction
    /// without re-reading system info on every call.
    private let totalBytes: UInt64

    init(totalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.totalBytes = totalBytes
    }

    func sample() -> SystemStats {
        SystemStats(cpu: sampleCPU(), memory: sampleMemory())
    }

    // MARK: - CPU

    private func sampleCPU() -> CPUStats {
        let current = readCPUTicks()
        defer { lastCPUSample = current }
        guard let previous = lastCPUSample else {
            // First sample — nothing to diff against. Report 0% busy.
            return .zero
        }
        return Self.computeCPUPercent(previous: previous, current: current)
    }

    /// Pure function — computing % from two tick samples. Tests cover this
    /// branch directly without touching the kernel.
    nonisolated static func computeCPUPercent(previous: CPUTickSample, current: CPUTickSample) -> CPUStats {
        let dUser = current.user &- previous.user
        let dSystem = current.system &- previous.system
        let dNice = current.nice &- previous.nice
        let dIdle = current.idle &- previous.idle
        let total = dUser &+ dSystem &+ dNice &+ dIdle
        guard total > 0 else { return .zero }
        let denom = Double(total)
        return CPUStats(
            userPercent: Double(dUser &+ dNice) / denom * 100,
            systemPercent: Double(dSystem) / denom * 100,
            idlePercent: Double(dIdle) / denom * 100
        )
    }

    private func readCPUTicks() -> CPUTickSample {
        // SDK 26.4 marks the `HOST_CPU_LOAD_INFO_COUNT` macro as unavailable;
        // compute the integer-field count from the struct size instead.
        var info = host_cpu_load_info()
        let countCapacity = MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(countCapacity)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: countCapacity) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return CPUTickSample(user: 0, system: 0, nice: 0, idle: 0)
        }
        return CPUTickSample(
            user:   UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            nice:   UInt64(info.cpu_ticks.3),
            idle:   UInt64(info.cpu_ticks.2)
        )
    }

    // MARK: - Memory

    private func sampleMemory() -> MemoryStats {
        guard let snapshot = readVMStatistics() else {
            return MemoryStats(totalBytes: totalBytes, usedBytes: 0, compressedBytes: 0)
        }
        return Self.memoryStats(from: snapshot, totalBytes: totalBytes)
    }

    nonisolated static func memoryStats(from snapshot: VMSnapshot, totalBytes: UInt64) -> MemoryStats {
        let usedPages = snapshot.activeCount &+ snapshot.wiredCount &+ snapshot.compressedCount
        return MemoryStats(
            totalBytes: totalBytes,
            usedBytes: usedPages &* snapshot.pageSize,
            compressedBytes: snapshot.compressedCount &* snapshot.pageSize
        )
    }

    private func readVMStatistics() -> VMSnapshot? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMSnapshot(
            pageSize:          UInt64(vm_kernel_page_size),
            activeCount:       UInt64(info.active_count),
            wiredCount:        UInt64(info.wire_count),
            compressedCount:   UInt64(info.compressor_page_count),
            freeCount:         UInt64(info.free_count),
            inactiveCount:     UInt64(info.inactive_count),
            speculativeCount:  UInt64(info.speculative_count)
        )
    }

    // MARK: - Formatting

    nonisolated static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Compose the menu-bar status string. Either side can be hidden.
    /// Default keeps the historical "CPU 45% · MEM 8GB" rendering.
    nonisolated static func statusBarString(cpu: CPUStats?, memory: MemoryStats?) -> String {
        statusBarString(cpu: cpu, memory: memory, format: .labeled)
    }

    /// Render the menu-bar status string in one of several preset shapes.
    /// Switching format is a pure, allocation-light string composition —
    /// safe to call on every timer tick.
    nonisolated static func statusBarString(
        cpu: CPUStats?,
        memory: MemoryStats?,
        format: MenuBarDisplayFormat
    ) -> String {
        var parts: [String] = []
        if let cpu {
            parts.append(format.formatCPU(cpu))
        }
        if let memory {
            parts.append(format.formatMemory(memory))
        }
        return parts.joined(separator: format.separator)
    }

    /// Compact memory rendering used by the non-labeled formats — keeps the
    /// number short ("8.2G" / "812M") so the menu-bar slot doesn't bloat.
    nonisolated static func compactBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824 // 1024^3
        if gb >= 1 {
            return String(format: "%.1fG", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0fM", mb)
    }
}

/// How `HostStatsSampler.statusBarString` lays out the CPU + memory pair.
/// Persisted via `SystemMonitorPrefs.displayFormat`.
enum MenuBarDisplayFormat: String, CaseIterable, Identifiable, Hashable {
    /// "CPU 45% · MEM 8.2GB"
    case labeled
    /// "45% · 8.2G"  — labels stripped, units kept.
    case compact
    /// "45 · 8.2"    — labels & units stripped. Mem is GB without the suffix.
    case numericOnly
    /// "C45 M8.2G"   — single-letter prefix to disambiguate without consuming space.
    case initialPrefix

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .labeled:       return "Labeled (CPU 45% · MEM 8GB)"
        case .compact:       return "Compact (45% · 8G)"
        case .numericOnly:   return "Numeric (45 · 8.2)"
        case .initialPrefix: return "Initial prefix (C45 M8G)"
        }
    }

    /// Separator between CPU and memory parts. The initial-prefix mode skips
    /// the middle dot since the C/M letters are already strong delimiters.
    fileprivate var separator: String {
        switch self {
        case .labeled, .compact, .numericOnly: return " · "
        case .initialPrefix:                   return " "
        }
    }

    fileprivate func formatCPU(_ cpu: CPUStats) -> String {
        switch self {
        case .labeled:       return String(format: "CPU %.0f%%", cpu.busyPercent)
        case .compact:       return String(format: "%.0f%%", cpu.busyPercent)
        case .numericOnly:   return String(format: "%.0f", cpu.busyPercent)
        case .initialPrefix: return String(format: "C%.0f", cpu.busyPercent)
        }
    }

    fileprivate func formatMemory(_ memory: MemoryStats) -> String {
        switch self {
        case .labeled:
            return "MEM \(HostStatsSampler.formatBytes(memory.usedBytes))"
        case .compact:
            return HostStatsSampler.compactBytes(memory.usedBytes)
        case .numericOnly:
            // Bare GB number with one decimal — shorter than `compactBytes`'s
            // "8.2G" because we drop the unit letter altogether here.
            let gb = Double(memory.usedBytes) / 1_073_741_824
            return String(format: "%.1f", gb)
        case .initialPrefix:
            return "M\(HostStatsSampler.compactBytes(memory.usedBytes))"
        }
    }
}
