import AppKit
import MuStatsKit
import MuStatsUI

/// Wires the engine, the settings store and every piece of UI together, and owns
/// the system-level observers (sleep, wake, screen lock, display changes) that
/// decide how hard μStats is allowed to work.
@MainActor
final class AppCoordinator {

    private let settingsStore: SettingsStore
    private let engine: MetricsEngine

    private let statusItem: StatusItemController
    private let panel: PanelController
    private let settingsWindow: SettingsWindowController
    private let thresholdMonitor: ThresholdMonitor
    private let hotKeys: GlobalHotKeyCenter
    private let updater: SoftwareUpdater
    private let updateAnnouncer: UpdateAnnouncer
    private let widgetBridge: WidgetBridge
    /// Set from `MUSTATS_DEMO`: the app runs on fixture data for screenshots.
    private let demo: OffscreenRenderer.Scenario?

    private var observers: [any NSObjectProtocol] = []
    /// Where the panel is currently hung. Kept here because with one status item per
    /// readout, "toggle" has a third case: the click came from a different item than
    /// the one the panel is under.
    private var panelAnchor: NSRect?

    init() {
        let environment = ProcessInfo.processInfo.environment
        let demo = environment["MUSTATS_DEMO"].flatMap(OffscreenRenderer.Scenario.init(rawValue:))
        self.demo = demo
        // A demo keeps its settings in a temporary folder, seeded from
        // MUSTATS_DEMO_SETTINGS when given, so screenshots never touch the real ones.
        var directory: URL?
        if demo != nil {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("MuStatsDemo-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            if let seed = environment["MUSTATS_DEMO_SETTINGS"] {
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: seed),
                                                  to: temporary.appendingPathComponent("settings.json"))
            }
            directory = temporary
        }
        let store = SettingsStore(directory: directory)
        let engine = MetricsEngine(settingsStore: store)
        var updaterDefaults = UserDefaults.standard
        // A demo never sees a real update. MUSTATS_DEMO_UPDATE names a version to show
        // as waiting, kept in a throwaway domain rather than in the app's own.
        if demo != nil, let version = environment["MUSTATS_DEMO_UPDATE"], !version.isEmpty,
           let scratch = UserDefaults(suiteName: "com.danesed.muStats.demo") {
            scratch.removePersistentDomain(forName: "com.danesed.muStats.demo")
            SoftwareUpdater.seed(PendingUpdate(version: version, build: "999999", stage: .available),
                                 in: scratch)
            updaterDefaults = scratch
        }
        let updater = SoftwareUpdater(defaults: updaterDefaults)
        let authority = NotificationAuthority()
        self.settingsStore = store
        self.engine = engine
        self.updater = updater
        self.statusItem = StatusItemController(engine: engine, settings: store)
        self.panel = PanelController(engine: engine, settings: store, updates: updater)
        self.settingsWindow = SettingsWindowController(engine: engine, settings: store,
                                                      updater: updater, authority: authority)
        self.thresholdMonitor = ThresholdMonitor(engine: engine, settings: store, authority: authority)
        self.updateAnnouncer = UpdateAnnouncer(updates: updater, authority: authority)
        self.hotKeys = GlobalHotKeyCenter(settings: store)
        self.widgetBridge = WidgetBridge(store: store)
    }

    // MARK: Lifecycle

    func start() {
        statusItem.onPrimaryAction = { [weak self] in self?.togglePanel() }
        statusItem.onSecondaryAction = { [weak self] in self?.showContextMenu() }
        statusItem.onAlternateAction = { [weak self] metric in self?.openActivityMonitor(for: metric) }
        statusItem.onVisibilityChange = { [weak self] visible in
            self?.engine.setMenuBarOccluded(!visible)
        }

        panel.onVisibilityChange = { [weak self] visible in
            self?.engine.setPanelVisible(visible)
        }
        panel.onRequestSettings = { [weak self] in self?.showSettings() }
        panel.onRequestQuit = { NSApp.terminate(nil) }
        panel.onRequestActivityMonitor = { [weak self] tab in self?.openActivityMonitor(tab: tab) }

        // A hot key must do exactly what the equivalent menu item does, including
        // leaving the frontmost app alone: the panel is worth having precisely because
        // it can be summoned over another app without interrupting it.
        hotKeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .togglePanel: self.togglePanel()
            case .toggleMenuBarItem: self.toggleMenuBarItem()
            case .openSettings: self.showSettings()
            }
        }

        statusItem.install()
        if let demo {
            startDemo(demo)
            return
        }
        engine.systemUpdate = SystemUpdateRecord.noteLaunch()
        engine.start()
        thresholdMonitor.start()
        hotKeys.start()
        // Sparkle schedules its own checks from here, once a week, and shows its window
        // only when it finds something.
        updater.start()
        updateAnnouncer.start()
        widgetBridge.start()

        registerSystemObservers()
        // The system follows the stored preference, and then the preference follows the
        // system. Since the shipped default is on, a first launch registers the login
        // item here; a registration macOS refuses would otherwise leave the toggle
        // showing on for a login item that does not exist.
        LoginItem.synchronize(enabled: settingsStore.settings.general.launchAtLogin)
        if LoginItem.isEnabled != settingsStore.settings.general.launchAtLogin {
            settingsStore.update { $0.general.launchAtLogin = LoginItem.isEnabled }
        }
    }

    /// Fixture data in the real windows, with nothing sampled, scheduled or sent:
    /// no alerts, no update checks, no widget payload and no login item.
    private func startDemo(_ scenario: OffscreenRenderer.Scenario) {
        engine.loadFixture(snapshot: scenario.snapshot, history: scenario.history,
                           dayHistory: scenario.dayHistory(),
                           monthHistory: SnapshotFixtures.monthHistory())
        // Fixtures carry a fixed date, which would otherwise read as stale.
        engine.staleOverride = false
        // "panel", "settings" or a PanelModule to open expanded.
        guard let target = ProcessInfo.processInfo.environment["MUSTATS_DEMO_OPEN"] else { return }
        // Two seconds: at one the status item was sometimes not placed yet, and the
        // panel had nothing to hang from.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            switch target {
            case "panel": self.togglePanel()
            case "settings": self.showSettings()
            default:
                if let module = PanelModule(rawValue: target) { self.openPanel(on: module) }
            }
        }
    }

    func shutdown() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        updateAnnouncer.stop()
        hotKeys.stop()
        thresholdMonitor.stop()
        engine.stop()
        statusItem.remove()
        settingsStore.flush()
    }

    // MARK: Actions

    /// Open the panel with `module` expanded, as a widget asks for.
    func openPanel(on module: PanelModule) {
        let anchor = statusItem.anchorRect
        panelAnchor = anchor
        panel.show(expanding: module, anchoredTo: anchor, on: statusItem.anchorScreen)
    }

    private func togglePanel() {
        let anchor = statusItem.anchorRect
        guard panel.isVisible else {
            panelAnchor = anchor
            panel.show(anchoredTo: anchor, on: statusItem.anchorScreen)
            return
        }
        // Clicking a second readout's item moves the panel under it. Dismissing there
        // would read as the click having missed: the user pointed at a different item
        // and got nothing.
        if let anchor, let panelAnchor, anchor != panelAnchor {
            self.panelAnchor = anchor
            panel.reanchor(to: anchor, on: statusItem.anchorScreen)
            return
        }
        panel.hide()
        panelAnchor = nil
    }

    /// Bring Settings up, from wherever the request came from.
    ///
    /// Also the answer to a second launch: the app has no dock icon and no window of
    /// its own, so opening it from Spotlight or the Finder while it is already running
    /// used to do nothing at all, which is indistinguishable from the app being broken.
    func showSettings() {
        panel.hide()
        settingsWindow.show()
    }

    /// The panel hangs from the item, so it goes with it.
    private func toggleMenuBarItem() {
        if panel.isVisible {
            panel.hide()
            panelAnchor = nil
        }
        settingsStore.update { $0.menuBar.isVisible.toggle() }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(menuShowSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit μStats"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.presentMenu(menu)
    }

    @objc private func menuShowSettings() { showSettings() }

    /// Opens Activity Monitor on the tab behind the readout that was Option-clicked.
    ///
    /// The tab is chosen by writing the preference Activity Monitor itself saves when
    /// you switch tabs, which it reads on launch. There is no scripting interface for
    /// it, so when Activity Monitor is already running the tab cannot be changed from
    /// outside and it is simply brought forward as the user left it.
    private func openActivityMonitor(for metric: MenuBarMetric?) {
        openActivityMonitor(tab: metric?.activityMonitorTab)
    }

    private func openActivityMonitor(tab: Int?) {
        let bundleID = "com.apple.ActivityMonitor"
        let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        if let tab, !isRunning {
            CFPreferencesSetAppValue("SelectedTab" as CFString,
                                     tab as CFNumber,
                                     bundleID as CFString)
            CFPreferencesAppSynchronize(bundleID as CFString)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: System observers

    private func registerSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter

        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(false) }
        })
        // Display sleep is far more common than system sleep on a desktop Mac and
        // is just as good a reason to stop sampling.
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setScreensAsleep(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setScreensAsleep(false) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSessionActive(false) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSessionActive(true) }
        })

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"),
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setLocked(true) }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setLocked(false) }
        })

        // Screen reconfiguration moves the status item and can invalidate the
        // panel's anchor; re-anchor rather than leaving the panel stranded.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.panel.isVisible {
                        self.panelAnchor = self.statusItem.anchorRect
                        self.panel.reanchor(to: self.panelAnchor,
                                            on: self.statusItem.anchorScreen)
                    }
                }
        })
    }
}
