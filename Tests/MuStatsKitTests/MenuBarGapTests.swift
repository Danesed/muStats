import Foundation
import Testing
@testable import MuStatsKit
@testable import MuStatsUI

@Suite("Menu bar history gaps")
struct MenuBarGapTests {
    private func item(_ metric: MenuBarMetric, _ history: MetricHistory,
                      snapshot: SystemSnapshot = SnapshotFixtures.nominal,
                      style: MenuBarDisplayStyle = .textAndGraph) -> MenuBarItemRender {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: metric, style: style)]
        return MenuBarRenderModel(snapshot: snapshot, history: history,
                                  settings: settings, isStale: false).items[0]
    }

    @Test("a gap remains a gap and does not affect the scale")
    func normalizedGap() {
        var history = MetricHistory()
        history.record(.fanRPM, 10)
        history.recordGap(.fanRPM)
        history.record(.fanRPM, 20)
        let series = item(.fanSpeed, history).primary.series
        #expect(series == [0.5, .infinity, 1])
    }

    @Test("paired rates ignore gaps when choosing their shared scale")
    func pairedGaps() {
        var history = MetricHistory()
        history.record(.diskRead, 100)
        history.recordGap(.diskRead)
        history.record(.diskRead, 200)
        history.record(.diskWrite, 50)
        history.record(.diskWrite, 100)
        history.recordGap(.diskWrite)
        let model = item(.diskActivity, history)
        #expect(model.primary.series == [0.5, .infinity, 1])
        #expect(model.secondary?.series == [0.25, 0.5, .infinity])
    }

    @Test("a network gap does not light the activity indicators")
    func gapIsNotActivity() {
        var snapshot = SnapshotFixtures.nominal
        snapshot.network = .value(SnapshotFixtures.network(down: 0, up: 0))
        var history = MetricHistory()
        history.recordGap(.networkDownload)
        history.recordGap(.networkUpload)
        let status = item(.networkThroughput, history, snapshot: snapshot, style: .statusDot).networkStatus
        #expect(status == .init(isOnline: true, isReceiving: false, isSending: false))
    }

    @Test("CPU ring average excludes missing readings")
    func cpuAverageExcludesGaps() {
        var history = MetricHistory()
        history.record(.cpuTotal, 0.2)
        history.recordGap(.cpuTotal)
        history.record(.cpuTotal, 0.6)
        let busy = RingsReading.fraction(of: .cpuUsage, snapshot: SnapshotFixtures.nominal, history: history)
        #expect(abs((busy ?? 0) - 0.4) < 0.0001)
    }
}
