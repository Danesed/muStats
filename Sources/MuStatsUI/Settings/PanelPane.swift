import SwiftUI
import MuStatsKit

/// What the drop-down panel shows: the status line, the tabs, the module rows, and
/// module by module, every piece of an open module's detail.
struct PanelPane: View {
    let settings: SettingsStore

    private var panel: PanelSettings { settings.settings.panel }

    var body: some View {
        Form {
            Section {
                Picker("Show the status line", selection: settings.binding(\.panel.statusLine)) {
                    ForEach(PanelStatusLine.allCases, id: \.self) { mode in
                        Text(localizing: mode.label).tag(mode)
                    }
                }
            } header: {
                Text("Status Line")
            } footer: {
                SettingsFootnote("The line at the top of Now, such as \"Everything looks normal\" "
                                 + "or \"Memory pressure 88%\" with the app behind it.")
            }

            Section {
                Toggle("Today", isOn: settings.binding(\.panel.showsToday))
                Toggle("Chip", isOn: settings.binding(\.panel.showsLiveChip))
            } header: {
                Text("Tabs")
            } footer: {
                SettingsFootnote("Today is the day's CPU with its notable moments. Chip lights up the cores, "
                                 + "GPU and memory with their real load, and is drawn only while its tab is open.")
            }

            Section {
                elementToggle(.moduleSparklines)
                elementToggle(.moduleCaptions)
                Toggle("History charts in open modules", isOn: settings.binding(\.panel.showsHistoryChart))
                Picker("Default range", selection: settings.binding(\.panel.defaultHistoryRange)) {
                    ForEach(HistoryRange.allCases, id: \.self) { range in
                        Text(range.label(historyDuration: settings.settings.charts.historyDuration)).tag(range)
                    }
                }
                .disabled(!panel.showsHistoryChart)
            } header: {
                Text("Module Rows")
            }

            ForEach(panel.orderedModules, id: \.self) { module in
                moduleSection(module)
            }
        }
        .settingsFormStyle()
    }

    /// One module: whether it is in the panel, then each piece of its detail.
    @ViewBuilder
    private func moduleSection(_ module: PanelModule) -> some View {
        let shown = !panel.hiddenModules.contains(module)
        Section {
            Toggle(isOn: Binding(
                get: { shown },
                set: { on in
                    settings.update { s in
                        if on { s.panel.hiddenModules.remove(module) } else { s.panel.hiddenModules.insert(module) }
                    }
                })) {
                Label {
                    Text(localizing: module.label)
                } icon: {
                    Image(systemName: module.symbolName)
                }
            }
            // An empty Now tab is a panel with nothing in it.
            .disabled(shown && panel.visibleModules == [module])

            if shown {
                ForEach(PanelElement.inside(module), id: \.self) { element in
                    elementToggle(element)
                        .padding(.leading, Design.Space.l)
                }
                if module == .network {
                    Toggle("Listening ports and Docker", isOn: Binding(
                        get: { panel.developerToolsShown },
                        set: { value in settings.update { $0.panel.showsDeveloperTools = value } }))
                        .padding(.leading, Design.Space.l)
                }
            }
        } footer: {
            if let note = footnote(for: module), shown {
                SettingsFootnote(note)
            }
        }
    }

    private func elementToggle(_ element: PanelElement) -> some View {
        Toggle(isOn: Binding(
            get: { panel.shows(element) },
            set: { on in
                settings.update { s in
                    if on { s.panel.hiddenElements.remove(element) } else { s.panel.hiddenElements.insert(element) }
                }
            })) {
            Text(localizing: element.label)
        }
    }

    /// Where hiding a piece also stops a reading, the footnote says so.
    private func footnote(for module: PanelModule) -> String? {
        switch module {
        case .cpu, .memory, .disk, .battery:
            return "With Top processes off, this module no longer reads the process list."
        case .network:
            return "With Latency off, the network is not probed. Listening ports and Docker are on by "
                + "default when Xcode, Homebrew or Docker is installed."
        default:
            return nil
        }
    }
}
