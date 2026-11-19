import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MuStatsKit

struct AboutPane: View {
    let settings: SettingsStore
    let engine: MetricsEngine?
    /// Absent in the offscreen renderer, which has no running app to update.
    var updater: SoftwareUpdater?

    @State private var transferResult: String?
    @State private var transferFailed = false
    @State private var isConfirmingFullReset = false
    @State private var logoTaps = 0

    /// Live identity when the app is running; the render harness has no engine, so
    /// it shows the same fixture machine every other rendered surface shows.
    private var systemState: MetricState<SystemInfoSnapshot> {
        engine?.system ?? .value(SnapshotFixtures.system())
    }

    private var formatter: MetricFormatter {
        MetricFormatter(settings: settings.settings.general)
    }

    /// Seven clicks on the logo, and it grows one. Seven more and it is shaved.
    private var wearsMoustache: Bool { (logoTaps / 7) % 2 == 1 }

    private var moustache: some View {
        MoustacheShape()
            .frame(width: 24, height: 24 / Moustache.aspect)
            .offset(y: 8)
            .scaleEffect(wearsMoustache ? 1 : 0.2, anchor: .center)
            .opacity(wearsMoustache ? 1 : 0)
            .animation(Design.Motion.respectingAccessibility(.spring(duration: 0.35, bounce: 0)), value: wearsMoustache)
            .accessibilityHidden(true)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Design.Space.xl) {
                    LogoMark(size: 52)
                        .overlay { moustache }
                        .foregroundStyle(Design.Palette.primaryText)
                        .contentShape(Rectangle())
                        .onTapGesture { logoTaps += 1 }
                    VStack(alignment: .leading, spacing: Design.Space.xxs) {
                        Text("μStats").font(.title2.weight(.medium))
                        Text(versionText).foregroundStyle(Design.Palette.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, Design.Space.xs)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("μStats, \(versionText)")
            }

            // Every update control in one place, under the version it would replace:
            // "is this up to date, and will it stay that way" is answered in one look.
            Section {
                // The answer to a check is drawn beside the button rather than in
                // Sparkle's alert. Only an update opens a window, and only when the
                // user asks to install it, because that window carries the release
                // notes and the Install button.
                HStack(spacing: Design.Space.l) {
                    if let pending = updater?.pending {
                        Button(pending.isReadyToInstall ? "Restart" : "Install…") {
                            updater?.installPending()
                        }
                        .accessibilityHint(pending.isReadyToInstall
                                           ? "Relaunches μStats into the new version"
                                           : "Opens the updater to install it")
                        Button("Skip This Version") { updater?.skipPending() }
                            .help("Skip this version. A newer one will still be offered.")
                    } else {
                        Button("Check Now") { updater?.checkQuietly() }
                            .disabled(updater?.canCheck != true)
                            .accessibilityHint("Asks GitHub whether a newer version exists")
                    }
                    Spacer()
                    updateStatus
                }
                // Stored by Sparkle rather than in the settings file, so this reads and
                // writes the updater itself. Only the offscreen renderer has none.
                Toggle("Check for updates automatically", isOn: checksAutomatically)
                    .disabled(updater == nil)
                // Sparkle offers the same choice the first time it installs something,
                // and takes the answer as standing. Without this row the only way back
                // is to wait for another release and refuse it there.
                Toggle("Install updates automatically", isOn: installsAutomatically)
                    .disabled(updater == nil || !(updater?.checksAutomatically ?? false))
            } header: {
                Text("Updates")
            }

            Section {
                MetricContent(systemState) { system in
                    Group {
                        LabeledContent("Computer", value: system.computerName)
                        LabeledContent("Model", value: system.modelName)
                        LabeledContent("Chip", value: system.chipName)
                        LabeledContent("Cores", value: coreText(system))
                        LabeledContent("Memory", value: formatter.memory(system.totalMemoryBytes))
                        LabeledContent("System", value: "\(system.osName) \(system.osVersion) (\(system.osBuild))")
                        LabeledContent("Uptime", value: formatter.compactUptime(system.uptime))
                    }
                }
            } header: {
                Text("This Mac")
            }

            Section {
                HStack(spacing: Design.Space.l) {
                    Button("Export…") { export() }
                        .accessibilityHint("Writes your settings to a JSON file")
                    Button("Import…") { importSettings() }
                        .accessibilityHint("Replaces your settings from a JSON file")
                    Spacer()
                }
                if let transferResult {
                    if transferFailed {
                        SettingsCaution(transferResult)
                    } else {
                        SettingsFootnote(transferResult)
                    }
                }
                LabeledContent("Location", value: settings.settingsFileURL.path)
                    .font(.callout)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .textSelection(.enabled)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([settings.settingsFileURL])
                }
            } header: {
                Text("Settings File")
            }

            // One section's defaults are restored from the bar under that section's
            // own pane, where the user can see what is about to change. This is the
            // only reset that reaches settings you are not looking at, so it is the
            // only one that belongs here.
            Section {
                Button("Restore All Settings…", role: .destructive) { isConfirmingFullReset = true }
                    .confirmationDialog("Restore every setting to its defaults?",
                                        isPresented: $isConfirmingFullReset) {
                        Button("Restore All Settings", role: .destructive) {
                            settings.resetToDefaults()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Your menu bar readouts, colours, notification rules and shortcuts all go back to their defaults.")
                    }
            } header: {
                Text("Reset")
            } footer: {
                if let diagnostic = settings.loadDiagnostic {
                    SettingsCaution(diagnostic)
                }
            }
        }
        .settingsFormStyle()
    }

    private var checksAutomatically: Binding<Bool> {
        Binding(get: { updater?.checksAutomatically ?? true },
                set: { updater?.setChecksAutomatically($0) })
    }

    private var installsAutomatically: Binding<Bool> {
        Binding(get: { updater?.installsAutomatically ?? false },
                set: { updater?.setInstallsAutomatically($0) })
    }

    /// The state of updates, beside the button that changes it. It also answers "is
    /// this thing actually running?": the automatic check is silent when it finds
    /// nothing, so without the checked time a user who never pressed anything would see
    /// no sign of it at all. A failure is named, because Sparkle stamps the check date
    /// on failure too and a feed unreachable for a month would otherwise read as fine.
    @ViewBuilder
    private var updateStatus: some View {
        if updater?.isChecking == true {
            HStack(spacing: Design.Space.s) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
            .foregroundStyle(.secondary)
        } else if let failure = updater?.lastCheckFailure {
            Text("Couldn't check")
                .foregroundStyle(.secondary)
                .help(failure)
                .accessibilityValue(failure)
        } else if updater?.pending != nil || updater?.lastCheck != nil {
            VStack(alignment: .trailing, spacing: Design.Space.xxs) {
                if let pending = updater?.pending {
                    Text(pending.isReadyToInstall ? "μStats \(pending.version) is ready"
                                                  : "μStats \(pending.version) is available")
                } else {
                    Text("Up to date")
                }
                if let checked = updater?.lastCheck {
                    Text("Checked \(Self.checkedPhrase(checked))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    /// A check that has just finished is stamped a moment after the `Date()` it is
    /// drawn against, and the formatter reads that as "in 0 seconds".
    private static func checkedPhrase(_ checked: Date) -> String {
        let now = Date()
        guard now.timeIntervalSince(checked) >= 60 else { return "just now" }
        return relative.localizedString(for: checked, relativeTo: now)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// The marketing version alone. The build number beside it is what Sparkle
    /// compares releases by and means nothing to the person reading it.
    private var versionText: String {
        guard let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            // Running the bare SwiftPM binary rather than the assembled .app.
            return "Development build"
        }
        return "Version \(short)"
    }

    private func coreText(_ system: SystemInfoSnapshot) -> String {
        var text = "\(system.logicalCores)"
        if system.performanceCores > 0 || system.efficiencyCores > 0 {
            text += " (\(system.performanceCores) performance, \(system.efficiencyCores) efficiency)"
        }
        if let gpu = system.gpuCoreCount {
            text += " · \(gpu) GPU"
        }
        return text
    }

    // MARK: Import / export

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "μStats Settings.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.exportJSON().write(to: url, options: .atomic)
            transferFailed = false
            transferResult = "Exported to \(url.lastPathComponent)."
        } catch {
            transferFailed = true
            transferResult = "Could not export: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.importJSON(Data(contentsOf: url))
            transferFailed = false
            transferResult = "Imported from \(url.lastPathComponent)."
        } catch {
            transferFailed = true
            transferResult = "\(url.lastPathComponent) is not a settings file μStats can read. Your settings are unchanged."
        }
    }
}
