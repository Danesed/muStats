import SwiftUI
import AppKit
import MuStatsKit

/// The one-glance answer for a module, shown on its header line.
///
/// Everything below the header is detail the user reads second; this is what they
/// read first, so each module contributes exactly one of them.
struct PanelSummary {
    /// Whether the primary reads as a measurement or as a state. A state ("Nominal",
    /// "AC") set at headline size looks like a mistake, so it drops to value size.
    enum Emphasis { case measurement, state }

    var value: String?
    var caption: String?
    /// Replaces the module's own glyph. A full battery icon on a Mac that has no
    /// battery states something untrue before the reader gets to the words.
    var icon: String?
    var symbol: String?
    /// A second reading that leads `value`, direction glyph and all. Only
    /// network answers with two rates — "↗ 340 KB/s  ↙ 2.4 MB/s"; everywhere
    /// else one number is the answer.
    var leadValue: String?
    var leadSymbol: String?
    var emphasis: Emphasis = .measurement
    /// Text the headline slot is sized for before it is on screen, drawn hidden at
    /// the size the real reading will use. Only a module whose headline swaps a
    /// state for a measurement mid-session asks for one: without them the
    /// "Apple M4 Pro" → "84%" handover moves the whole row, and measured reserves
    /// drift a point or two from what the layout actually grants a `Text`.
    var reservedHeadlineText: String?
    var reservedValueText: String?
}

/// How a row stands against the others.
///
/// Nine rows at one contrast ask the reader to compare nine numbers to find the one
/// that matters. When a row has something to say the calm ones step back, so the eye
/// lands on it before reading anything: emphasis made by removing ink from the rest,
/// not by adding it to the one. With nothing to say, every row is `.normal` and the
/// panel looks as it always did.
enum PanelRowEmphasis: Equatable {
    case normal
    /// Calm while another row is not.
    case receded
    /// Below every threshold, but the reading the status line is pointing at.
    case noticed

    /// The emphasis of each of `modules`.
    ///
    /// - Parameters:
    ///   - alerting: modules whose reading is at warning or critical.
    ///   - noticed: the module a notice is about, if the status line carries one.
    ///   - expanded: open modules, which never recede: the reader chose them.
    ///   - dims: the user's setting.
    static func assign(_ modules: [PanelModule], alerting: Set<PanelModule>, noticed: PanelModule?,
                       expanded: Set<PanelModule>, dims: Bool) -> [PanelModule: PanelRowEmphasis] {
        var standouts = alerting
        if let noticed { standouts.insert(noticed) }
        var result: [PanelModule: PanelRowEmphasis] = [:]
        for module in modules {
            if module == noticed, !alerting.contains(module) {
                result[module] = .noticed
            } else if dims, !standouts.isEmpty, !standouts.contains(module), !expanded.contains(module) {
                result[module] = .receded
            } else {
                result[module] = .normal
            }
        }
        return result
    }
}

/// One module of the panel: a header that carries the headline value, and detail
/// that the user can collapse away.
struct PanelModuleView: View {
    let module: PanelModule
    let engine: MetricsEngine
    let settings: SettingsStore
    var layout: PanelLayoutState?
    /// Width of the qualifier column beside the headline value, shared by every row so
    /// the numbers keep one right edge. See `PanelSummary.captionColumnWidth(for:)`.
    var captionColumnWidth: CGFloat
    /// Width of the name column, shared so every sparkline starts at one x.
    var nameColumnWidth: CGFloat = 80
    var emphasis: PanelRowEmphasis = .normal

    @State private var isHovering = false
    @Environment(\.panelActions) var actions
    /// Which window the module's history chart shows, once the user has picked one.
    /// View state rather than a setting: it is a glance choice, and it resets with
    /// the panel. Nil lets the chart choose by how much of the day exists.
    @State var historyRange: HistoryRange?

    /// Derived from the store rather than read from the environment so a module is
    /// correct wherever it is hosted, and injected below so the primitives it draws
    /// cannot disagree with it.
    var formatter: MetricFormatter {
        MetricFormatter(settings: settings.settings.general)
    }

    var isExpanded: Bool {
        let collapsed = layout?.collapsedModulesOverride
            ?? settings.settings.panel.collapsedModules
        return !collapsed.contains(module)
    }

    /// What the panel fills its bars and core cells with.
    ///
    /// The label colour, not `Palette.metric`. Nine modules each in their own hue is
    /// nine colours competing in a 340pt window, and the bar is the content here —
    /// nothing sits on top of it — so it takes the colour text takes.
    static let barTint = Design.Palette.primaryText

    var metricColor: Color {
        if let custom = settings.settings.theme.color(for: module.requiredSource) {
            return Color(themeColor: custom)
        }
        return Design.Palette.defaultMetric(module.requiredSource)
    }

    /// Bars, cores and charts keep the metric's own colour whatever the reading.
    /// Alert colour lands on the headline number and the dot beside the glyph only:
    /// when every part of a busy module turned red, six modules under load were a
    /// wall of red and the one that mattered did not stand out.
    var tint: Color { metricColor }

    var barTint: Color { tint }

    var chartTint: Color { tint }

    /// The low-to-high band of the history chart, under its mean line.
    var bandTint: Color { tint.opacity(0.15) }

    var alertLevel: PanelAlertLevel {
        settings.settings.panel.showsAlertColors ? PanelAlert.level(for: module, engine: engine) : .none
    }

    /// Reserved width for the process list's value column, sized for the widest
    /// reading it can hold ("412.6%", "4.3 GB") so the column never reflows as
    /// processes come and go.
    static let processValueWidth: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            detail
                .padding(.horizontal, Design.Space.panelInset)
                .padding(.top, Design.Space.xxs)
                // Air before the rule that closes an expanded module, so its last row
                // does not sit on the separator.
                .padding(.bottom, isExpanded ? Design.Space.xs : 0)
        }
        .padding(.vertical, Design.Space.xxs)
        .environment(\.metricFormatter, formatter)
        .environment(\.isDisclosureInProgress, layout?.isDisclosureTransitionActive == true)
    }

    // MARK: Header

    private var header: some View {
        Button(action: toggleCollapsed) {
          VStack(spacing: 3) {
            HStack(spacing: Design.Space.m) {
                Image(systemName: "chevron.right")
                    .font(Design.Text.micro.weight(.semibold))
                    .foregroundStyle(Design.Palette.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Design.Space.m)
                // Regular weight, not the label's semibold: the glyph identifies the
                // row, and at the heading's weight nine of them read as a second
                // column of content.
                Image(systemName: summary.icon ?? module.symbolName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(metricColor)
                    .frame(width: Design.Space.xl)
                    .overlay(alignment: .topTrailing) { alertDot }
                // The name is what the row is, the number is what it says: the name
                // steps back in weight and colour so the eye lands on the number.
                Text(localizing: module.label)
                    .font(Design.Text.rowTitle)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
                    .frame(width: nameColumnWidth, alignment: .leading)
                sparkline
                Spacer(minLength: Design.Space.s)
                headlineValue
                    // The number outranks the gap in front of it: without this the
                    // `HStack` splits any shortfall between the `Spacer` and the value,
                    // so "7.4 GB" could render as "7.4…" with slack sitting unused to
                    // its left.
                    .layoutPriority(1)
            }
            if let gauge {
                PanelGauge(reading: gauge, excessTint: alertLevel.color ?? PanelGauge.unusualTint)
                    // Starts under the name, the way a list's rules start under its
                    // text: the glyph column stays clear and the bars share one origin.
                    .padding(.leading, Self.gaugeInset)
                    .transition(.opacity)
            }
          }
            // A pointer on a receded row brings it back: pointing at it is asking.
            .opacity(emphasis == .receded && !isHovering && !isKeyboardFocused ? Self.recededOpacity : 1)
            .animation(Design.Motion.respectingAccessibility(Design.Motion.value), value: emphasis)
            .padding(.horizontal, Design.Space.panelInset)
            .contentShape(Rectangle())
            .background(hoverHighlight)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Design.Motion.respectingAccessibility(Design.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(module.label)
        .accessibilityValue([summary.leadValue, summary.value,
                             alertLevel != .none ? "needs attention" : emphasis == .noticed ? "unusual" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
    }

    /// Low enough to read as background, high enough to stay legible: the row is
    /// still information, only not the news.
    static let recededOpacity = 0.45

    /// The chevron and the glyph, and the gaps after them.
    static let gaugeInset: CGFloat = Design.Space.m + Design.Space.m + Design.Space.xl + Design.Space.m

    /// The row's gauge: while the module is closed, the user wants gauges, and the
    /// reading has a scale to be drawn on. Open, the detail says the same thing larger.
    var gauge: PanelGaugeReading? {
        Self.gauge(for: module, engine: engine, panel: settings.settings.panel, isExpanded: isExpanded)
    }

    static func gauge(for module: PanelModule, engine: MetricsEngine, panel: PanelSettings,
                      isExpanded: Bool) -> PanelGaugeReading? {
        guard !isExpanded, panel.showsGauges else { return nil }
        return PanelGaugeReading.make(for: module, engine: engine, showsUsual: panel.shows(.moduleUsual))
    }

    /// Marks the glyph of a module whose reading is in alert colour, so the row is
    /// found by shape as well as by hue.
    @ViewBuilder
    private var alertDot: some View {
        if let color = alertLevel.color ?? (emphasis == .noticed ? PanelGauge.unusualTint : nil) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .offset(x: 2, y: -1)
                .accessibilityHidden(true)
        }
    }

    /// The last few minutes of the headline value, in the row itself. Neutral even in
    /// alert, where the number and the dot already carry the colour. Absent while the
    /// module is open, where the full chart says the same thing larger, and for the
    /// modules that keep no series.
    @ViewBuilder
    private var sparkline: some View {
        if !isExpanded, settings.settings.panel.shows(.moduleSparklines),
           let series = module.historySeries {
            PanelSparkline(samples: engine.history[series.key], key: series.key,
                           domain: series.domain,
                           usual: usualRange(for: series.key),
                           tint: Design.Palette.secondaryText)
                .frame(minWidth: 0, idealWidth: PanelSparkline.width, maxWidth: PanelSparkline.width)
                .frame(height: PanelSparkline.height)
        } else {
            Color.clear
                .frame(minWidth: 0, idealWidth: PanelSparkline.width, maxWidth: PanelSparkline.width)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    /// This hour's usual range for the row's series, when the user wants it drawn and
    /// the month holds enough days to have one.
    private func usualRange(for key: SeriesKey) -> UsualRange? {
        // The gauge under the row already carries the range, at a size it can be read.
        guard settings.settings.panel.shows(.moduleUsual), !settings.settings.panel.showsGauges,
              Usual.isDrawn(for: key) else { return nil }
        return Usual.range(key, month: engine.monthHistory, at: engine.history.lastSampleDate ?? Date())
    }

    private var isKeyboardFocused: Bool {
        layout?.focusedModule == module
    }

    @ViewBuilder
    private var hoverHighlight: some View {
        let isFocused = isKeyboardFocused
        let isHovered = isHovering && layout?.isDisclosureTransitionActive != true
        RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            // Rows move under a stationary pointer during disclosure. Hiding the
            // highlight while they travel prevents it flashing from one row to the
            // next; onHover still tracks the final row underneath for the next frame.
            .fill(isHovered || isFocused ? Design.Palette.track : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .stroke(Design.Palette.secondaryText.opacity(0.4), lineWidth: isFocused ? 1 : 0)
            )
            .padding(.horizontal, Design.Space.m)
    }

    @ViewBuilder
    private var headlineValue: some View {
        if let value = summary.value {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                ZStack(alignment: .trailing) {
                    // Hidden sizers claim the exact slot the readings will occupy —
                    // same `Text`, same fonts, so the reservation cannot drift from
                    // the layout the way a hand-measured width can.
                    if let text = summary.reservedHeadlineText {
                        Text(text).font(Design.Text.headline).hidden()
                    }
                    if let text = summary.reservedValueText {
                        Text(text).font(Design.Text.value).hidden()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                        if let lead = summary.leadValue {
                            headlineReading(symbol: summary.leadSymbol, value: lead)
                        }
                        headlineReading(symbol: summary.symbol, value: value)
                    }
                    // Never cut. When the row is short of room the sparkline gives way,
                    // since it has no minimum width, and the reading stays whole.
                    .fixedSize(horizontal: true, vertical: false)
                }
                // The qualifier sits in a shared column so it cannot push the number.
                //
                // Inline, a caption shifted its value left by its own width, so across the
                // collapsed list the numbers ended at x = 254, 282, 285, 300, 323, 324 —
                // a 70pt ragged spread that made the column impossible to scan even though
                // the right edge looked tidy. Every row takes the slot whether or not it
                // has a caption, which puts every number's right edge on the same line.
                // When no row has one there is no column at all.
                if captionColumnWidth > 0 {
                    if let caption = summary.caption, !caption.isEmpty {
                        Text(caption)
                            .font(Design.Text.caption)
                            .foregroundStyle(Design.Palette.secondaryText)
                            .lineLimit(1)
                            .frame(width: captionColumnWidth, alignment: .leading)
                    } else if summary.leadValue == nil {
                        Color.clear
                            .frame(width: captionColumnWidth, height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// One glyph-and-number unit of the headline. Tight internally so the wider
    /// gap falls between two units, where a second reading needs to separate.
    @ViewBuilder
    private func headlineReading(symbol: String?, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.xxs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(Design.Text.caption.weight(.semibold))
                    .foregroundStyle(Design.Palette.secondaryText)
            }
            Group {
                if summary.emphasis == .state {
                    Text(value).font(Design.Text.value)
                } else {
                    UnitText.text(value, size: isExpanded ? 20 : 13, weight: .semibold)
                }
            }
                .foregroundStyle(headlineColor)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }

    private var headlineColor: Color {
        alertLevel.color ?? Design.Palette.primaryText
    }

    private func toggleCollapsed() {
        if let coordinate = layout?.toggleModule {
            coordinate(module)
            return
        }
        withAnimation(Design.Motion.respectingAccessibility(Design.Motion.disclosure)) {
            settings.update { s in
                s.panel.collapsedModules = s.panel.collapsedModules(toggling: module)
            }
        }
    }

    // MARK: Summary

    private var summary: PanelSummary {
        .make(for: module, engine: engine, formatter: formatter)
    }

}

extension PanelSummary {
    /// The one-glance answer for `module`, or an empty summary while it has nothing yet.
    @MainActor
    static func make(for module: PanelModule, engine: MetricsEngine,
                     formatter: MetricFormatter) -> PanelSummary {
        switch module {
        case .cpu:
            guard let cpu = engine.cpu.value else { return warmup(for: engine.cpu) }
            // The percentage alone cannot say whether work is queueing: 34% with a
            // load of 12 is a very different machine from 34% with a load of 1.
            return PanelSummary(value: formatter.percent(cpu.total.busy),
                                caption: String(localized: "load \(formatter.fixed(cpu.loadAverage.one, decimals: 1))"))
        case .memory:
            guard let memory = engine.memory.value else { return warmup(for: engine.memory) }
            let ramValue = Self.usedOfTotal(Double(memory.usedBytes), Double(memory.totalBytes),
                                            formatter: formatter)
            return PanelSummary(value: ramValue,
                                caption: String(localized: "pressure \(formatter.percent(memory.pressureFraction))"))
        case .gpu:
            guard let gpu = engine.gpu.value else { return warmup(for: engine.gpu) }
            guard let device = gpu.primary else { return PanelSummary() }
            let utilCaption = device.utilization.map { String(localized: "util \(formatter.percent($0))") }
            if let used = device.vramUsedBytes {
                let vramValue = device.vramTotalBytes.flatMap { $0 > 0 ? $0 : nil }
                    .map { Self.usedOfTotal(Double(used), Double($0), formatter: formatter) }
                    ?? formatter.memory(used)
                return PanelSummary(value: vramValue, caption: utilCaption)
            }
            guard let utilization = device.utilization else {
                return PanelSummary(value: device.name, caption: nil,
                                    emphasis: .state,
                                    reservedHeadlineText: formatter.percent(1.0),
                                    reservedValueText: device.name)
            }
            return PanelSummary(value: formatter.percent(utilization), caption: nil,
                                reservedHeadlineText: formatter.percent(1.0),
                                reservedValueText: device.name)
        case .network:
            guard let network = engine.network.value else { return warmup(for: engine.network) }
            // No caption: two rates already fill the row, and "Ethernet" beside them
            // pushed the numbers into "…" on narrower layouts. The connection is named
            // in the detail instead.
            return PanelSummary(value: formatter.networkRate(network.downloadBytesPerSecond),
                                caption: nil,
                                symbol: "arrow.down.left",
                                leadValue: formatter.networkRate(network.uploadBytesPerSecond),
                                leadSymbol: "arrow.up.right")
        case .disk:
            guard let disk = engine.disk.value else { return warmup(for: engine.disk) }
            guard let root = disk.rootVolume else { return PanelSummary() }
            // The caption is the value's twin in the other unit: "120 GB" and
            // "24% free" are one answer, so it is measured from the same bytes.
            let freeFraction = root.totalBytes > 0
                ? Double(root.availableBytes) / Double(root.totalBytes) : 0
            return PanelSummary(value: formatter.storage(root.availableBytes),
                                caption: String(localized: "\(formatter.percent(freeFraction)) free"))
        case .battery:
            guard let power = engine.power.value else { return warmup(for: engine.power) }
            guard power.hasBattery, let percentage = power.percentage else {
                return PanelSummary(value: power.isPluggedIn ? "AC" : MetricFormatter.unavailable,
                                    icon: "powerplug",
                                    emphasis: .state)
            }
            // The caption is the pack's instantaneous power: on battery it is the
            // system draw, on AC it is the charge rate — which also carries the
            // "is it charging" answer the old "charging" caption held, in a number.
            // Held, the pack moves no current and "0.0 W" would read as a fault.
            let caption = power.isOptimizedChargingPaused
                ? "on hold" : power.batteryWatts.map { formatter.watts(abs($0)) }
            return PanelSummary(value: formatter.percentValue(percentage),
                                caption: caption,
                                icon: power.isCharging || power.isPluggedIn ? "powerplug" : nil)
        case .thermal:
            guard let thermal = engine.thermal.value else { return warmup(for: engine.thermal) }
            // The caption is the fastest fan as percentage.
            let fan: String? = {
                guard let fastest = thermal.fans.max(by: { $0.currentRPM < $1.currentRPM }) else { return nil }
                if let max = fastest.maxRPM, max > 0 {
                    let pct = Int((100 * fastest.currentRPM / max).rounded())
                    let share = "\(pct)%"
                    return String(localized: "fan \(share)")
                }
                let rpm = "\(Int(fastest.currentRPM.rounded()))"
                return String(localized: "fan \(rpm)")
            }()
            guard let celsius = thermal.cpuCelsius else {
                return PanelSummary(value: thermal.pressure.label, caption: fan,
                                    emphasis: .state)
            }
            return PanelSummary(value: formatter.temperature(celsius), caption: fan)
        case .processes:
            guard let count = engine.cpu.value?.processCount else {
                return PanelSummary(value: MetricFailure.pending.shortLabel, emphasis: .state)
            }
            return PanelSummary(value: formatter.count(count),
                                caption: String(localized: "running"))
        case .system:
            guard let system = engine.system.value else { return warmup(for: engine.system) }
            return PanelSummary(value: formatter.uptime(system.uptime), caption: String(localized: "uptime"))
        }
    }

    /// "1.0/13 GB": both figures in the total's unit.
    ///
    /// Formatted separately, 1006 MB of 13 GB read "1006 MB/13 GB", which is wider
    /// than any other headline and asks the reader to convert before comparing.
    static func usedOfTotal(_ used: Double, _ total: Double, formatter: MetricFormatter) -> String {
        let totalText = formatter.memory(total)
        guard total > 0, let unit = totalText.split(separator: " ").last,
              let exponent = ["B", "KB", "MB", "GB", "TB", "PB"].firstIndex(of: String(unit)) else {
            return "\(formatter.memory(used))/\(totalText)"
        }
        let usedNumber = used / pow(1024, Double(exponent))
        let usedText = formatter.fixed(usedNumber, decimals: usedNumber < 10 && exponent > 0 ? 1 : 0)
        return "\(usedText)/\(totalText)"
    }

    /// The stand-in while a metric has never sampled: "Collecting…" in the
    /// headline slot itself, so a warming module stays one line instead of
    /// gaining a note underneath that vanishes the moment the number lands.
    /// Harder failures keep their explanation in the detail line.
    private static func warmup<V>(for state: MetricState<V>) -> PanelSummary {
        state.failure == .pending
            ? PanelSummary(value: MetricFailure.pending.shortLabel, emphasis: .state)
            : PanelSummary()
    }

    /// The width the qualifier column needs to hold the widest caption in `summaries`.
    ///
    /// Measured from what is on screen rather than reserved for the longest caption the
    /// panel can ever show: sized for a state that is not always present, the column
    /// stood mostly empty and the whole right edge read as a gap. Every row still
    /// takes the same width, so the numbers keep their shared right edge; that edge
    /// just sits where the captions actually end.
    static func captionColumnWidth(for summaries: [PanelSummary]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Design.Text.captionSize)
        let widest = summaries.compactMap(\.caption).map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return ceil(widest)
    }
}
