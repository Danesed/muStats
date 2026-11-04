import SwiftUI
import MuStatsKit

/// What the desktop widgets show. The widgets themselves are added from macOS: this
/// pane decides what they draw once they are there.
struct WidgetsPane: View {
    let settings: SettingsStore

    private var widgets: WidgetSettings { settings.settings.widgets }
    private var menuBar: MenuBarSettings { settings.settings.menuBar }

    var body: some View {
        Form {
            Section {
                Toggle("Same rings as the menu bar", isOn: settings.binding(\.widgets.ringsFollowMenuBar))
                if !widgets.ringsFollowMenuBar {
                    ringPickers
                }
            } header: {
                Text("Rings")
            } footer: {
                SettingsFootnote("Colours come from Appearance. Temperature and GPU rings are left out: "
                                 + "a widget reads only what macOS lets it read on its own.")
            }

            Section {
                ForEach(WidgetSettings.metrics, id: \.self) { metric in
                    Toggle(isOn: Binding(
                        get: { widgets.overviewMetrics.contains(metric) },
                        set: { on in
                            settings.update { s in
                                var list = s.widgets.overviewMetrics.filter { $0 != metric }
                                if on { list.append(metric) }
                                s.widgets.overviewMetrics = WidgetSettings.sanitizedOverview(list)
                            }
                        })) {
                        Text(localizing: metric.ringLabel)
                    }
                    // The last row cannot be switched off: an empty overview is a
                    // blank tile on the desktop.
                    .disabled(widgets.overviewMetrics == [metric])
                }
            } header: {
                Text("Overview")
            }

            Section {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    Label("Right-click the desktop and choose Edit Widgets.", systemImage: "1.circle")
                    Label("Search for muStats, then drag a widget to the desktop.", systemImage: "2.circle")
                }
                .font(.callout)
                .foregroundStyle(Design.Palette.secondaryText)
            } header: {
                Text("Adding a Widget")
            } footer: {
                SettingsFootnote("Changes here redraw the widgets at once. Their readings refresh "
                                 + "about every 15 minutes, as often as macOS allows, and each "
                                 + "widget shows when its reading was taken.")
            }
        }
        .settingsFormStyle()
    }

    /// One picker per ring, outermost first, as in the menu bar pane: a reading taken
    /// by another ring swaps the two.
    @ViewBuilder
    private var ringPickers: some View {
        let rings = widgets.ringMetrics
        ForEach(Array(rings.enumerated()), id: \.offset) { index, metric in
            HStack(spacing: Design.Space.s) {
                Circle()
                    .strokeBorder(RingPalette.color(ring: index, onDark: true, colors: menuBar.ringColors,
                                                    custom: menuBar.customRingColors),
                                  lineWidth: 3)
                    .frame(width: 14, height: 14)
                Picker(selection: Binding(
                    get: { metric },
                    set: { new in
                        settings.update { s in
                            var list = s.widgets.ringMetrics
                            if let other = list.firstIndex(of: new) { list[other] = list[index] }
                            list[index] = new
                            s.widgets.ringMetrics = WidgetSettings.sanitizedRings(list)
                        }
                    })) {
                    ForEach(WidgetSettings.metrics, id: \.self) { option in
                        Text(localizing: option.ringLabel).tag(option)
                    }
                } label: {
                    Text(localizing: ["Outer ring", "Middle ring", "Inner ring"][index])
                }
                if rings.count > 1 {
                    RowIconButton(systemName: "minus.circle", help: "Remove this ring", label: "Remove this ring") {
                        settings.update { s in
                            var list = s.widgets.ringMetrics
                            list.remove(at: index)
                            s.widgets.ringMetrics = WidgetSettings.sanitizedRings(list)
                        }
                    }
                }
            }
        }
        if rings.count < MenuBarSettings.maximumRings,
           let next = WidgetSettings.metrics.first(where: { !rings.contains($0) }) {
            Button("Add a Ring") {
                settings.update { s in
                    s.widgets.ringMetrics = WidgetSettings.sanitizedRings(s.widgets.ringMetrics + [next])
                }
            }
        }
    }
}
