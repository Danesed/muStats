import SwiftUI
import MuStatsKit

/// This Mac before and after its last macOS update, a line per reading.
///
/// A reading that moved past the noise is set in the primary colour with an arrow
/// and the size of the move; one that did not is set back, because "the same as
/// before" is also the answer and should not look like news.
struct PanelUpdateEffect: View {
    let effect: UpdateEffect
    let systemName: String
    let version: String

    @Environment(\.metricFormatter) private var formatter

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(alignment: .firstTextBaseline) {
                PanelSectionLabel(String(localized: "Since \(systemName) \(version)"))
                Spacer(minLength: Design.Space.xs)
                Text(Self.span(effect.days))
                    .font(Design.Text.micro)
                    .foregroundStyle(Design.Palette.tertiaryText)
            }
            ForEach(effect.changes) { change in
                row(change)
            }
            Text("A typical hour, the week before against the days since.")
                .font(Design.Text.micro)
                .foregroundStyle(Design.Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Design.Space.xs)
        .accessibilityElement(children: .combine)
    }

    private func row(_ change: UpdateEffect.Change) -> some View {
        let notable = change.isNotable
        return HStack(spacing: Design.Space.s) {
            Text(localizing: Self.label(change.key))
                .font(Design.Text.label)
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
            Spacer(minLength: Design.Space.m)
            Text(verbatim: "\(value(change.before, change.key)) → \(value(change.after, change.key))")
                .font(Design.Text.caption.monospacedDigit())
                .foregroundStyle(notable ? Design.Palette.secondaryText : Design.Palette.tertiaryText)
                .lineLimit(1)
            HStack(spacing: 2) {
                Image(systemName: notable ? (change.delta > 0 ? "arrow.up.right" : "arrow.down.right") : "equal")
                    .font(.system(size: 8, weight: .bold))
                Text(notable ? Self.delta(change, formatter: formatter) : String(localized: "same"))
                    .font(Design.Text.value)
                    .lineLimit(1)
            }
            .foregroundStyle(notable ? Design.Palette.primaryText : Design.Palette.tertiaryText)
            .frame(width: 64, alignment: .trailing)
        }
    }

    private func value(_ reading: Double, _ key: SeriesKey) -> String {
        key == .cpuTemperature ? formatter.temperature(reading) : formatter.percent(reading)
    }

    static func label(_ key: SeriesKey) -> String {
        switch key {
        case .cpuTemperature: return "Temperature"
        case .memoryPressure: return "Memory pressure"
        default: return "CPU"
        }
    }

    /// "+4°C", "−6 pts": the move in the reading's own unit. A share moves in points,
    /// since "+50%" of 10% would read as 60%.
    static func delta(_ change: UpdateEffect.Change, formatter: MetricFormatter) -> String {
        let sign = change.delta > 0 ? "+" : "−"
        if change.key == .cpuTemperature {
            let scale = formatter.temperatureUnit == .fahrenheit ? 9.0 / 5 : 1
            return sign + formatter.fixed(abs(change.delta) * scale, decimals: 0) + formatter.temperatureUnit.suffix
        }
        let points = formatter.fixed(abs(change.delta) * 100, decimals: 0)
        return String(localized: "\(sign)\(points) pts")
    }

    static func span(_ days: Double) -> String {
        let whole = max(1, Int(days.rounded(.down)))
        return whole == 1 ? String(localized: "1 day") : String(localized: "\(whole) days")
    }
}
