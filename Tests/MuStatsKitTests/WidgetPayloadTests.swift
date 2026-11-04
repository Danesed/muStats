import Testing
import Foundation
@testable import MuStatsKit

@Suite("What the app hands the widgets")
struct WidgetPayloadTests {
    @Test("the rings follow the menu bar's, less those a widget cannot read, in its colours")
    func followsMenuBar() {
        var settings = Settings()
        settings.menuBar.ringMetrics = [.cpuUsage, .gpuUsage, .battery]
        settings.menuBar.ringColors = .ocean
        let own = ThemeColor(red: 1, green: 0, blue: 0)
        settings.menuBar.customRingColors = [nil, nil, own]
        let payload = WidgetPayload(settings: settings)
        #expect(payload.rings.map(\.metric) == ["cpu", "battery"])
        let first = RingColors.ocean.tones[0].dark
        #expect(payload.rings[0].dark == [first.0, first.1, first.2])
    }

    @Test("rings of their own, and an overview kept in order and never empty")
    func ownChoices() throws {
        var settings = Settings()
        settings.widgets.ringsFollowMenuBar = false
        settings.widgets.ringMetrics = WidgetSettings.sanitizedRings([.memoryPressure, .cpuTemperature, .diskUsage])
        settings.widgets.overviewMetrics = WidgetSettings.sanitizedOverview([.battery, .cpuUsage])
        let payload = WidgetPayload(settings: settings)
        #expect(payload.rings.map(\.metric) == ["pressure", "disk"])
        #expect(payload.overview == ["cpu", "battery"])
        #expect(WidgetSettings.sanitizedOverview([]) == WidgetSettings.defaultOverview)

        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.widgets == settings.widgets)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(old.widgets == WidgetSettings())
    }
}
