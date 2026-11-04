import WidgetKit
import SwiftUI

// MARK: - Shared pieces

/// How loudly a reading should speak, on the same lines as the panel's alert dot.
enum WidgetLevel {
    case normal, warning, critical

    var tint: Color {
        switch self {
        case .normal: return .primary
        case .warning: return .orange
        case .critical: return .red
        }
    }

    static func cpu(_ busy: Double) -> WidgetLevel {
        busy >= 0.90 ? .critical : busy >= 0.65 ? .warning : .normal
    }

    static func memory(_ pressure: Double) -> WidgetLevel {
        pressure >= 0.85 ? .critical : pressure >= 0.70 ? .warning : .normal
    }

    static func disk(_ freeFraction: Double) -> WidgetLevel {
        freeFraction <= 0.05 ? .critical : freeFraction <= 0.10 ? .warning : .normal
    }

    static func battery(_ battery: WidgetReading.Battery) -> WidgetLevel {
        guard !battery.isPluggedIn else { return .normal }
        return battery.percent <= 10 ? .critical : battery.percent <= 20 ? .warning : .normal
    }
}

enum WidgetFormat {
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Gigabytes the way the app writes them: one decimal below ten, none above.
    static func gigabytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb < 10 ? String(format: "%.1f", gb) : String(format: "%.0f", gb)
    }

    static func memory(used: UInt64, total: UInt64) -> (number: String, unit: String) {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var totalNumber = Double(total)
        var index = 0
        while totalNumber >= 1024 && index < units.count - 1 {
            totalNumber /= 1024
            index += 1
        }
        let usedNumber = Double(used) / pow(1024, Double(index))
        func format(_ value: Double) -> String {
            guard index > 0 && value < 10 else { return String(format: "%.0f", value.rounded()) }
            let number = String(format: "%.1f", value)
            let separator = Locale.current.decimalSeparator ?? "."
            return separator == "." ? number : number.replacingOccurrences(of: ".", with: separator)
        }
        return ("\(format(usedNumber))/\(format(totalNumber))", units[index])
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        return hours > 0 ? "\(hours) h \(minutes % 60) min" : "\(minutes) min"
    }
}

/// A thin capacity bar, filled in the reading's level colour.
struct WidgetBar: View {
    var fraction: Double
    var level: WidgetLevel

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level == .normal ? AnyShapeStyle(.primary.opacity(0.75)) : AnyShapeStyle(level.tint))
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 3))
                    .widgetAccentable()
            }
        }
        .frame(height: 5)
    }
}

/// The frame every small widget shares: what it is on top, the reading in the
/// middle, a bar, and when the reading was taken.
struct SmallWidgetLayout<Value: View>: View {
    let symbol: String
    let title: String
    let date: Date
    var fraction: Double?
    var level: WidgetLevel = .normal
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
                Spacer(minLength: 0)
                Text(verbatim: "μ")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            value
            if let fraction {
                WidgetBar(fraction: fraction, level: level)
            }
            Text(date, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// The reading, at widget size, with its unit set smaller as the panel does.
struct BigReading: View {
    let number: String
    var unit: String?
    var level: WidgetLevel = .normal

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(number)
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
            if let unit {
                Text(unit)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(level.tint)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

struct Unavailable: View {
    var body: some View {
        Text("Not available")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Small widgets

struct CPUWidgetView: View {
    let entry: ReadingEntry

    var body: some View {
        let cpu = entry.reading.cpu
        SmallWidgetLayout(symbol: "cpu", title: "CPU", date: entry.date,
                          fraction: cpu?.busy, level: cpu.map { WidgetLevel.cpu($0.busy) } ?? .normal) {
            if let cpu {
                BigReading(number: "\(Int((cpu.busy * 100).rounded()))", unit: "%", level: WidgetLevel.cpu(cpu.busy))
                Text(String(localized: "load \(String(format: "%.1f", cpu.loadAverage.one))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Unavailable()
            }
        }
        .widgetURL(WidgetModule.cpu.url)
    }
}

struct MemoryWidgetView: View {
    let entry: ReadingEntry

    var body: some View {
        let memory = entry.reading.memory
        SmallWidgetLayout(symbol: "memorychip", title: String(localized: "Memory"), date: entry.date,
                          fraction: memory?.usedFraction,
                          level: memory.map { WidgetLevel.memory($0.pressure) } ?? .normal) {
            if let memory {
                let value = WidgetFormat.memory(used: memory.usedBytes, total: memory.totalBytes)
                BigReading(number: value.number, unit: value.unit, level: WidgetLevel.memory(memory.pressure))
                Text(String(localized: "pressure \(WidgetFormat.percent(memory.pressure))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Unavailable()
            }
        }
        .widgetURL(WidgetModule.memory.url)
    }
}

struct DiskWidgetView: View {
    let entry: ReadingEntry

    var body: some View {
        let disk = entry.reading.disk
        SmallWidgetLayout(symbol: "internaldrive", title: String(localized: "Disk"), date: entry.date,
                          fraction: disk.map { 1 - $0.freeFraction },
                          level: disk.map { WidgetLevel.disk($0.freeFraction) } ?? .normal) {
            if let disk {
                BigReading(number: WidgetFormat.gigabytes(disk.availableBytes), unit: "GB",
                           level: WidgetLevel.disk(disk.freeFraction))
                Text(String(localized: "\(WidgetFormat.percent(disk.freeFraction)) free"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Unavailable()
            }
        }
        .widgetURL(WidgetModule.disk.url)
    }
}

struct BatteryWidgetView: View {
    let entry: ReadingEntry

    static func caption(_ battery: WidgetReading.Battery) -> String {
        if battery.isCharging {
            return battery.timeToFull.map { String(localized: "\(WidgetFormat.duration($0)) to full") }
                ?? String(localized: "Charging")
        }
        if battery.isPluggedIn { return String(localized: "Plugged in") }
        return battery.timeToEmpty.map { String(localized: "\(WidgetFormat.duration($0)) left") }
            ?? String(localized: "On battery")
    }

    var body: some View {
        let battery = entry.reading.battery
        SmallWidgetLayout(symbol: battery?.isCharging == true ? "battery.100.bolt" : "battery.75",
                          title: String(localized: "Battery"), date: entry.date,
                          fraction: battery.map { $0.percent / 100 },
                          level: battery.map(WidgetLevel.battery) ?? .normal) {
            if let battery {
                BigReading(number: "\(Int(battery.percent.rounded()))", unit: "%", level: WidgetLevel.battery(battery))
                Text(Self.caption(battery))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("This Mac has no battery")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(WidgetModule.battery.url)
    }
}
