import WidgetKit
import SwiftUI

// MARK: - Timeline

struct ReadingEntry: TimelineEntry {
    let date: Date
    let reading: WidgetReading
    /// What the app asked the widgets to draw, read with the reading.
    var config: WidgetConfig = .standard
}

/// Each widget asks only for the readings it displays. The configurable widgets pass
/// no metrics and read what the app's settings ask for.
struct ReadingProvider: TimelineProvider {
    var metrics: WidgetReading.Metrics?
    /// How long an entry stands before macOS is asked for the next. macOS keeps a
    /// daily budget per widget and may stretch this; a monitor that pretends to be
    /// live would be lying, so every widget says when its reading was taken.
    static let refresh: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> ReadingEntry {
        ReadingEntry(date: .now, reading: .sample, config: metrics == nil ? .load() : .standard)
    }

    func getSnapshot(in context: Context, completion: @escaping (ReadingEntry) -> Void) {
        let config = metrics == nil ? WidgetConfig.load() : .standard
        if context.isPreview {
            completion(ReadingEntry(date: .now, reading: .sample, config: config))
            return
        }
        Task {
            let reading = await WidgetReading.take(metrics: metrics ?? config.needs)
            completion(ReadingEntry(date: reading.date, reading: reading, config: config))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReadingEntry>) -> Void) {
        let config = metrics == nil ? WidgetConfig.load() : .standard
        Task {
            let reading = await WidgetReading.take(metrics: metrics ?? config.needs)
            let entry = ReadingEntry(date: reading.date, reading: reading, config: config)
            completion(Timeline(entries: [entry], policy: .after(reading.date.addingTimeInterval(Self.refresh))))
        }
    }
}

extension WidgetReading {
    /// What the gallery shows before the widget is placed.
    static let sample = WidgetReading(
        date: .now,
        cpu: CPU(busy: 0.23, loadAverage: (2.1, 2.4, 2.6)),
        memory: Memory(usedBytes: 11_200_000_000, totalBytes: 18_000_000_000, pressure: 0.31),
        disk: Disk(availableBytes: 185_000_000_000, totalBytes: 494_000_000_000),
        battery: Battery(percent: 76, isCharging: false, isPluggedIn: false,
                         timeToEmpty: 4 * 3600 + 40 * 60, timeToFull: nil))
}

// MARK: - Widgets

/// The module a widget opens in the panel, as the app's `mustats://open/<module>`.
enum WidgetModule: String {
    case cpu, memory, disk, battery

    var url: URL { URL(string: "mustats://open/\(rawValue)")! }
}

/// Searchable as "muStats" too: the gallery matches descriptions, and typing a μ is
/// not something anyone does.
private func describe(_ text: String) -> String {
    "muStats · " + text
}

struct CPUWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "cpu", provider: ReadingProvider(metrics: .cpu)) { entry in
            CPUWidgetView(entry: entry)
        }
        .configurationDisplayName("CPU")
        .description(describe(String(localized: "How busy the processor was, and its load.")))
        .supportedFamilies([.systemSmall])
    }
}

struct MemoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "memory", provider: ReadingProvider(metrics: .memory)) { entry in
            MemoryWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Memory"))
        .description(describe(String(localized: "Memory in use and how much pressure it is under.")))
        .supportedFamilies([.systemSmall])
    }
}

struct DiskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "disk", provider: ReadingProvider(metrics: .disk)) { entry in
            DiskWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Disk"))
        .description(describe(String(localized: "Free space on the startup disk.")))
        .supportedFamilies([.systemSmall])
    }
}

struct BatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "battery", provider: ReadingProvider(metrics: .battery)) { entry in
            BatteryWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Battery"))
        .description(describe(String(localized: "Charge, and how long it will last.")))
        .supportedFamilies([.systemSmall])
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "overview", provider: ReadingProvider()) { entry in
            OverviewWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Overview"))
        .description(describe(String(localized: "The readings chosen in μStats at a glance.")))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct MuStatsWidgets: WidgetBundle {
    var body: some Widget {
        RingsWidget()
        OverviewWidget()
        CPUWidget()
        MemoryWidget()
        DiskWidget()
        BatteryWidget()
    }
}
