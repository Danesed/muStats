import Testing
import AppKit
@testable import MuStatsKit
@testable import MuStatsUI

@MainActor
@Suite("Panel navigation", .serialized)
struct PanelNavigationTests {
    private func makeController() -> (PanelController, MetricsEngine, SettingsStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelNavigationTests-\(UUID().uuidString)")
        let settings = SettingsStore(directory: directory)
        settings.update { $0.panel.showsLiveChip = true }
        let engine = MetricsEngine(settingsStore: settings)
        engine.loadFixture(snapshot: SnapshotFixtures.nominal, history: MetricHistory())
        return (PanelController(engine: engine, settings: settings), engine, settings)
    }

    @Test("only details with process rows request the process list")
    func detailSources() {
        #expect(PanelRootView.detailSources(for: []).isEmpty)
        #expect(PanelRootView.detailSources(for: [.cpu]) == [.cpu, .processes])
        #expect(PanelRootView.detailSources(for: [.memory]) == [.memory, .processes])
        #expect(PanelRootView.detailSources(for: [.disk]) == [.disk, .processes])
        #expect(PanelRootView.detailSources(for: [.battery]) == [.power, .processes])
        #expect(PanelRootView.detailSources(for: [.network]) == [.network])
        #expect(PanelRootView.detailSources(for: [.gpu]) == [.gpu])
    }

    @Test("widget requests switch to Now and expand the selected module")
    func widgetNavigationState() throws {
        let (controller, _, settings) = makeController()
        controller.show(anchoredTo: nil, on: nil)
        let layout = try #require(controller.layout)
        layout.selectedTab = .today
        controller.show(expanding: .disk, anchoredTo: nil, on: nil)
        #expect(layout.selectedTab == .now)
        #expect(layout.requestedModule == .disk)
        #expect(!settings.settings.panel.collapsedModules.contains(.disk))

        controller.hide()
        layout.selectedTab = .chip
        controller.show(expanding: .memory, anchoredTo: nil, on: nil)
        #expect(controller.layout === layout)
        #expect(layout.selectedTab == .now)
        #expect(layout.requestedModule == .memory)
        #expect(!settings.settings.panel.collapsedModules.contains(.memory))
        controller.hide()
    }

    @Test("a widget opens and scrolls to its module from another tab and after reopening")
    func widgetNavigation() async throws {
        let (controller, engine, settings) = makeController()
        let screen = try #require(NSScreen.main)
        let anchor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.minY + 240,
                            width: 30, height: 22)
        controller.show(anchoredTo: anchor, on: screen)
        let layout = try #require(controller.layout)
        try await Task.sleep(for: .milliseconds(100))
        let scroll = try #require(scrollView(in: controller.window?.contentView))
        let top = scroll.documentVisibleRect.minY

        layout.selectedTab = .today
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.panelDetails.isEmpty)
        #expect(!engine.panelProcessCount)
        controller.show(expanding: .system, anchoredTo: anchor, on: screen)
        try await Task.sleep(for: .milliseconds(500))
        #expect(layout.selectedTab == .now)
        #expect(!settings.settings.panel.collapsedModules.contains(.system))
        #expect(layout.requestedModule == .system)
        #expect(abs(scroll.documentVisibleRect.minY - top) > 20)
        #expect(engine.panelDetails == [.system])
        #expect(engine.panelProcessCount)

        controller.hide()
        #expect(engine.panelDetails.isEmpty)
        #expect(!engine.panelProcessCount)
        layout.selectedTab = .chip
        controller.show(expanding: .memory, anchoredTo: anchor, on: screen)
        try await Task.sleep(for: .milliseconds(300))
        #expect(layout.selectedTab == .now)
        #expect(!settings.settings.panel.collapsedModules.contains(.memory))
        #expect(engine.panelDetails == [.memory, .processes])
        #expect(engine.panelProcessCount)
        controller.hide()
    }

    @Test("memory pressure releases only a hidden window")
    func memoryPressure() async throws {
        let (controller, _, _) = makeController()
        controller.show(anchoredTo: nil, on: NSScreen.main)
        let window = try #require(controller.window)
        controller.handleMemoryPressure()
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.window === window)
        controller.hide()
        controller.handleMemoryPressure()
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.window == nil)
    }

    private func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }
}
