import Foundation
import Darwin
import IOKit.ps

/// One look at the Mac, taken when macOS asks a widget for its next entry.
///
/// The extension reads the kernel itself rather than asking the app: it runs a few
/// times an hour for a few milliseconds, so the app keeps no extra work going for
/// widgets that may not even be on the desktop. Every figure is worked out the way
/// the app works it out, so a widget and the panel never disagree about the same
/// moment.
struct WidgetReading: Sendable {
    struct Metrics: OptionSet, Sendable {
        let rawValue: UInt8

        static let cpu = Metrics(rawValue: 1 << 0)
        static let memory = Metrics(rawValue: 1 << 1)
        static let disk = Metrics(rawValue: 1 << 2)
        static let battery = Metrics(rawValue: 1 << 3)
        static let rings: Metrics = [.cpu, .memory, .disk]
        static let all: Metrics = [.cpu, .memory, .disk, .battery]
    }

    struct CPU: Sendable {
        /// Busy share of all cores over the sampling window, 0...1.
        var busy: Double
        var loadAverage: (one: Double, five: Double, fifteen: Double)
    }

    struct Memory: Sendable {
        var usedBytes: UInt64
        var totalBytes: UInt64
        /// Wired and compressed over total, the app's pressure figure.
        var pressure: Double
        var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    }

    struct Disk: Sendable {
        var availableBytes: UInt64
        var totalBytes: UInt64
        var freeFraction: Double { totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 0 }
    }

    struct Battery: Sendable {
        var percent: Double
        var isCharging: Bool
        var isPluggedIn: Bool
        /// Seconds, when the system has an estimate.
        var timeToEmpty: TimeInterval?
        var timeToFull: TimeInterval?
    }

    var date: Date
    var cpu: CPU?
    var memory: Memory?
    var disk: Disk?
    /// Nil on a Mac without one.
    var battery: Battery?

    /// CPU needs two looks at the tick counters, so it waits `window` between them.
    static func take(metrics: Metrics, window: Duration = .milliseconds(600)) async -> WidgetReading {
        var cpu: CPU?
        if metrics.contains(.cpu) {
            let first = cpuTicks()
            try? await Task.sleep(for: window)
            let second = cpuTicks()
            if let first, let second {
                let busy = Double(second.busy &- first.busy)
                let total = busy + Double(second.idle &- first.idle)
                var loads = [Double](repeating: 0, count: 3)
                getloadavg(&loads, 3)
                cpu = CPU(busy: total > 0 ? min(max(busy / total, 0), 1) : 0,
                          loadAverage: (loads[0], loads[1], loads[2]))
            }
        }
        return WidgetReading(date: .now, cpu: cpu,
                             memory: metrics.contains(.memory) ? memory() : nil,
                             disk: metrics.contains(.disk) ? disk() : nil,
                             battery: metrics.contains(.battery) ? battery() : nil)
    }

    // MARK: CPU

    private static func cpuTicks() -> (busy: UInt64, idle: UInt64)? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let user = UInt64(ticks.0), system = UInt64(ticks.1), idle = UInt64(ticks.2), nice = UInt64(ticks.3)
        return (user + system + nice, idle)
    }

    // MARK: Memory

    /// App + wired + compressed, as in the app's MemoryCollector.
    private static func memory() -> Memory? {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0, total > 0 else { return nil }
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }

        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(pageSize)
        let purgeable = UInt64(vm.purgeable_count)
        let internalPages = UInt64(vm.internal_page_count)
        let app = (internalPages - min(internalPages, purgeable)) * page
        let wired = UInt64(vm.wire_count) * page
        let compressed = UInt64(vm.compressor_page_count) * page
        return Memory(usedBytes: app + wired + compressed, totalBytes: total,
                      pressure: min(1, Double(wired + compressed) / Double(total)))
    }

    // MARK: Disk

    /// The startup volume's available capacity, purgeable space included, which is
    /// the figure Finder and the app show.
    private static func disk() -> Disk? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
        let plain = values.volumeAvailableCapacity.map { UInt64(max($0, 0)) }
        guard let available = important ?? plain else { return nil }
        return Disk(availableBytes: min(available, UInt64(total)), totalBytes: UInt64(total))
    }

    // MARK: Battery

    private static func battery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let sources = list.compactMap {
            IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
        }
        guard let source = sources.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }),
              let current = (source[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let full = (source[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, full > 0 else { return nil }
        func minutes(_ key: String) -> TimeInterval? {
            guard let value = (source[key] as? NSNumber)?.doubleValue, value > 0 else { return nil }
            return value * 60
        }
        return Battery(percent: min(100, max(0, current / full * 100)),
                       isCharging: source[kIOPSIsChargingKey] as? Bool ?? false,
                       isPluggedIn: (source[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                       timeToEmpty: minutes(kIOPSTimeToEmptyKey),
                       timeToFull: minutes(kIOPSTimeToFullChargeKey))
    }
}
