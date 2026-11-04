import WidgetKit
import SwiftUI

/// The readings chosen in the app, one row each, at three sizes.
struct OverviewWidgetView: View {
    let entry: ReadingEntry
    @Environment(\.widgetFamily) private var family

    /// The chosen readings this Mac has: a battery row on a desktop Mac is left out.
    private var metrics: [WidgetMetric] {
        entry.config.overview.filter { $0 != .battery || entry.reading.battery != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 14 : 7) {
            WidgetHeader(date: entry.date)
            ForEach(metrics, id: \.self) { metric in
                Link(destination: metric.module.url) {
                    switch family {
                    case .systemSmall: smallRow(metric)
                    case .systemLarge: largeRow(metric)
                    default: mediumRow(metric)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func value(_ metric: WidgetMetric) -> String {
        metric.value(entry.reading) ?? "—"
    }

    private func smallRow(_ metric: WidgetMetric) -> some View {
        HStack(spacing: 6) {
            Image(systemName: metric.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(value(metric))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(metric.level(entry.reading).tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
    }

    private func mediumRow(_ metric: WidgetMetric) -> some View {
        HStack(spacing: 8) {
            Image(systemName: metric.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(metric.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)
            WidgetBar(fraction: metric.fraction(entry.reading) ?? 0, level: metric.level(entry.reading))
            Text(value(metric))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(metric.level(entry.reading).tint)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func largeRow(_ metric: WidgetMetric) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: metric.symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(metric.title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                Text(value(metric))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(metric.level(entry.reading).tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            WidgetBar(fraction: metric.fraction(entry.reading) ?? 0, level: metric.level(entry.reading))
            if let detail = metric.detail(entry.reading) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
