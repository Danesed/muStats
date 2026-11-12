import SwiftUI
import AppKit
import MuStatsKit

/// How loudly a module's reading should speak. Ordered, so the panel can ask which
/// module is the worst.
enum PanelAlertLevel: Int, Comparable {
    case none, warning, critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Amber before red: a warning is something to keep an eye on, and drawing it in
    /// the colour of a failure is what made a busy panel read as a broken one.
    var color: Color? {
        switch self {
        case .none: return nil
        case .warning: return Color.orange
        case .critical: return Color.red
        }
    }
}

/// The one place the panel decides when a reading is worth colour. The rows, the
/// insight line and the bars all ask here, so they cannot disagree.
@MainActor
enum PanelAlert {
    static func level(for module: PanelModule, engine: MetricsEngine) -> PanelAlertLevel {
        switch module {
        case .cpu:
            guard let cpu = engine.cpu.value else { return .none }
            let busy = cpu.total.busy
            // The cores the reading was taken on, so a fixture judges the same on any host.
            let cores = Double(cpu.perCore.isEmpty ? ProcessInfo.processInfo.activeProcessorCount
                                                   : cpu.perCore.count)
            let highLoad = cpu.loadAverage.one >= cores
            if busy >= 0.90 || (highLoad && busy >= 0.75) { return .critical }
            if busy >= 0.65 || highLoad { return .warning }
        case .memory:
            guard let memory = engine.memory.value else { return .none }
            if memory.memoryPressure == .critical || memory.pressureFraction >= 0.85 { return .critical }
            if memory.memoryPressure == .warning || memory.pressureFraction >= 0.70 { return .warning }
        case .thermal:
            guard let thermal = engine.thermal.value else { return .none }
            let temp = thermal.cpuCelsius ?? 0
            if thermal.pressure == .critical || temp >= 95 { return .critical }
            if thermal.pressure == .serious || temp >= 85 { return .warning }
        case .battery:
            guard let power = engine.power.value, !power.isPluggedIn,
                  let pct = power.percentage else { return .none }
            if pct <= 10 { return .critical }
            if pct <= 20 { return .warning }
        case .disk:
            guard let root = engine.disk.value?.rootVolume, root.totalBytes > 0 else { return .none }
            let free = Double(root.availableBytes) / Double(root.totalBytes)
            if free <= 0.05 { return .critical }
            if free <= 0.10 { return .warning }
        case .gpu:
            guard let gpu = engine.gpu.value?.primary else { return .none }
            let util = gpu.utilization ?? 0
            if util >= 0.95 { return .critical }
            if util >= 0.80 { return .warning }
        case .network, .processes, .system:
            break
        }
        return .none
    }
}

/// The panel's first line: the answer to "why is my Mac slow?", or that nothing is.
///
/// One module speaks, the worst one, and it names what is behind the reading when
/// the process list can say. Nine coloured rows answer the same question only for a
/// reader willing to compare them.
struct PanelInsight: Equatable {
    var level: PanelAlertLevel
    var module: PanelModule?
    var headline: String
    var detail: String?
    var isIncomplete = false
    /// The reading set against this Mac's own habit: "usually 22%". Sits between the
    /// headline and the culprit, so the line reads what, how unusual, who.
    var comparison: String?
    /// Worth saying although no threshold was crossed: busier than this Mac usually
    /// is, or a disk that fills within the month. Informs, does not warn.
    var isNotice = false
    /// Set when the line is about a stretch that ended while the panel was closed:
    /// how loud it was. The present is calm; this is what the reader missed.
    var pastLevel: PanelAlertLevel?

    var isPast: Bool { pastLevel != nil }

    /// Whether the line has something to say beyond "all is well".
    var isNotable: Bool { level != .none || isNotice || isPast }

    /// When two modules are equally loud, the one the user can most often act on
    /// speaks: memory and CPU are usually one app, heat follows them, and a full disk
    /// or a flat battery are the slower stories.
    static let priority: [PanelModule] = [.memory, .cpu, .thermal, .battery, .disk, .gpu]

    @MainActor
    static func make(modules: [PanelModule], engine: MetricsEngine,
                     formatter: MetricFormatter, recap: PanelRecap? = nil) -> PanelInsight {
        let candidates = priority.filter(modules.contains)
        let worst = candidates.max { a, b in
            let la = PanelAlert.level(for: a, engine: engine)
            let lb = PanelAlert.level(for: b, engine: engine)
            if la != lb { return la < lb }
            // `max` keeps the last of equals, so an earlier priority must compare greater.
            return priority.firstIndex(of: a)! > priority.firstIndex(of: b)!
        }
        guard let module = worst else { return partial }
        let level = PanelAlert.level(for: module, engine: engine)
        if level == .none {
            let reporting = candidates.filter { relevant($0, engine: engine) }
            guard !reporting.isEmpty else { return partial }
            let readable = reporting.filter { available($0, engine: engine) }.count
            if readable == reporting.count {
                // Now, then what was missed, then what is coming.
                return unusual(modules: modules, engine: engine, formatter: formatter)
                    ?? recap.flatMap { missed($0, modules: modules, formatter: formatter) }
                    ?? filling(modules: modules, engine: engine, formatter: formatter)
                    ?? quiet
            }
            return readable == 0 && reporting.allSatisfy { pending($0, engine: engine) } ? collecting : partial
        }
        let apps = engine.processes.value?.apps ?? []
        let now = engine.history.lastSampleDate ?? Date()
        func usually(_ key: SeriesKey, _ format: (Double) -> String) -> String? {
            Usual.range(key, month: engine.monthHistory, at: now)
                .map { String(localized: "usually \(format($0.median))") }
        }

        switch module {
        case .cpu:
            let busy = engine.cpu.value.map { formatter.percent($0.total.busy) } ?? ""
            let top = PanelCulprit.top(apps: apps) { $0.cpuPercent }
            return PanelInsight(level: level, module: module, headline: String(localized: "CPU at \(busy)"),
                                detail: top.map { "\($0.name) \(formatter.unclampedPercent($0.value, decimals: 0))" },
                                comparison: usually(.cpuTotal) { formatter.percent($0) })
        case .memory:
            let pressure = engine.memory.value.map { formatter.percent($0.pressureFraction) } ?? ""
            let top = PanelCulprit.top(apps: apps) { Double($0.memoryBytes) }
            return PanelInsight(level: level, module: module, headline: String(localized: "Memory pressure \(pressure)"),
                                detail: top.map { "\($0.name) \(formatter.memory($0.value))" },
                                comparison: usually(.memoryPressure) { formatter.percent($0) })
        case .thermal:
            let celsius = engine.thermal.value?.cpuCelsius.map { formatter.temperature($0) }
            let top = PanelCulprit.top(apps: apps) { $0.cpuPercent }
            return PanelInsight(level: level, module: module,
                                headline: celsius.map { String(localized: "Running hot at \($0)") } ?? String(localized: "Running hot"),
                                detail: top.map { "\($0.name) \(formatter.unclampedPercent($0.value, decimals: 0))" },
                                comparison: usually(.cpuTemperature) { formatter.temperature($0) })
        case .battery:
            let power = engine.power.value
            let pct = power?.percentage.map { formatter.percentValue($0) } ?? ""
            return PanelInsight(level: level, module: module, headline: String(localized: "Battery at \(pct)"),
                                detail: power?.timeToEmpty.map { String(localized: "\(formatter.duration($0)) left") })
        case .disk:
            let free = engine.disk.value?.rootVolume.map { formatter.storage($0.availableBytes) }
            return PanelInsight(level: level, module: module, headline: String(localized: "Startup disk almost full"),
                                detail: free.map { String(localized: "\($0) free") })
        case .gpu:
            let util = engine.gpu.value?.primary?.utilization.map { formatter.percent($0) } ?? ""
            return PanelInsight(level: level, module: module, headline: String(localized: "GPU at \(util)"), detail: nil)
        case .network, .processes, .system:
            return quiet
        }
    }

    /// A reading well past this Mac's habit for the hour, by the same test the
    /// notification uses, so the panel and the notification cannot disagree. Below
    /// every threshold, which is the point: 58% is not an alarm, but on a Mac that
    /// idles at 12% every afternoon it is the thing to look at.
    @MainActor
    private static func unusual(modules: [PanelModule], engine: MetricsEngine,
                                formatter: MetricFormatter) -> PanelInsight? {
        let now = engine.history.lastSampleDate ?? Date()
        for metric in UnusualWatch.metrics {
            let module: PanelModule
            switch metric.key {
            case .cpuTotal: module = .cpu
            case .cpuTemperature: module = .thermal
            case .memoryPressure: module = .memory
            default: continue
            }
            guard modules.contains(module),
                  let current = UnusualWatch.recent(metric.key, day: engine.dayHistory, now: now),
                  let usual = UnusualWatch.usual(metric.key, month: engine.monthHistory, now: now),
                  UnusualWatch.isUnusual(current: current, usual: usual,
                                         floor: metric.floor, margin: metric.margin)
            else { continue }
            let name = metric.note.flatMap { kind in
                (0..<UnusualWatch.window).lazy
                    .compactMap { engine.dayHistory.note(kind, at: now.addingTimeInterval(-60 * Double($0)))?.name }
                    .first
            }
            return PanelInsight(level: .none, module: module, headline: metric.title, detail: name,
                                comparison: String(localized: "\(metric.format(current, formatter)), usually \(metric.format(usual.median, formatter))"),
                                isNotice: true)
        }
        return nil
    }

    /// What happened while the panel was closed, in the past tense: the peak, when,
    /// and the process behind it. Every monitor shows now; a reader who opens the
    /// panel because the fans just stopped is asking about ten minutes ago.
    private static func missed(_ recap: PanelRecap, modules: [PanelModule],
                               formatter: MetricFormatter) -> PanelInsight? {
        let event = recap.event
        guard modules.contains(event.module) else { return nil }
        let clock = event.start.formatted(date: .omitted, time: .shortened)
        return PanelInsight(level: .none, module: event.module,
                            headline: event.pastTitle(using: formatter),
                            detail: event.culprit,
                            comparison: String(localized: "at \(clock)"),
                            pastLevel: event.level)
    }

    /// The startup disk, when it fills within the month at the rate of the last two
    /// weeks. Free space says how much room is left; this says how long it lasts.
    @MainActor
    private static func filling(modules: [PanelModule], engine: MetricsEngine,
                                formatter: MetricFormatter) -> PanelInsight? {
        guard modules.contains(.disk),
              let forecast = DiskForecast.make(month: engine.monthHistory,
                                               now: engine.history.lastSampleDate ?? Date()),
              forecast.daysUntilFull <= noticeDays else { return nil }
        return PanelInsight(level: .none, module: .disk,
                            headline: PanelForecast.headline(forecast),
                            detail: PanelForecast.rate(forecast, disk: engine.disk.value, formatter: formatter),
                            isNotice: true)
    }

    /// A disk that lasts longer than this is not news for the top of the panel.
    static let noticeDays: Double = 30

    @MainActor
    private static func relevant(_ module: PanelModule, engine: MetricsEngine) -> Bool {
        switch module {
        case .cpu, .memory, .thermal, .disk, .gpu: return true
        case .battery: return engine.power.value?.hasBattery != false
        case .network, .processes, .system: return false
        }
    }

    @MainActor
    private static func available(_ module: PanelModule, engine: MetricsEngine) -> Bool {
        switch module {
        case .cpu: return engine.cpu.value != nil
        case .memory: return engine.memory.value != nil
        case .thermal: return engine.thermal.value != nil
        case .battery:
            return engine.power.value?.percentage != nil
        case .disk: return engine.disk.value?.rootVolume != nil
        case .gpu: return engine.gpu.value?.primary?.utilization != nil
        case .network, .processes, .system: return false
        }
    }

    @MainActor
    private static func pending(_ module: PanelModule, engine: MetricsEngine) -> Bool {
        switch module {
        case .cpu: return engine.cpu.failure == .pending
        case .memory: return engine.memory.failure == .pending
        case .thermal: return engine.thermal.failure == .pending
        case .battery: return engine.power.failure == .pending
        case .disk: return engine.disk.failure == .pending
        case .gpu: return engine.gpu.failure == .pending
        case .network, .processes, .system: return false
        }
    }

    static let quiet = PanelInsight(level: .none, module: nil,
                                    headline: String(localized: "Everything looks normal"), detail: nil)
    static let collecting = PanelInsight(level: .none, module: nil,
                                         headline: String(localized: "Collecting readings"), detail: nil,
                                         isIncomplete: true)
    static let partial = PanelInsight(level: .none, module: nil,
                                     headline: String(localized: "Some readings unavailable"), detail: nil,
                                     isIncomplete: true)
}

/// The stretch of the day the reader missed: the loudest one that ended, or was
/// still running, after the panel was last closed.
struct PanelRecap: Equatable {
    var event: PanelEvent
    /// When the panel was last closed.
    var since: Date

    /// Closed for less than this, the reader saw it happen.
    static let minimumGap: TimeInterval = 5 * 60

    static func make(events: [PanelEvent], since: Date?, now: Date) -> PanelRecap? {
        guard let since, now.timeIntervalSince(since) >= minimumGap else { return nil }
        let missed = events.filter { $0.end > since && $0.start <= now }
        // The loudest, and of two as loud the later.
        guard let event = missed.max(by: { ($0.level, $0.end) < ($1.level, $1.end) }) else { return nil }
        return PanelRecap(event: event, since: since)
    }
}

/// The app behind a reading, with its helpers counted in.
///
/// Chrome at 4 GB is twenty processes at 200 MB, and none of them would top a list on
/// its own. Everything inside one `.app` is summed under the app's name; a plain
/// executable stands for itself.
enum PanelCulprit {
    struct Entry: Equatable {
        var name: String
        var value: Double
    }

    static func top(_ processes: [ProcessRow], by value: (ProcessRow) -> Double) -> Entry? {
        var totals: [String: Entry] = [:]
        for process in processes {
            let amount = value(process)
            guard amount > 0 else { continue }
            let key = appName(for: process)
            totals[key, default: Entry(name: key, value: 0)].value += amount
        }
        return totals.values.max { $0.value < $1.value || ($0.value == $1.value && $0.name > $1.name) }
    }

    /// The same answer from the bills the collector already added up, which count
    /// every process and not only the ones in the row list.
    static func top(apps: [AppUsage], by value: (AppUsage) -> Double) -> Entry? {
        apps.map { Entry(name: $0.name, value: value($0)) }
            .filter { $0.value > 0 }
            .max { $0.value < $1.value || ($0.value == $1.value && $0.name > $1.name) }
    }

    static func top(_ processes: [ProcessRow], by keyPath: KeyPath<ProcessRow, Double>) -> Entry? {
        top(processes) { $0[keyPath: keyPath] }
    }

    /// "Google Chrome" for anything under `/Applications/Google Chrome.app/`.
    static func appName(for process: ProcessRow) -> String {
        guard let path = process.executablePath, let range = path.range(of: ".app/") else {
            return process.name
        }
        let bundle = path[path.startIndex..<range.lowerBound]
        return bundle.split(separator: "/").last.map(String.init) ?? process.name
    }
}

/// The insight as a row. Clicking it opens the module it is about.
struct PanelInsightRow: View {
    let insight: PanelInsight
    let open: (PanelModule) -> Void

    @State private var isHovering = false

    /// Green for calm, amber and red for the thresholds, blue for a notice: something
    /// to know, in the colour the system uses for information.
    private var dotColor: Color {
        if let color = insight.level.color { return color }
        if let past = insight.pastLevel { return past.color ?? Design.Palette.secondaryText }
        if insight.isNotice { return .blue }
        return insight.isIncomplete ? .gray : .green
    }

    var body: some View {
        Button {
            if let module = insight.module { open(module) }
        } label: {
            HStack(spacing: Design.Space.s) {
                // Filled is now. A ring is over: it happened, and it has stopped.
                Group {
                    if insight.isPast {
                        Circle().strokeBorder(dotColor, lineWidth: 1.5)
                    } else {
                        Circle().fill(dotColor)
                    }
                }
                .frame(width: Design.Space.s, height: Design.Space.s)
                Text(insight.headline)
                    .font(Design.Text.label.weight(.medium))
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                    .layoutPriority(2)
                // The first thing to go when the line is short of room: the headline
                // and the culprit are the answer, this is its context.
                if let comparison = insight.comparison {
                    ViewThatFits(in: .horizontal) {
                        Text(comparison)
                            .font(Design.Text.caption.monospacedDigit())
                            .foregroundStyle(Design.Palette.secondaryText)
                            .lineLimit(1)
                            .fixedSize()
                        Color.clear.frame(width: 0, height: 1)
                    }
                }
                Spacer(minLength: Design.Space.s)
                if let detail = insight.detail {
                    Text(detail)
                        .font(Design.Text.caption.monospacedDigit())
                        .foregroundStyle(Design.Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                // A reading in alert takes its colour as a wash behind the line, so the
                // panel opens on the problem; a calm one sits on the glass.
                RoundedRectangle(cornerRadius: Design.Radius.card + 2, style: .continuous)
                    .fill(insight.level.color.map { $0.opacity(isHovering ? 0.2 : 0.13) }
                          ?? (isHovering && insight.module != nil ? Design.Palette.track : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Design.Motion.respectingAccessibility(Design.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([insight.isPast ? String(localized: "Since you last looked") : nil,
                             insight.headline, insight.comparison, insight.detail]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(insight.module == nil ? "" : "Opens \(insight.module!.label)")
    }
}

/// The disk forecast in words, shared by the status line and the disk module so the
/// two cannot phrase one fact two ways.
enum PanelForecast {
    static func headline(_ forecast: DiskForecast) -> String {
        let days = Int(forecast.daysUntilFull.rounded())
        if days <= 1 { return String(localized: "Disk full within a day") }
        return String(localized: "Disk full in about \(days) days")
    }

    /// "+2.1 GB a day", from the fraction of the volume gained daily.
    @MainActor
    static func rate(_ forecast: DiskForecast, disk: DiskSnapshot?, formatter: MetricFormatter) -> String? {
        guard let total = disk?.rootVolume?.totalBytes, total > 0 else { return nil }
        let amount = formatter.storage(forecast.growthPerDay * Double(total))
        return String(localized: "+\(amount) a day")
    }
}
