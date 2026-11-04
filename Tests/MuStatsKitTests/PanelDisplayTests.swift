import Testing
import Foundation
@testable import MuStatsKit
@testable import MuStatsUI

/// Settings > Panel: what the user hides stays hidden, and costs nothing to read.
@MainActor
@Suite("What the panel shows")
struct PanelDisplayTests {

    @Test("a settings file from before the Panel tab shows everything")
    func olderFileShowsEverything() throws {
        let panel = try JSONDecoder().decode(PanelSettings.self, from: Data(#"{"showsToday":true}"#.utf8))
        #expect(panel.statusLine == .always)
        #expect(panel.hiddenModules.isEmpty)
        #expect(PanelElement.allCases.allSatisfy(panel.shows))
    }

    @Test("a piece a newer build removed is dropped, the rest kept")
    func unknownElementIsDropped() throws {
        let json = #"{"hiddenElements":["cpuLoad","somethingRemoved"],"statusLine":"whenNotable"}"#
        let panel = try JSONDecoder().decode(PanelSettings.self, from: Data(json.utf8))
        #expect(panel.hiddenElements == [.cpuLoad])
        #expect(panel.statusLine == .whenNotable)
    }

    @Test("choices survive a round trip through the settings file")
    func roundTrip() throws {
        var panel = PanelSettings()
        panel.statusLine = .never
        panel.hiddenModules = [.gpu]
        panel.hiddenElements = [.networkLatency, .moduleSparklines]
        let decoded = try JSONDecoder().decode(PanelSettings.self, from: JSONEncoder().encode(panel))
        #expect(decoded == panel)
    }

    @Test("a hidden module leaves the panel and its sources, but keeps its place")
    func hiddenModule() {
        var settings = Settings()
        settings.panel.moduleOrder = [.battery, .cpu, .gpu]
        settings.panel.hiddenModules = [.gpu]
        #expect(!settings.panel.visibleModules.contains(.gpu))
        #expect(settings.panel.orderedModules.prefix(3) == [.battery, .cpu, .gpu])
        #expect(!settings.requiredSources(panelVisible: true).contains(.gpu))

        // Reordering while it is hidden does not lose it.
        let order = settings.panel.moduleOrder(moving: .cpu, before: .battery)
        #expect(order.contains(.gpu))
    }

    @Test("an open module asks for processes only while it lists them")
    func processesFollowTheToggle() {
        var panel = PanelSettings()
        #expect(PanelRootView.detailSources(for: [.cpu], panel: panel) == [.cpu, .processes])
        panel.hiddenElements = [.cpuProcesses]
        #expect(PanelRootView.detailSources(for: [.cpu], panel: panel) == [.cpu])
        // The process module is its list, so it always reads it.
        #expect(PanelRootView.detailSources(for: [.processes], panel: panel) == [.processes])
    }

    @Test("the status line follows the user's choice")
    func statusLine() {
        #expect(PanelRootView.showsStatusLine(.always, level: .none))
        #expect(!PanelRootView.showsStatusLine(.whenNotable, level: .none))
        #expect(PanelRootView.showsStatusLine(.whenNotable, level: .warning))
        #expect(!PanelRootView.showsStatusLine(.never, level: .critical))
    }

    @Test("every piece of a module's detail belongs to exactly one module")
    func elementsAreGrouped() {
        let inModules = PanelModule.allCases.flatMap(PanelElement.inside)
        let panelWide = PanelElement.allCases.filter { $0.module == nil }
        #expect(inModules.count + panelWide.count == PanelElement.allCases.count)
        #expect(Set(inModules).count == inModules.count)
    }

    @Test("restoring the Panel tab keeps the order and the open module")
    func resetKeepsLayout() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelDisplayTests-\(UUID().uuidString)")
        let store = SettingsStore(directory: directory)
        store.update {
            $0.panel.moduleOrder = [.disk, .cpu]
            $0.panel.hiddenElements = [.cpuCores]
            $0.panel.statusLine = .never
        }
        store.resetSection(.panel)
        #expect(store.settings.panel.moduleOrder == [.disk, .cpu])
        #expect(store.settings.panel.hiddenElements.isEmpty)
        #expect(store.settings.panel.statusLine == .always)
    }
}
