import SwiftUI
import AppKit
import MuStatsKit

/// The figure the bill is ranked by.
enum AppBillColumn: String, CaseIterable, Equatable {
    case cpu, memory, energy

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .energy: return "Energy"
        }
    }

    var width: CGFloat {
        switch self {
        case .cpu: return 44
        case .memory: return 56
        case .energy: return 50
        }
    }

    func measure(_ app: AppUsage) -> Double {
        switch self {
        case .cpu: return app.cpuPercent
        case .memory: return Double(app.memoryBytes)
        case .energy: return app.watts ?? 0
        }
    }
}

/// What each app costs, with everything it runs counted in.
///
/// A process list has one figure per row and one row per process, so the reader adds
/// up forty browser helpers and then opens a second list for the memory. This is one
/// row per app with its three costs side by side: processor, memory, energy. A click
/// on a heading ranks by that figure, and the row's fill is its share of the leader
/// on it, so who dominates is a length before it is a number.
struct PanelAppBill: View {
    let apps: [AppUsage]
    var rowCount = PanelSettings.processRowCount

    @State private var column: AppBillColumn = .cpu
    @Environment(\.metricFormatter) private var formatter
    static let rowHeight: CGFloat = 22

    /// The leaders on `column`, largest first. Ties keep the snapshot's CPU order.
    static func ranked(_ apps: [AppUsage], by column: AppBillColumn, count: Int) -> [AppUsage] {
        let indexed = apps.enumerated().sorted { a, b in
            let (x, y) = (column.measure(a.element), column.measure(b.element))
            return x != y ? x > y : a.offset < b.offset
        }
        return indexed.prefix(count).map(\.element)
    }

    var body: some View {
        let rows = Self.ranked(apps, by: column, count: rowCount)
        let top = rows.first.map(column.measure) ?? 0
        VStack(alignment: .leading, spacing: Design.Space.xxs + 1) {
            PanelAppBillHeader(column: $column)
            ForEach(rows) { app in
                row(app, fill: top > 0 ? column.measure(app) / top : 0)
            }
        }
    }

    private func row(_ app: AppUsage, fill: Double) -> some View {
        HStack(spacing: Design.Space.s) {
            PanelAppIconView(icon: PanelAppIcon.icon(forApp: app))
            Text(app.name)
                .font(Design.Text.body)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if app.processCount > 1 {
                // How many line items the bill adds up.
                Text(verbatim: "×\(app.processCount)")
                    .font(Design.Text.caption.monospacedDigit())
                    .foregroundStyle(Design.Palette.tertiaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: Design.Space.xs)
            ForEach(AppBillColumn.allCases, id: \.self) { item in
                Text(value(app, item))
                    .font(item == column ? Design.Text.value : Design.Text.caption.monospacedDigit())
                    .foregroundStyle(item == column ? Design.Palette.primaryText : Design.Palette.secondaryText)
                    .lineLimit(1)
                    .frame(width: item.width, alignment: .trailing)
            }
        }
        .padding(.horizontal, Design.Space.s)
        .frame(height: Self.rowHeight)
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                        .fill(Design.Palette.cardFill)
                    RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                        .fill(Design.Palette.primaryText.opacity(0.10))
                        .frame(width: proxy.size.width * CGFloat(min(max(fill, 0), 1)))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue(AppBillColumn.allCases.map { "\($0.title) \(value(app, $0))" }.joined(separator: ", "))
        .contextMenu { PanelAppMenu(app: app) }
    }

    private func value(_ app: AppUsage, _ column: AppBillColumn) -> String {
        switch column {
        case .cpu: return formatter.unclampedPercent(app.cpuPercent, decimals: 0)
        case .memory: return formatter.memory(app.memoryBytes)
        case .energy: return formatter.watts(app.watts, decimals: 1)
        }
    }

    /// Ask the app to quit the way its own Quit command does, so it can save first.
    /// Its helpers go with it; nothing here is killed.
    static func quit(_ app: AppUsage) {
        let bundle = URL(fileURLWithPath: app.path).standardizedFileURL
        for running in NSWorkspace.shared.runningApplications
        where running.bundleURL?.standardizedFileURL == bundle {
            running.terminate()
        }
    }
}

/// The icon slot of a process or app row: the app's own icon, or a gear for a plain
/// executable, so every row has one and the names share a left edge.
struct PanelAppIconView: View {
    let icon: PanelProcessIcon

    var body: some View {
        switch icon {
        case .bundle(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: Design.Space.l, height: Design.Space.l)
        case .executable:
            Image(systemName: "gearshape.fill")
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.secondaryText)
                .frame(width: Design.Space.l, height: Design.Space.l)
        }
    }
}

/// What can be done about an app from its row.
struct PanelAppMenu: View {
    let app: AppUsage
    var activityMonitorTab = PanelModule.processes.activityMonitorTab

    @Environment(\.panelActions) private var actions

    var body: some View {
        if app.isBundle {
            Button(role: .destructive) {
                PanelAppBill.quit(app)
            } label: {
                Label("Quit \(app.name)", systemImage: "xmark.circle")
            }
            Divider()
        }
        Button {
            actions.openActivityMonitor(activityMonitorTab)
        } label: {
            Label("Show in Activity Monitor", systemImage: "list.bullet.rectangle")
        }
        if app.path.hasPrefix("/") {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
    }
}

/// The bill's column headings. A click ranks by that column.
struct PanelAppBillHeader: View {
    @Binding var column: AppBillColumn

    var body: some View {
        HStack(spacing: Design.Space.s) {
            PanelSectionLabel("App")
            Spacer(minLength: Design.Space.xs)
            ForEach(AppBillColumn.allCases, id: \.self) { item in
                Button {
                    withAnimation(Design.Motion.respectingAccessibility(Design.Motion.value)) { column = item }
                } label: {
                    HStack(spacing: 2) {
                        if item == column {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        Text(localizing: item.title)
                            .font(Design.Text.caption.weight(.medium))
                            .textCase(.uppercase)
                            .kerning(0.3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(item == column ? Design.Palette.secondaryText : Design.Palette.tertiaryText)
                    .frame(width: item.width, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by \(item.title)")
                .accessibilityAddTraits(item == column ? .isSelected : [])
            }
        }
        .padding(.horizontal, Design.Space.s)
        .padding(.bottom, Design.Space.xxs)
    }
}

extension PanelAppIcon {
    /// The icon of an app's bundle; a plain executable has none of its own.
    static func icon(forApp app: AppUsage) -> PanelProcessIcon {
        icon(forKey: app.path, bundle: app.isBundle ? app.path : nil, bundleIdentifier: nil)
    }
}
