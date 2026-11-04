import WidgetKit
import SwiftUI

/// The menu bar's rings as a widget, with the readings and colours chosen in the app.
struct RingsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "rings", provider: ReadingProvider()) { entry in
            RingsWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Rings"))
        .description("muStats · " + String(localized: "Up to three readings as rings, in your colours."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct RingStack: View {
    let fractions: [Double?]
    let colors: [Color]

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let line = diameter * 0.11
            let gap = diameter * 0.03
            ZStack {
                ForEach(Array(fractions.enumerated()), id: \.offset) { index, fraction in
                    let inset = CGFloat(index) * (line + gap) + line / 2
                    let tone = colors[index]
                    Circle()
                        .stroke(tone.opacity(0.28), lineWidth: line)
                        .padding(inset)
                    if let fraction {
                        Circle()
                            .trim(from: 0, to: min(max(fraction, 0), 1))
                            .stroke(tone, style: StrokeStyle(lineWidth: line, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(inset)
                            .widgetAccentable()
                    } else {
                        let half = max(line * 0.55, 1.5)
                        Path { path in
                            path.move(to: CGPoint(x: diameter / 2 - half, y: inset - half))
                            path.addLine(to: CGPoint(x: diameter / 2 + half, y: inset + half))
                            path.move(to: CGPoint(x: diameter / 2 - half, y: inset + half))
                            path.addLine(to: CGPoint(x: diameter / 2 + half, y: inset - half))
                        }
                        .stroke(tone, style: StrokeStyle(lineWidth: max(1, line * 0.3), lineCap: .round))
                        .widgetAccentable()
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The name and time at the top of the larger widgets.
struct WidgetHeader: View {
    let date: Date

    var body: some View {
        HStack {
            Text(verbatim: "μStats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(date, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct RingsWidgetView: View {
    let entry: ReadingEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    private var rings: [WidgetConfig.Ring] { entry.config.rings }
    private var colors: [Color] { rings.map { $0.color(dark: scheme == .dark) } }
    private var fractions: [Double?] { rings.map { $0.metric.fraction(entry.reading) } }

    var body: some View {
        Group {
            switch family {
            case .systemMedium: medium
            case .systemLarge: large
            default:
                RingStack(fractions: fractions, colors: colors)
                    .padding(4)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL((rings.first?.metric.module ?? .cpu).url)
    }

    private var medium: some View {
        HStack(spacing: 16) {
            RingStack(fractions: fractions, colors: colors)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rings.enumerated()), id: \.offset) { index, ring in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ring.metric.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colors[index])
                        Text(ring.metric.value(entry.reading) ?? "—")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(date: entry.date)
            RingStack(fractions: fractions, colors: colors)
                .frame(maxHeight: .infinity)
            VStack(spacing: 8) {
                ForEach(Array(rings.enumerated()), id: \.offset) { index, ring in
                    Link(destination: ring.metric.module.url) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(colors[index])
                                .frame(width: 8, height: 8)
                            Text(ring.metric.title)
                                .font(.callout.weight(.semibold))
                            if let detail = ring.metric.detail(entry.reading) {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(ring.metric.value(entry.reading) ?? "—")
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(ring.metric.level(entry.reading).tint)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}
