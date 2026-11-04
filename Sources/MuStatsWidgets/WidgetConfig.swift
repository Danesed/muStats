import Foundation
import SwiftUI

/// A reading a widget can draw, by the name the app's `WidgetPayload` uses.
enum WidgetMetric: String, Sendable {
    case cpu, memory, pressure, disk, battery

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return String(localized: "Memory")
        case .pressure: return String(localized: "Pressure")
        case .disk: return String(localized: "Disk")
        case .battery: return String(localized: "Battery")
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .pressure: return "gauge.with.dots.needle.67percent"
        case .disk: return "internaldrive"
        case .battery: return "battery.75"
        }
    }

    var module: WidgetModule {
        switch self {
        case .cpu: return .cpu
        case .memory, .pressure: return .memory
        case .disk: return .disk
        case .battery: return .battery
        }
    }

    var needs: WidgetReading.Metrics {
        switch self {
        case .cpu: return .cpu
        case .memory, .pressure: return .memory
        case .disk: return .disk
        case .battery: return .battery
        }
    }

    /// How full the ring or bar is; nil when the reading is missing.
    func fraction(_ r: WidgetReading) -> Double? {
        switch self {
        case .cpu: return r.cpu?.busy
        case .memory: return r.memory?.usedFraction
        case .pressure: return r.memory?.pressure
        case .disk: return r.disk.map { 1 - $0.freeFraction }
        case .battery: return r.battery.map { $0.percent / 100 }
        }
    }

    /// The reading, short enough for a row.
    func value(_ r: WidgetReading) -> String? {
        switch self {
        case .cpu: return r.cpu.map { WidgetFormat.percent($0.busy) }
        case .memory:
            return r.memory.map {
                let value = WidgetFormat.memory(used: $0.usedBytes, total: $0.totalBytes)
                return "\(value.number) \(value.unit)"
            }
        case .pressure: return r.memory.map { WidgetFormat.percent($0.pressure) }
        case .disk: return r.disk.map { String(localized: "\(WidgetFormat.gigabytes($0.availableBytes)) GB free") }
        case .battery: return r.battery.map { WidgetFormat.percent($0.percent / 100) }
        }
    }

    /// A second line, for the sizes that have room for one.
    func detail(_ r: WidgetReading) -> String? {
        switch self {
        case .cpu: return r.cpu.map { String(localized: "load \(String(format: "%.1f", $0.loadAverage.one))") }
        case .memory: return r.memory.map { String(localized: "pressure \(WidgetFormat.percent($0.pressure))") }
        case .pressure: return nil
        case .disk: return r.disk.map { String(localized: "\(WidgetFormat.percent($0.freeFraction)) free") }
        case .battery: return r.battery.map(BatteryWidgetView.caption)
        }
    }

    func level(_ r: WidgetReading) -> WidgetLevel {
        switch self {
        case .cpu: return r.cpu.map { .cpu($0.busy) } ?? .normal
        case .memory, .pressure: return r.memory.map { .memory($0.pressure) } ?? .normal
        case .disk: return r.disk.map { .disk($0.freeFraction) } ?? .normal
        case .battery: return r.battery.map(WidgetLevel.battery) ?? .normal
        }
    }
}

/// What the app asked the widgets to draw, read from the file it writes for them.
///
/// The sandbox lets the extension read the app's Application Support folder and
/// nothing else of the user's. The folder is found from the account's real home: in
/// the sandbox `NSHomeDirectory()` is the extension's own container.
struct WidgetConfig: Sendable {
    struct Ring: Sendable {
        var metric: WidgetMetric
        var dark: Color
        var light: Color

        func color(dark isDark: Bool) -> Color { isDark ? dark : light }
    }

    var rings: [Ring]
    var overview: [WidgetMetric]

    /// Before the app has ever written a file: its own defaults, Aurora colours.
    static let standard = WidgetConfig(
        rings: [Ring(metric: .cpu, dark: Color(red: 0.66, green: 0.50, blue: 1.00),
                     light: Color(red: 0.45, green: 0.27, blue: 0.86)),
                Ring(metric: .memory, dark: Color(red: 0.25, green: 0.86, blue: 0.76),
                     light: Color(red: 0.00, green: 0.56, blue: 0.50)),
                Ring(metric: .disk, dark: Color(red: 1.00, green: 0.76, blue: 0.28),
                     light: Color(red: 0.80, green: 0.50, blue: 0.00))],
        overview: [.cpu, .memory, .disk, .battery])

    var needs: WidgetReading.Metrics {
        WidgetReading.Metrics(rings.map(\.metric.needs) + overview.map(\.needs))
    }

    static func load() -> WidgetConfig {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return .standard }
        let url = URL(fileURLWithPath: String(cString: home))
            .appendingPathComponent("Library/Application Support/muStats/widget.json")
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return .standard }
        let rings = payload.rings.compactMap { ring -> Ring? in
            guard let metric = WidgetMetric(rawValue: ring.metric) else { return nil }
            return Ring(metric: metric, dark: color(ring.dark), light: color(ring.light))
        }
        let overview = payload.overview.compactMap(WidgetMetric.init(rawValue:))
        return WidgetConfig(rings: rings.isEmpty ? standard.rings : rings,
                            overview: overview.isEmpty ? standard.overview : overview)
    }

    private static func color(_ rgb: [Double]) -> Color {
        guard rgb.count == 3 else { return .primary }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    /// The app's `WidgetPayload`, mirrored: the extension links nothing of the app.
    private struct Payload: Decodable {
        struct Ring: Decodable {
            var metric: String
            var dark: [Double]
            var light: [Double]
        }
        var rings: [Ring]
        var overview: [String]
    }
}
