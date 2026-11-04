import Foundation

// MARK: - Lenient decoding

/// Decode a key, falling back to a default when it is missing *or malformed*.
///
/// Settings files get hand-edited, truncated by power loss, and written by older
/// builds. A single bad key must never cost the user their whole configuration,
/// so every property in this file decodes through here.
extension KeyedDecodingContainer {
    /// `try?` flattens the `T??` here, so a key that is absent and a key that fails
    /// to decode both land on `fallback` — which is exactly the desired behaviour.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        guard let decoded = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return decoded
    }
}

// MARK: - Units and formatting

public enum TemperatureUnit: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case celsius, fahrenheit

    public var label: String {
        switch self {
        case .celsius: return "Celsius (°C)"
        case .fahrenheit: return "Fahrenheit (°F)"
        }
    }
    public var suffix: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }
}

/// Network rates are conventionally quoted in bits (Mbps) by ISPs and bytes (MB/s)
/// by file transfer UI. Both are offered because both are "correct".
public enum NetworkRateUnit: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case bytes, bits

    public var label: String {
        switch self {
        case .bytes: return "Bytes per second (MB/s)"
        case .bits: return "Bits per second (Mbps)"
        }
    }
}

/// GiB (1024-based, what Activity Monitor's graphs use) vs GB (1000-based, what
/// Finder and Apple's marketing use).
/// Applies to STORAGE only. Physical memory is always formatted in binary units
/// because that is what Apple itself does (18 GB of RAM is 19,327,352,832 bytes).
public enum ByteUnitStyle: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case binary, decimal

    public var label: String {
        switch self {
        case .binary: return "Binary (1 GB = 1024 MB)"
        case .decimal: return "Decimal (1 GB = 1000 MB)"
        }
    }
    public var base: Double { self == .binary ? 1024 : 1000 }
}

public enum AppearanceMode: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case system, light, dark

    public var label: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

// MARK: - Menu bar

/// A single readout the user can place in the menu bar.
public enum MenuBarMetric: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case cpuUsage, cpuTemperature, cpuFrequency
    case memoryUsage, memoryPressure
    case gpuUsage
    case networkThroughput, networkUpload, networkDownload
    case diskActivity, diskFree, diskUsage
    case battery, batteryTime, systemPower
    case fanSpeed
    case uptime

    public var label: String {
        switch self {
        case .cpuUsage: return "CPU Usage"
        case .cpuTemperature: return "CPU Temperature"
        case .cpuFrequency: return "CPU Frequency"
        case .memoryUsage: return "Memory Usage"
        case .memoryPressure: return "Memory Pressure"
        case .gpuUsage: return "GPU Usage"
        case .networkThroughput: return "Network (Up & Down)"
        case .networkUpload: return "Network Upload"
        case .networkDownload: return "Network Download"
        case .diskActivity: return "Disk Activity"
        case .diskFree: return "Disk Free"
        case .diskUsage: return "Disk Usage"
        case .battery: return "Battery"
        case .batteryTime: return "Battery Time Remaining"
        case .systemPower: return "System Power"
        case .fanSpeed: return "Fan Speed"
        case .uptime: return "Uptime"
        }
    }

    /// Which collector must be running for this readout to have data.
    public var requiredSource: CollectorID {
        switch self {
        case .cpuUsage, .cpuFrequency: return .cpu
        case .cpuTemperature, .fanSpeed: return .thermal
        case .memoryUsage, .memoryPressure: return .memory
        case .gpuUsage: return .gpu
        case .networkThroughput, .networkUpload, .networkDownload: return .network
        case .diskActivity, .diskFree, .diskUsage: return .disk
        case .battery, .batteryTime, .systemPower: return .power
        case .uptime: return .system
        }
    }

    /// The Activity Monitor tab that answers "what is behind this number", by the index
    /// Activity Monitor stores as `SelectedTab`: CPU, Memory, Energy, Disk, Network.
    /// Temperature, frequency, fans and GPU land on CPU, which is where the processes
    /// heating the machine are ranked.
    public var activityMonitorTab: Int {
        switch self {
        case .cpuUsage, .cpuTemperature, .cpuFrequency, .gpuUsage, .fanSpeed, .uptime: return 0
        case .memoryUsage, .memoryPressure: return 1
        case .battery, .batteryTime, .systemPower: return 2
        case .diskActivity, .diskFree, .diskUsage: return 3
        case .networkThroughput, .networkUpload, .networkDownload: return 4
        }
    }

    /// Styles that make sense for this metric. Only the metrics that keep a series
    /// can be graphed; the rest are a number, with or without their icon.
    ///
    /// The first entry is the style this metric lands on when it has no valid one:
    /// a newly added readout, or one whose stored style this metric does not support.
    /// The readings a ring can draw: each a share of something with a ceiling.
    public static let ringMetrics: [MenuBarMetric] = [
        .cpuUsage, .memoryUsage, .memoryPressure, .gpuUsage, .diskUsage, .battery, .cpuTemperature,
    ]

    /// The ring's short name, under the rings and in the settings list.
    public var ringLabel: String {
        switch self {
        case .cpuUsage: return "CPU"
        case .memoryUsage: return "Memory"
        case .memoryPressure: return "Pressure"
        case .gpuUsage: return "GPU"
        case .diskUsage: return "Disk"
        case .battery: return "Battery"
        case .cpuTemperature: return "Temperature"
        default: return label
        }
    }

    public var supportedStyles: [MenuBarDisplayStyle] {
        switch self {
        case .uptime, .batteryTime, .cpuFrequency, .diskFree:
            return [.text, .iconAndText]
        case .battery:
            // The only metric the system's own indicator can draw, and the one it
            // should draw by default, so it leads the list.
            return [.battery] + MenuBarDisplayStyle.general
        case .networkThroughput:
            // The readout that is already two directions, so it is the one the
            // two lights can stand in for — and a pair is the only thing the
            // stacked style has to stack.
            return MenuBarDisplayStyle.general + [.statusDot, .stackedPair]
        case .diskActivity:
            // The other two-direction readout: read over write stacks the same
            // way up does over down.
            return MenuBarDisplayStyle.general + [.stackedPair]
        case .cpuUsage, .gpuUsage, .memoryUsage, .memoryPressure, .diskUsage:
            // The readouts that are a fraction of a known ceiling, which is the only
            // thing a fill level can honestly draw.
            return MenuBarDisplayStyle.general + [.bar]
        default:
            return MenuBarDisplayStyle.general
        }
    }
}

/// How one readout draws.
///
/// The general styles are the number, the number's history, and the number with a mark
/// saying which metric it is. The rest each draw one shape for the metrics that shape
/// can honestly stand for: the system battery indicator for the charge, two activity
/// lights for the up-and-down network readout, and a fill level for the readouts that
/// are a fraction of a known ceiling.
public enum MenuBarDisplayStyle: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case text
    case graph
    case miniGraph
    case textAndGraph
    case iconAndText
    case battery
    case statusDot
    case bar
    /// A paired readout drawn as two stacked rows — glyphs in one shared column,
    /// values right-aligned beside them — instead of both directions on one line.
    case stackedPair

    /// The styles any numeric readout can take. The indicator styles are left out
    /// because each draws one kind of metric and nothing else.
    public static let general: [MenuBarDisplayStyle] = [.text, .graph, .miniGraph, .textAndGraph, .iconAndText]

    public var label: String {
        switch self {
        case .text: return "Text"
        case .graph: return "Graph"
        case .miniGraph: return "Mini Graph"
        case .textAndGraph: return "Text & Graph"
        case .iconAndText: return "Icon & Text"
        case .battery: return "Battery Indicator"
        case .statusDot: return "Status Dot"
        case .bar: return "Compact Bar"
        case .stackedPair: return "Stacked Pair"
        }
    }

    /// Whether a caption would add anything. It would not for the two styles that
    /// already name their metric with a glyph, and the status dots are meant to be
    /// the smallest thing on the bar, so they carry no text at all. A bar is an
    /// anonymous shape, so the caption is what says which fraction it is. The
    /// stacked pair is already the two rows a 22-point bar fits — a caption on top
    /// would be a third.
    public var supportsCaption: Bool {
        switch self {
        case .text, .graph, .miniGraph, .textAndGraph, .bar: return true
        case .iconAndText, .battery, .statusDot, .stackedPair: return false
        }
    }

    /// Whether this style draws a historical graph series.
    public var showsGraph: Bool {
        self == .graph || self == .miniGraph || self == .textAndGraph
    }
}

public struct MenuBarItemConfig: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var metric: MenuBarMetric
    public var style: MenuBarDisplayStyle
    public var isEnabled: Bool
    /// Draw the metric's name above its number.
    public var showsCaption: Bool

    public init(id: UUID = UUID(), metric: MenuBarMetric, style: MenuBarDisplayStyle = .text,
                isEnabled: Bool = true, showsCaption: Bool = true) {
        self.id = id
        self.metric = metric
        self.style = style
        self.isEnabled = isEnabled
        self.showsCaption = showsCaption
    }

    /// Clamp a decoded config back into a coherent state — an old build may have
    /// stored a style this metric no longer supports.
    public func sanitized() -> MenuBarItemConfig {
        var copy = self
        if !metric.supportedStyles.contains(style) {
            copy.style = metric.supportedStyles.first ?? .text
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, metric, style, isEnabled, showsCaption
    }

    /// A hand-edited file may carry a style this metric does not support. That is not
    /// an error: `sanitized()` moves it to one the metric does.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID())
        metric = c.value(.metric, or: MenuBarMetric.cpuUsage)
        style = c.value(.style, or: MenuBarDisplayStyle.text)
        isEnabled = c.value(.isEnabled, or: true)
        showsCaption = c.value(.showsCaption, or: true)
    }
}

public struct MenuBarSettings: Sendable, Codable, Equatable {
    public var items: [MenuBarItemConfig]
    /// Use a single status item for everything (tidier, survives menu bar crowding)
    /// versus one status item per metric (individually re-orderable by the user).
    public var usesCombinedItem: Bool
    /// Off, and the app puts nothing in the menu bar at all: the panel is reached by
    /// its hot key, and Settings by launching the app again or by its hot key.
    public var isVisible: Bool
    /// The charge printed inside the battery indicator. On by default, the reason most
    /// people put a battery in a second status item at all; off, the indicator is the
    /// bare shape, as the system draws it until you ask for the number.
    public var showsBatteryPercentage: Bool
    /// Up to three concentric rings in place of every readout, in the manner of the
    /// Activity rings: each fills with one reading.
    public var showsRings: Bool
    /// The rings, outermost first. Always one to three, each a reading that is a
    /// fraction of something; see `MenuBarMetric.ringMetrics`.
    public var ringMetrics: [MenuBarMetric]

    /// The rings' colours.
    public var ringColors: RingColors
    /// A colour of the user's own per ring, outermost first, over the set's; nil keeps
    /// the set's. Always three entries, whatever the number of rings.
    public var customRingColors: [ThemeColor?]

    public static let defaultRingMetrics: [MenuBarMetric] = [.cpuUsage, .memoryUsage, .diskUsage]
    public static let maximumRings = 3

    /// Numbers are always set in a fixed-width face. Previously a toggle; a column of
    /// proportional digits shimmers as it changes, which is the single most visible
    /// cheapness tell in a stats app, and nobody was ever going to want it.
    public static let usesMonospacedDigits = true

    /// Four settings, gone. Each governed one dimension of how the bar is packed, and
    /// between them they were the reason a readout could move, resize or vanish while
    /// the user was looking at it — the one thing a menu bar must never do.
    ///
    /// Previously `usesFixedWidth`. Always on: without it every readout resizes as its
    /// own value changes and drags everything to its right along with it.
    public static let usesFixedWidth = true
    /// Previously `itemSpacing`, a 0–24 slider. 8 is the gap AppKit puts between its
    /// own status items, which is the gap this has to match to look like it belongs.
    public static let itemSpacing: Double = 8

    public init(items: [MenuBarItemConfig] = MenuBarSettings.defaultItems,
                usesCombinedItem: Bool = true,
                isVisible: Bool = true,
                showsBatteryPercentage: Bool = true,
                showsRings: Bool = false,
                ringMetrics: [MenuBarMetric] = MenuBarSettings.defaultRingMetrics,
                ringColors: RingColors = .aurora,
                customRingColors: [ThemeColor?] = []) {
        self.items = items
        self.usesCombinedItem = usesCombinedItem
        self.isVisible = isVisible
        self.showsBatteryPercentage = showsBatteryPercentage
        self.showsRings = showsRings
        self.ringMetrics = MenuBarSettings.sanitizedRings(ringMetrics)
        self.ringColors = ringColors
        self.customRingColors = MenuBarSettings.sanitizedRingColors(customRingColors)
    }

    public static func sanitizedRingColors(_ colors: [ThemeColor?]) -> [ThemeColor?] {
        Array((colors + Array(repeating: nil, count: maximumRings)).prefix(maximumRings))
    }

    /// The readouts drawn beside the rings: every enabled one, less those whose reading
    /// is already a ring, so CPU, memory and disk as rings leave the temperature and
    /// the network as text.
    public var readoutsBesideRings: [MenuBarItemConfig] {
        guard showsRings else { return enabledItems }
        return enabledItems.filter { !ringMetrics.contains($0.metric) }
    }

    /// One to three distinct ring-capable readings, in order.
    public static func sanitizedRings(_ metrics: [MenuBarMetric]) -> [MenuBarMetric] {
        var seen = Set<MenuBarMetric>()
        let kept = metrics.filter { MenuBarMetric.ringMetrics.contains($0) && seen.insert($0).inserted }
        return kept.isEmpty ? defaultRingMetrics : Array(kept.prefix(maximumRings))
    }

    /// CPU, memory and disk as captioned bars, the CPU temperature as a number, and
    /// network as a stacked pair.
    ///
    /// The three bars pack into one group, so the resources that fill up read
    /// together at a glance. Temperature is a reading rather than a level, so it
    /// stays a number. Network is two directions, and stacked they cost the width
    /// of one readout.
    ///
    /// The battery is listed but off: one click in Settings brings back the system's
    /// own indicator for those on a laptop who want it.
    public static let defaultItems: [MenuBarItemConfig] = [
        MenuBarItemConfig(metric: .cpuUsage, style: .bar, showsCaption: true),
        MenuBarItemConfig(metric: .memoryUsage, style: .bar, showsCaption: true),
        MenuBarItemConfig(metric: .diskUsage, style: .bar, showsCaption: true),
        MenuBarItemConfig(metric: .cpuTemperature, style: .text, showsCaption: true),
        MenuBarItemConfig(metric: .networkThroughput, style: .stackedPair, showsCaption: true),
        MenuBarItemConfig(metric: .battery, style: .battery, isEnabled: false, showsCaption: false),
    ]

    public var enabledItems: [MenuBarItemConfig] { items.filter(\.isEnabled) }

    private enum CodingKeys: String, CodingKey {
        case items, usesCombinedItem, isVisible, showsBatteryPercentage, showsRings, ringMetrics
        case ringColors, customRingColors
    }

    /// Files written before the packing settings were removed still load: the keys
    /// they carry for spacing, fixed width and quiet mode are simply not read, and an
    /// unknown key has never been an error here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedItems = c.value(.items, or: MenuBarSettings.defaultItems)
        // An empty menu bar would leave the user with no way back into the app.
        items = decodedItems.isEmpty ? MenuBarSettings.defaultItems : decodedItems.map { $0.sanitized() }
        usesCombinedItem = c.value(.usesCombinedItem, or: true)
        isVisible = c.value(.isVisible, or: true)
        showsBatteryPercentage = c.value(.showsBatteryPercentage, or: true)
        showsRings = c.value(.showsRings, or: false)
        ringMetrics = MenuBarSettings.sanitizedRings(c.value(.ringMetrics, or: MenuBarSettings.defaultRingMetrics))
        ringColors = c.value(.ringColors, or: RingColors.aurora)
        customRingColors = MenuBarSettings.sanitizedRingColors(c.value(.customRingColors, or: []))
    }
}

/// The rings' colour sets, outermost ring first.
public enum RingColors: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case aurora, ocean, sunset, neon, mono, fitness

    public var label: String {
        switch self {
        case .aurora: return "Aurora"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .neon: return "Neon"
        case .mono: return "Mono"
        case .fitness: return "Fitness"
        }
    }

    /// One ring's tone, from the user's own colour when there is one. Their colour
    /// is what a dark bar shows; a light bar gets it darkened, as the sets are.
    public func tone(ring index: Int, custom: [ThemeColor?] = [], onDark: Bool) -> (Double, Double, Double) {
        if index < custom.count, let own = custom[index] {
            let rgb = (own.red, own.green, own.blue)
            return onDark ? rgb : (rgb.0 * Self.lightShade, rgb.1 * Self.lightShade, rgb.2 * Self.lightShade)
        }
        let tone = tones[index % tones.count]
        return onDark ? tone.dark : tone.light
    }

    /// How much darker a custom colour is drawn on a light bar: about the step between
    /// the sets' own dark and light tones.
    static let lightShade = 0.78

    /// Red, green, blue in 0...1 for each ring, as (on a dark surface, on a light one).
    /// The light tones are darker so that pale hues still read on a light menu bar.
    public var tones: [(dark: (Double, Double, Double), light: (Double, Double, Double))] {
        switch self {
        case .aurora:
            return [((0.66, 0.50, 1.00), (0.45, 0.27, 0.86)),
                    ((0.25, 0.86, 0.76), (0.00, 0.56, 0.50)),
                    ((1.00, 0.76, 0.28), (0.80, 0.50, 0.00))]
        case .ocean:
            return [((0.27, 0.55, 1.00), (0.05, 0.35, 0.86)),
                    ((0.36, 0.80, 1.00), (0.00, 0.55, 0.80)),
                    ((0.46, 0.95, 0.80), (0.00, 0.60, 0.48))]
        case .sunset:
            return [((1.00, 0.42, 0.36), (0.86, 0.22, 0.14)),
                    ((1.00, 0.64, 0.22), (0.84, 0.42, 0.00)),
                    ((1.00, 0.86, 0.34), (0.70, 0.55, 0.00))]
        case .neon:
            return [((1.00, 0.34, 0.84), (0.80, 0.08, 0.64)),
                    ((0.76, 1.00, 0.30), (0.40, 0.64, 0.00)),
                    ((0.42, 0.56, 1.00), (0.16, 0.30, 0.90))]
        case .mono:
            return [((0.96, 0.96, 0.96), (0.10, 0.10, 0.10)),
                    ((0.74, 0.74, 0.74), (0.34, 0.34, 0.34)),
                    ((0.54, 0.54, 0.54), (0.56, 0.56, 0.56))]
        case .fitness:
            return [((0.98, 0.07, 0.31), (0.88, 0.00, 0.24)),
                    ((0.57, 0.91, 0.16), (0.30, 0.66, 0.00)),
                    ((0.12, 0.92, 0.94), (0.00, 0.62, 0.72))]
        }
    }
}

// MARK: - Widgets

/// What the desktop widgets show.
///
/// The widgets run in a sandboxed extension that cannot read this store. The app
/// hands them a `WidgetPayload` instead, in a file the extension's sandbox is allowed
/// to read, and asks macOS to redraw them whenever it changes.
public struct WidgetSettings: Sendable, Codable, Equatable {
    /// The Rings widget draws the menu bar's rings, less any the extension cannot
    /// read; off, it draws `ringMetrics`.
    public var ringsFollowMenuBar: Bool
    public var ringMetrics: [MenuBarMetric]
    /// The Overview widget's rows, in order.
    public var overviewMetrics: [MenuBarMetric]

    /// What the extension can read itself, from the kernel and IOKit, in the few
    /// milliseconds macOS gives it. Temperature and GPU need the app's collectors.
    public static let metrics: [MenuBarMetric] = [.cpuUsage, .memoryUsage, .memoryPressure, .diskUsage, .battery]
    public static let defaultOverview: [MenuBarMetric] = [.cpuUsage, .memoryUsage, .diskUsage, .battery]

    public init(ringsFollowMenuBar: Bool = true,
                ringMetrics: [MenuBarMetric] = MenuBarSettings.defaultRingMetrics,
                overviewMetrics: [MenuBarMetric] = WidgetSettings.defaultOverview) {
        self.ringsFollowMenuBar = ringsFollowMenuBar
        self.ringMetrics = WidgetSettings.sanitizedRings(ringMetrics)
        self.overviewMetrics = WidgetSettings.sanitizedOverview(overviewMetrics)
    }

    /// One to three distinct readings the extension can draw as a ring.
    public static func sanitizedRings(_ list: [MenuBarMetric]) -> [MenuBarMetric] {
        var seen = Set<MenuBarMetric>()
        let kept = list.filter { metrics.contains($0) && seen.insert($0).inserted }
        return kept.isEmpty ? MenuBarSettings.defaultRingMetrics : Array(kept.prefix(MenuBarSettings.maximumRings))
    }

    /// Distinct readings the extension can draw, in metric order; at least one.
    public static func sanitizedOverview(_ list: [MenuBarMetric]) -> [MenuBarMetric] {
        let kept = metrics.filter(list.contains)
        return kept.isEmpty ? defaultOverview : kept
    }

    private enum CodingKeys: String, CodingKey { case ringsFollowMenuBar, ringMetrics, overviewMetrics }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ringsFollowMenuBar: c.value(.ringsFollowMenuBar, or: true),
                  ringMetrics: c.value(.ringMetrics, or: MenuBarSettings.defaultRingMetrics),
                  overviewMetrics: c.value(.overviewMetrics, or: WidgetSettings.defaultOverview))
    }
}

/// Everything the widget extension needs from the app, resolved: which readings, and
/// each ring's colour on a dark and a light desktop. Plain names and numbers, so the
/// extension decodes it without linking any of the app.
public struct WidgetPayload: Codable, Equatable, Sendable {
    public struct Ring: Codable, Equatable, Sendable {
        public var metric: String
        /// Red, green, blue in 0...1.
        public var dark: [Double]
        public var light: [Double]
    }

    public var rings: [Ring]
    public var overview: [String]

    public static let fileName = "widget.json"

    public init(settings: Settings) {
        let widgets = settings.widgets
        let menuBar = settings.menuBar
        var metrics = widgets.ringMetrics
        if widgets.ringsFollowMenuBar {
            let readable = menuBar.ringMetrics.filter(WidgetSettings.metrics.contains)
            metrics = readable.isEmpty ? MenuBarSettings.defaultRingMetrics : readable
        }
        rings = metrics.enumerated().compactMap { index, metric in
            guard let name = WidgetPayload.name(of: metric) else { return nil }
            let dark = menuBar.ringColors.tone(ring: index, custom: menuBar.customRingColors, onDark: true)
            let light = menuBar.ringColors.tone(ring: index, custom: menuBar.customRingColors, onDark: false)
            return Ring(metric: name, dark: [dark.0, dark.1, dark.2], light: [light.0, light.1, light.2])
        }
        overview = widgets.overviewMetrics.compactMap(WidgetPayload.name(of:))
    }

    /// The extension's name for a reading.
    public static func name(of metric: MenuBarMetric) -> String? {
        switch metric {
        case .cpuUsage: return "cpu"
        case .memoryUsage: return "memory"
        case .memoryPressure: return "pressure"
        case .diskUsage: return "disk"
        case .battery: return "battery"
        default: return nil
        }
    }
}

// MARK: - Panel

public enum PanelModule: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case cpu, memory, gpu, network, disk, battery, thermal, processes, system

    public var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .network: return "Network"
        case .disk: return "Disk"
        case .battery: return "Battery"
        case .thermal: return "Temperature"
        case .processes: return "Top Processes"
        case .system: return "System"
        }
    }

    public var requiredSource: CollectorID {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .gpu: return .gpu
        case .network: return .network
        case .disk: return .disk
        case .battery: return .power
        case .thermal: return .thermal
        case .processes: return .processes
        case .system: return .system
        }
    }

    public var symbolName: String { requiredSource.symbolName }

    /// The Activity Monitor tab that ranks processes by what this module measures.
    public var activityMonitorTab: Int {
        switch self {
        case .cpu, .gpu, .thermal, .processes, .system: return 0
        case .memory: return 1
        case .battery: return 2
        case .disk: return 3
        case .network: return 4
        }
    }
}

/// What the panel remembers between openings.
///
/// The panel used to be configurable — module order, which modules were on, width,
/// process row count and sort, sparklines, focus behaviour. All of it is gone: the
/// panel is a glance surface reached by one click, and a settings pane with eight
/// controls governing it was more configuration than the surface earns. What remains
/// is the one piece of state the user still sets, and they set it by clicking a
/// heading in the panel itself rather than by opening a window.
public struct PanelSettings: Sendable, Codable, Equatable {
    /// Modules the user has collapsed to just their summary row.
    public var collapsedModules: Set<PanelModule>
    /// Draw the history chart under an expanded module's rows.
    public var showsHistoryChart: Bool
    /// The default range when opening a history chart in the panel.
    public var defaultHistoryRange: HistoryRange
    /// Highlight warning and critical metrics with orange and red tint in the panel.
    public var showsAlertColors: Bool
    /// The order the user dragged the modules into. Empty until they first do, and
    /// read through `visibleModules`, which drops what a newer build removed and
    /// appends what it added, so a stored order never needs migrating.
    public var moduleOrder: [PanelModule]
    /// The "Today" card: the day's CPU with its notable stretches pinned on it.
    public var showsToday: Bool
    /// Listening ports and Docker in the network module. Nil until the user decides,
    /// which reads as on for a Mac with developer tools installed and off otherwise.
    public var showsDeveloperTools: Bool?

    /// Whether the developer readings are on, deciding for the user until they have.
    public var developerToolsShown: Bool { showsDeveloperTools ?? DeveloperEnvironment.isPresent }
    /// The live chip tab: the processor drawn and lit by the readings. An extra.
    public var showsLiveChip: Bool

    /// Fixed layout, previously the `width` setting. 380pt gives a detail grid three
    /// columns and a process name room beside its icon, and still leaves the panel
    /// narrower than the narrowest MacBook screen at any status item position.
    public static let width: Double = 380
    /// Previously `processRowCount` and `processSortKey`.
    public static let processRowCount = 5
    public static let processSortKey: ProcessSortKey = .cpu

    public init(collapsedModules: Set<PanelModule> = PanelSettings.defaultCollapsed,
                showsHistoryChart: Bool = true,
                defaultHistoryRange: HistoryRange = .hour,
                showsAlertColors: Bool = true,
                moduleOrder: [PanelModule] = [],
                showsToday: Bool = true,
                showsDeveloperTools: Bool? = nil,
                showsLiveChip: Bool = false) {
        self.collapsedModules = Self.accordion(collapsedModules)
        self.showsHistoryChart = showsHistoryChart
        self.defaultHistoryRange = defaultHistoryRange
        self.showsAlertColors = showsAlertColors
        self.moduleOrder = moduleOrder
        self.showsToday = showsToday
        self.showsDeveloperTools = showsDeveloperTools
        self.showsLiveChip = showsLiveChip
    }

    /// The collapsed set after a click on `module`'s header.
    ///
    /// One module open at a time. Opening a second one used to stack its detail under
    /// the first, and with charts under every module the panel ran off a 13-inch
    /// screen by the third click. Opening a module now closes whichever one was open,
    /// so the panel is never taller than the list plus one detail.
    public func collapsedModules(toggling module: PanelModule) -> Set<PanelModule> {
        if collapsedModules.contains(module) {
            return Set(PanelModule.allCases).subtracting([module])
        }
        return Set(PanelModule.allCases)
    }

    /// At most one module open. A settings file written before the accordion may hold
    /// several; the first in panel order keeps its place and the rest close.
    static func accordion(_ collapsed: Set<PanelModule>) -> Set<PanelModule> {
        guard let open = PanelModule.allCases.first(where: { !collapsed.contains($0) }) else {
            return collapsed
        }
        return Set(PanelModule.allCases).subtracting([open])
    }

    /// Every module starts collapsed.
    ///
    /// A collapsed module still shows its heading and its headline value, so nothing
    /// glanceable is lost — only the detail rows are hidden. Collapsed it reads as a
    /// summary you can scan, and the detail is one click away where the user actually
    /// wants it.
    ///
    /// CPU and Memory used to be left open, on the reasoning that a panel opening to
    /// nothing but headings looks inert. It reads as an inconsistency instead: two
    /// modules are already showing detail nobody asked for, the panel opens at an
    /// awkward in-between height, and the two that happen to be open are the two
    /// someone chose years ago rather than the two this user cares about. Uniformly
    /// closed is the shorter, quieter, more predictable panel — and every module is
    /// one click from open.
    public static let defaultCollapsed: Set<PanelModule> = Set(PanelModule.allCases)

    /// Every module, in the user's order. Modules the stored order does not name, a
    /// new release's or all of them before the first drag, follow in declaration order.
    public var visibleModules: [PanelModule] {
        var seen = Set<PanelModule>()
        let ordered = moduleOrder.filter { seen.insert($0).inserted }
        return ordered + PanelModule.allCases.filter { !seen.contains($0) }
    }

    /// The order after `module` is dropped onto `target`: it takes the target's place
    /// and everything from there moves down one.
    public func moduleOrder(moving module: PanelModule, before target: PanelModule) -> [PanelModule] {
        guard module != target else { return visibleModules }
        var order = visibleModules.filter { $0 != module }
        let index = order.firstIndex(of: target) ?? order.endIndex
        let movingDown = (visibleModules.firstIndex(of: module) ?? 0) < (visibleModules.firstIndex(of: target) ?? 0)
        order.insert(module, at: movingDown ? min(index + 1, order.endIndex) : index)
        return order
    }

    private enum CodingKeys: String, CodingKey {
        case collapsedModules, showsHistoryChart, defaultHistoryRange, showsAlertColors, moduleOrder, showsToday
        case showsDeveloperTools, showsLiveChip
    }

    /// Decoded leniently, and settings files written before the panel pane was removed
    /// still load: the keys they carry for order, width and the rest are simply not
    /// read, and an unknown key has never been an error here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collapsedModules = Self.accordion(c.value(.collapsedModules, or: PanelSettings.defaultCollapsed))
        showsHistoryChart = c.value(.showsHistoryChart, or: true)
        defaultHistoryRange = c.value(.defaultHistoryRange, or: .hour)
        showsAlertColors = c.value(.showsAlertColors, or: true)
        moduleOrder = c.value(.moduleOrder, or: [])
        showsToday = c.value(.showsToday, or: true)
        showsDeveloperTools = try? c.decodeIfPresent(Bool.self, forKey: .showsDeveloperTools)
        showsLiveChip = c.value(.showsLiveChip, or: false)
    }
}

// MARK: - History Range

/// Which window a history chart is showing.
///
/// Fixed ranges: the first is whatever "Keep history for" is set to (e.g. 5m);
/// the rest are the spans the bucket tiers keep — an hour of the day's minutes,
/// the day itself (24h), and the month of hours (30d).
public enum HistoryRange: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case recent
    case hour
    case day
    case month

    /// "5m", "1h", "24h": short enough for a segment control in a chart footer.
    public static func label(forSpan span: TimeInterval) -> String {
        if span < 60 { return "\(Int(span.rounded()))s" }
        if span < 3_600 { return "\(Int((span / 60).rounded()))m" }
        let hours = span / 3_600
        return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    /// Display label for settings pickers: e.g. "5 min (Recent)", "1h (1 Hour)", etc.
    public func label(historyDuration: TimeInterval = 300) -> String {
        switch self {
        case .recent:
            let span = HistoryRange.label(forSpan: historyDuration)
            let spanLabel = span == "5m" ? "5 min" : span
            return "\(spanLabel) (Recent)"
        case .hour:
            return "1h (1 Hour)"
        case .day:
            return "24h (24 Hours)"
        case .month:
            return "30d (30 Days)"
        }
    }

    /// What an empty plot says it is still gathering.
    public var collectingText: String {
        switch self {
        case .day: return "Collecting the day…"
        case .month: return "Collecting the month…"
        case .recent, .hour: return "Collecting samples…"
        }
    }

    /// The span words the spoken summary uses, or nil to fall back to a measured
    /// "last N" caption: only the bucket windows whose span is exact get a name.
    public var summaryWindow: String? {
        switch self {
        case .hour: return "the last hour"
        case .day: return "the last 24 hours"
        case .month: return "the last 30 days"
        case .recent: return nil
        }
    }
}

// MARK: - Charts

public enum ChartStyle: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case line, filledLine, bars

    public var label: String {
        switch self {
        case .line: return "Line"
        case .filledLine: return "Filled Line"
        case .bars: return "Bars"
        }
    }
}

/// What the charts remember.
///
/// Two settings, where there were six. Grid, value labels, curve smoothing and
/// adaptive scaling were each a toggle governing one detail of how a 28-point
/// sparkline is drawn — four decisions the app is better placed to make than the
/// user, and four rows of settings standing between them and the two that change
/// what a chart actually says. They are constants now, at the values every one of
/// them shipped switched on.
public struct ChartSettings: Sendable, Codable, Equatable {
    /// Seconds of history retained and drawn.
    public var historyDuration: TimeInterval
    public var style: ChartStyle

    /// Previously `showsGrid`.
    public static let showsGrid = true
    /// Previously `usesAdaptiveScale`: rate charts scale to the peak in the window,
    /// because a rate has no maximum to scale against instead.
    public static let usesAdaptiveScale = true
    /// Previously `showsValueLabels`.
    public static let showsValueLabels = true
    /// Previously `smoothsCurves`. Smooths the drawn line only; samples are never
    /// averaged, so a spike is still a spike in the number beside it.
    public static let smoothsCurves = true

    public init(historyDuration: TimeInterval = 300,
                style: ChartStyle = .filledLine) {
        self.historyDuration = historyDuration
        self.style = style
    }

    public static let allowedDurations: [TimeInterval] = [60, 300, 600, 1800, 3600]

    private enum CodingKeys: String, CodingKey {
        case historyDuration, style
    }

    /// Files written before the drawing toggles were removed still load: the keys they
    /// carry are simply not read, and an unknown key has never been an error here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        historyDuration = min(max(c.value(.historyDuration, or: 300.0), 30), 3600)
        style = c.value(.style, or: ChartStyle.filledLine)
    }
}

// MARK: - Notifications

public enum ThresholdMetric: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case cpuUsage, memoryPressure, diskFree, batteryLow, batteryFull, cpuTemperature, thermalPressure

    public var label: String {
        switch self {
        case .cpuUsage: return "Sustained CPU usage above"
        case .memoryPressure: return "Memory pressure above"
        case .diskFree: return "Startup disk free space below"
        case .batteryLow: return "Battery drops below"
        case .batteryFull: return "Battery reaches"
        case .cpuTemperature: return "CPU temperature above"
        case .thermalPressure: return "Thermal pressure reaches"
        }
    }

    public var unitSuffix: String {
        switch self {
        case .cpuUsage, .memoryPressure, .batteryLow, .batteryFull: return "%"
        case .diskFree: return "GB"
        case .cpuTemperature: return "°"
        case .thermalPressure: return ""
        }
    }

    public var defaultThreshold: Double {
        switch self {
        case .cpuUsage: return 90
        case .memoryPressure: return 80
        case .diskFree: return 10
        case .batteryLow: return 20
        case .batteryFull: return 100
        case .cpuTemperature: return 95
        case .thermalPressure: return 2
        }
    }

    public var requiredSource: CollectorID {
        switch self {
        case .cpuUsage: return .cpu
        case .memoryPressure: return .memory
        case .diskFree: return .disk
        case .batteryLow, .batteryFull: return .power
        case .cpuTemperature, .thermalPressure: return .thermal
        }
    }
}

public struct ThresholdRule: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var metric: ThresholdMetric
    public var threshold: Double
    public var isEnabled: Bool
    /// Seconds the condition must hold before notifying, so a one-second CPU spike
    /// while launching an app does not fire an alert.
    public var sustainedFor: TimeInterval
    /// Minimum seconds between repeat notifications for this rule.
    public var cooldown: TimeInterval

    public init(id: UUID = UUID(), metric: ThresholdMetric, threshold: Double? = nil,
                isEnabled: Bool = false, sustainedFor: TimeInterval = 30,
                cooldown: TimeInterval = 900) {
        self.id = id
        self.metric = metric
        self.threshold = threshold ?? metric.defaultThreshold
        self.isEnabled = isEnabled
        self.sustainedFor = sustainedFor
        self.cooldown = cooldown
    }

    private enum CodingKeys: String, CodingKey {
        case id, metric, threshold, isEnabled, sustainedFor, cooldown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID())
        metric = c.value(.metric, or: ThresholdMetric.cpuUsage)
        threshold = c.value(.threshold, or: metric.defaultThreshold)
        isEnabled = c.value(.isEnabled, or: false)
        sustainedFor = min(max(c.value(.sustainedFor, or: 30.0), 0), 3600)
        cooldown = min(max(c.value(.cooldown, or: 900.0), 60), 86400)
    }
}

public struct NotificationSettings: Sendable, Codable, Equatable {
    public var isEnabled: Bool
    public var rules: [ThresholdRule]
    /// Edge-triggered rather than a threshold: alert when the fetched public IP
    /// differs from the last one seen. Only meaningful while
    /// `general.fetchesPublicIP` is on, since there is no address to watch otherwise.
    public var notifiesOnPublicIPChange: Bool
    /// Alert on every change of the primary link: to no connectivity and back to
    /// one. `connectionType` is free in the snapshot, so the watch costs a compare.
    public var notifiesOnConnectivityChange: Bool
    /// A process keeping a whole core busy for ten minutes while nobody is at the Mac.
    public var notifiesOnRunaway: Bool
    /// A reading well outside what this Mac does at this hour, learnt from its month.
    public var notifiesOnUnusual: Bool
    /// On unplugging, a word when something is drawing enough to cut the battery short.
    public var notifiesOnHeavyUnplug: Bool
    /// Processes the user asked not to hear about again, by name.
    public var ignoredRunaways: [String]

    public init(isEnabled: Bool = false, rules: [ThresholdRule] = NotificationSettings.defaultRules,
                notifiesOnPublicIPChange: Bool = false, notifiesOnConnectivityChange: Bool = false,
                notifiesOnRunaway: Bool = true, notifiesOnUnusual: Bool = true,
                notifiesOnHeavyUnplug: Bool = true, ignoredRunaways: [String] = []) {
        self.isEnabled = isEnabled
        self.rules = rules
        self.notifiesOnPublicIPChange = notifiesOnPublicIPChange
        self.notifiesOnConnectivityChange = notifiesOnConnectivityChange
        self.notifiesOnRunaway = notifiesOnRunaway
        self.notifiesOnUnusual = notifiesOnUnusual
        self.notifiesOnHeavyUnplug = notifiesOnHeavyUnplug
        self.ignoredRunaways = ignoredRunaways
    }

    public static var defaultRules: [ThresholdRule] {
        ThresholdMetric.allCases.map { ThresholdRule(metric: $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, rules, notifiesOnPublicIPChange, notifiesOnConnectivityChange
        case notifiesOnRunaway, notifiesOnUnusual, notifiesOnHeavyUnplug, ignoredRunaways
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.value(.isEnabled, or: false)
        notifiesOnPublicIPChange = c.value(.notifiesOnPublicIPChange, or: false)
        notifiesOnConnectivityChange = c.value(.notifiesOnConnectivityChange, or: false)
        notifiesOnRunaway = c.value(.notifiesOnRunaway, or: true)
        notifiesOnUnusual = c.value(.notifiesOnUnusual, or: true)
        notifiesOnHeavyUnplug = c.value(.notifiesOnHeavyUnplug, or: true)
        ignoredRunaways = c.value(.ignoredRunaways, or: [String]())
        var decoded = c.value(.rules, or: NotificationSettings.defaultRules)
        // Add rules for any metric introduced since the file was written.
        let present = Set(decoded.map(\.metric))
        for metric in ThresholdMetric.allCases where !present.contains(metric) {
            decoded.append(ThresholdRule(metric: metric))
        }
        rules = decoded
    }

    public var enabledRules: [ThresholdRule] { rules.filter(\.isEnabled) }
}

// MARK: - Shortcuts

/// A recorded key combination. Stored as a raw key code plus modifier bitmask so it
/// survives keyboard layout changes.
public struct KeyboardShortcut: Sendable, Codable, Equatable, Hashable {
    public var keyCode: UInt16
    public var modifierFlags: UInt
    public var characters: String

    public init(keyCode: UInt16, modifierFlags: UInt, characters: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.characters = characters
    }
}

public enum ShortcutAction: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case togglePanel = "togglePanel"
    case toggleMenuBarItem = "toggleMenuBarItem"
    case openSettings = "openSettings"

    public var label: String {
        switch self {
        case .togglePanel: return "Show / Hide Panel"
        case .toggleMenuBarItem: return "Show / Hide Menu Bar Item"
        case .openSettings: return "Open Settings"
        }
    }
}

public struct ShortcutSettings: Sendable, Codable, Equatable {
    public var bindings: [ShortcutAction: KeyboardShortcut]

    public init(bindings: [ShortcutAction: KeyboardShortcut] = [:]) {
        self.bindings = bindings
    }

    private enum CodingKeys: String, CodingKey { case bindings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bindings = c.value(.bindings, or: [:])
    }
}

// MARK: - General

public struct GeneralSettings: Sendable, Codable, Equatable {
    /// Seconds between sampling cycles. Individual collectors may run slower.
    public var updateInterval: TimeInterval
    public var launchAtLogin: Bool
    public var appearance: AppearanceMode
    public var temperatureUnit: TemperatureUnit
    public var networkRateUnit: NetworkRateUnit
    public var byteUnitStyle: ByteUnitStyle
    public var showsPercentSign: Bool
    /// Drop to a quarter cadence when the menu bar item is not visible.
    public var throttlesWhenOccluded: Bool
    /// Suspend sampling entirely while on battery below a threshold.
    public var pausesOnLowPower: Bool
    /// Once a second while the panel is open, so its details are live. Off, the panel
    /// keeps the same pace as the menu bar.
    public var livePanel: Bool
    /// Fetch the public IP address. One of the two features that leave the machine,
    /// the other being Sparkle's update check, which keeps its own preference.
    public var fetchesPublicIP: Bool
    public var showsDockIcon: Bool

    public init(updateInterval: TimeInterval = 2,
                launchAtLogin: Bool = true,
                appearance: AppearanceMode = .system,
                temperatureUnit: TemperatureUnit = .celsius,
                networkRateUnit: NetworkRateUnit = .bytes,
                byteUnitStyle: ByteUnitStyle = .decimal,
                showsPercentSign: Bool = true,
                throttlesWhenOccluded: Bool = true,
                pausesOnLowPower: Bool = false,
                livePanel: Bool = true,
                fetchesPublicIP: Bool = false,
                showsDockIcon: Bool = false) {
        self.updateInterval = updateInterval
        self.launchAtLogin = launchAtLogin
        self.appearance = appearance
        self.temperatureUnit = temperatureUnit
        self.networkRateUnit = networkRateUnit
        self.byteUnitStyle = byteUnitStyle
        self.showsPercentSign = showsPercentSign
        self.throttlesWhenOccluded = throttlesWhenOccluded
        self.pausesOnLowPower = pausesOnLowPower
        self.livePanel = livePanel
        self.fetchesPublicIP = fetchesPublicIP
        self.showsDockIcon = showsDockIcon
    }

    public static let allowedIntervals: [TimeInterval] = [0.5, 1, 2, 3, 5, 10, 30]

    private enum CodingKeys: String, CodingKey {
        case updateInterval, launchAtLogin, appearance, temperatureUnit, networkRateUnit
        case byteUnitStyle, showsPercentSign, throttlesWhenOccluded, pausesOnLowPower, livePanel
        case fetchesPublicIP, showsDockIcon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updateInterval = min(max(c.value(.updateInterval, or: 2.0), 0.5), 60)
        launchAtLogin = c.value(.launchAtLogin, or: false)
        appearance = c.value(.appearance, or: AppearanceMode.system)
        temperatureUnit = c.value(.temperatureUnit, or: TemperatureUnit.celsius)
        networkRateUnit = c.value(.networkRateUnit, or: NetworkRateUnit.bytes)
        byteUnitStyle = c.value(.byteUnitStyle, or: ByteUnitStyle.decimal)
        showsPercentSign = c.value(.showsPercentSign, or: true)
        throttlesWhenOccluded = c.value(.throttlesWhenOccluded, or: true)
        pausesOnLowPower = c.value(.pausesOnLowPower, or: false)
        livePanel = c.value(.livePanel, or: true)
        fetchesPublicIP = c.value(.fetchesPublicIP, or: false)
        showsDockIcon = c.value(.showsDockIcon, or: false)
    }
}

// MARK: - Root

// MARK: - Theme

/// One user-chosen colour, stored as sRGB components.
///
/// Components rather than a hex string because that is what `ColorPicker` hands back
/// and what `NSColor` wants, and round-tripping through hex would quantise a colour
/// the user picked to eight bits per channel every time the file was written.
public struct ThemeColor: Sendable, Codable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case red, green, blue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(red: c.value(.red, or: 0.5),
                  green: c.value(.green, or: 0.5),
                  blue: c.value(.blue, or: 0.5))
    }
}

/// User overrides for the app's colours.
///
/// Every field is optional, and nil means "use what the app shipped". That is the
/// whole design: the defaults are Apple's semantic system colours, which already
/// track light, dark, increased-contrast and vibrancy correctly, and a stored copy
/// of one of them would freeze it at whatever it resolved to on the day it was
/// picked. So an untouched install stores nothing and keeps following the system;
/// only a colour the user deliberately chose is written down.
public struct ThemeSettings: Sendable, Codable, Equatable {
    /// Per-metric identity colours, keyed by `CollectorID.rawValue`.
    ///
    /// Keyed by the raw string rather than by `CollectorID` so a collector that is
    /// renamed or removed in a later build leaves an ignorable entry behind instead
    /// of failing the whole decode.
    ///
    /// The one thing this type stores. The accent colour was editable here too, and
    /// should not have been: selection is a system-wide choice the user already made
    /// in System Settings, and an app that quietly disagrees with it is not theming
    /// itself, it is ignoring them. A previously stored `accent` key decodes to
    /// nothing and is dropped on the next save.
    public var metrics: [String: ThemeColor]

    public init(metrics: [String: ThemeColor] = [:]) {
        self.metrics = metrics
    }

    public func color(for id: CollectorID) -> ThemeColor? { metrics[id.rawValue] }

    public mutating func setColor(_ color: ThemeColor?, for id: CollectorID) {
        metrics[id.rawValue] = color
    }

    /// Puts every metric on one colour, or back on the colours the app ships with.
    ///
    /// Nil clears the whole dictionary rather than writing nine copies of a default:
    /// an absent entry is what makes a metric follow Apple's semantic colour through
    /// appearance and contrast changes, and a stored copy of that colour would not.
    public mutating func setAllColors(_ color: ThemeColor?) {
        guard let color else { metrics.removeAll(); return }
        for id in CollectorID.allCases { metrics[id.rawValue] = color }
    }

    /// The single colour every metric is currently set to, or nil if any is on its
    /// default or differs from the rest.
    public var uniformColor: ThemeColor? {
        var shared: ThemeColor?
        for id in CollectorID.allCases {
            guard let color = metrics[id.rawValue] else { return nil }
            if let shared, shared != color { return nil }
            shared = color
        }
        return shared
    }

    private enum CodingKeys: String, CodingKey { case metrics }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metrics = c.value(.metrics, or: [:])
    }
}

public struct Settings: Sendable, Codable, Equatable {
    /// Bumped when a migration is needed. Unknown future versions are loaded
    /// leniently rather than discarded.
    public var schemaVersion: Int
    public var general: GeneralSettings
    public var menuBar: MenuBarSettings
    public var panel: PanelSettings
    public var charts: ChartSettings
    public var notifications: NotificationSettings
    public var shortcuts: ShortcutSettings
    public var theme: ThemeSettings
    public var widgets: WidgetSettings

    public static let currentSchemaVersion = 1

    public init(schemaVersion: Int = Settings.currentSchemaVersion,
                general: GeneralSettings = .init(),
                menuBar: MenuBarSettings = .init(),
                panel: PanelSettings = .init(),
                charts: ChartSettings = .init(),
                notifications: NotificationSettings = .init(),
                shortcuts: ShortcutSettings = .init(),
                theme: ThemeSettings = .init(),
                widgets: WidgetSettings = .init()) {
        self.schemaVersion = schemaVersion
        self.general = general
        self.menuBar = menuBar
        self.panel = panel
        self.charts = charts
        self.notifications = notifications
        self.shortcuts = shortcuts
        self.theme = theme
        self.widgets = widgets
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, general, menuBar, panel, charts, notifications
        case shortcuts, theme, widgets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, or: Settings.currentSchemaVersion)
        general = c.value(.general, or: GeneralSettings())
        menuBar = c.value(.menuBar, or: MenuBarSettings())
        panel = c.value(.panel, or: PanelSettings())
        charts = c.value(.charts, or: ChartSettings())
        notifications = c.value(.notifications, or: NotificationSettings())
        shortcuts = c.value(.shortcuts, or: ShortcutSettings())
        theme = c.value(.theme, or: ThemeSettings())
        widgets = c.value(.widgets, or: WidgetSettings())
    }

    /// Collectors that must run to satisfy everything currently on screen.
    ///
    /// This drives the engine's enabled-source set, and is why a user who only
    /// wants a CPU readout never pays for IOKit battery or SMC sensor polling.
    public func requiredSources(panelVisible: Bool) -> Set<CollectorID> {
        var sources = Set<CollectorID>()
        if menuBar.showsRings {
            for metric in menuBar.ringMetrics { sources.insert(metric.requiredSource) }
        }
        for item in menuBar.readoutsBesideRings { sources.insert(item.metric.requiredSource) }
        if panelVisible {
            for module in panel.visibleModules { sources.insert(module.requiredSource) }
        }
        if notifications.isEnabled {
            for rule in notifications.enabledRules { sources.insert(rule.metric.requiredSource) }
            if notifications.notifiesOnPublicIPChange || notifications.notifiesOnConnectivityChange {
                sources.insert(.network)
            }
            if notifications.notifiesOnRunaway || notifications.notifiesOnUnusual {
                sources.formUnion([.cpu, .memory, .thermal])
            }
            if notifications.notifiesOnHeavyUnplug { sources.insert(.power) }
            // The two alerts that name a process need the list. With the panel closed
            // it is read only in a busy minute, twice, or on unplugging: never on an
            // idle Mac, and never while these alerts are off.
            if notifications.notifiesOnRunaway || notifications.notifiesOnHeavyUnplug {
                sources.insert(.processes)
            }
        }
        // System info is cheap, static, and needed for the about/uptime readouts.
        sources.insert(.system)
        return sources
    }

    /// Number of retained samples implied by the chart history and update interval.
    public var historyCapacity: Int {
        let interval = max(general.updateInterval, 0.5)
        return min(max(Int(charts.historyDuration / interval) + 2, 30), 4096)
    }
}
