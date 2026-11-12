import Testing
import Foundation
import SwiftUI
@testable import MuStatsKit
@testable import MuStatsUI

/// One row per app, with everything it runs counted in.
@MainActor
@Suite("The bill per app")
struct AppBillTests {

    @Test("a helper nested in its own bundle still belongs to the outer app")
    func identity() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework"
            + "/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(AppUsage.identity(forExecutable: helper) == ("/Applications/Google Chrome.app", "Google Chrome"))
        let compiler = "/Applications/Xcode.app/Contents/Developer/Toolchains/X.xctoolchain/usr/bin/swift-frontend"
        #expect(AppUsage.identity(forExecutable: compiler).name == "Xcode")
        // Outside a bundle an executable stands for itself, under its file name.
        #expect(AppUsage.identity(forExecutable: "/usr/libexec/logd") == ("/usr/libexec/logd", "logd"))
        #expect(AppUsage.identity(forExecutable: "/Applications/Music.app") == ("/Applications/Music.app", "Music"))
    }

    @Test("an app's bill is the sum of its processes, and names its busiest one")
    func grouping() {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/"
        let rows = [
            ProcessRow(pid: 1, name: "Google Chrome", executablePath: chrome + "Google Chrome",
                       cpuPercent: 10, memoryBytes: 400, energyImpact: 1),
            ProcessRow(pid: 2, name: "Helper", executablePath: chrome + "Helper", cpuPercent: 30, memoryBytes: 500),
            ProcessRow(pid: 3, name: "logd", executablePath: "/usr/libexec/logd", cpuPercent: 25, memoryBytes: 50),
            ProcessRow(pid: 4, name: "Helper", executablePath: chrome + "Helper", cpuPercent: 5, memoryBytes: 300,
                       energyImpact: 0.5),
        ]
        let apps = AppUsage.grouping(rows)
        #expect(apps.map(\.name) == ["Google Chrome", "logd"])
        let app = apps[0]
        #expect(app.processCount == 3)
        #expect(app.cpuPercent == 45)
        #expect(app.memoryBytes == 1_200)
        #expect(app.watts == 1.5)
        #expect(app.leaderPID == 2)
        #expect(app.isBundle)
        // No process of it reported energy: unknown, not zero.
        #expect(apps[1].watts == nil)
        #expect(!apps[1].isBundle)
    }

    @Test("a snapshot built from rows alone still has its bills")
    func snapshotDefault() {
        let snapshot = ProcessSnapshot(processes: [ProcessRow(pid: 1, name: "a", executablePath: "/bin/a", cpuPercent: 3)])
        #expect(snapshot.apps.count == 1)
        #expect(snapshot.apps[0].cpuPercent == 3)
    }

    @Test("the bill ranks by the column asked for, and ties keep the CPU order")
    func ranked() {
        let apps = [
            AppUsage(path: "/a.app", name: "a", cpuPercent: 90, memoryBytes: 100, watts: 2),
            AppUsage(path: "/b.app", name: "b", cpuPercent: 50, memoryBytes: 900, watts: nil),
            AppUsage(path: "/c.app", name: "c", cpuPercent: 10, memoryBytes: 500, watts: 2),
        ]
        #expect(PanelAppBill.ranked(apps, by: .cpu, count: 2).map(\.name) == ["a", "b"])
        #expect(PanelAppBill.ranked(apps, by: .memory, count: 3).map(\.name) == ["b", "c", "a"])
        #expect(PanelAppBill.ranked(apps, by: .energy, count: 3).map(\.name) == ["a", "c", "b"])
    }

    @Test("the status line names the app with the largest bill")
    func culprit() {
        let apps = [AppUsage(path: "/a.app", name: "a", cpuPercent: 5, memoryBytes: 900),
                    AppUsage(path: "/b.app", name: "b", cpuPercent: 80, memoryBytes: 100)]
        #expect(PanelCulprit.top(apps: apps) { $0.cpuPercent } == PanelCulprit.Entry(name: "b", value: 80))
        #expect(PanelCulprit.top(apps: apps) { Double($0.memoryBytes) }?.name == "a")
        #expect(PanelCulprit.top(apps: []) { $0.cpuPercent } == nil)
    }

    @Test("the live collector bills every process, not only the rows it lists")
    func liveCollector() throws {
        let collector = ProcessCollector()
        collector.start()
        defer { collector.stop() }
        _ = collector.collect(context: SampleContext(elapsed: 0, isFirstSample: true, activity: .panel))
        Thread.sleep(forTimeInterval: 0.3)
        let state = collector.collect(context: SampleContext(elapsed: 0.3, isFirstSample: false, activity: .panel))
        let snapshot = try #require(state.value)
        #expect(!snapshot.apps.isEmpty)
        let cpu = snapshot.apps.map(\.cpuPercent)
        #expect(cpu == cpu.sorted(by: >), "apps must come in CPU order")
        for app in snapshot.apps {
            #expect(app.processCount >= 1)
            #expect(!app.name.isEmpty)
            #expect(app.memoryBytes > 0)
            #expect(app.leaderPID > 0)
        }
        // More processes are billed than rows are listed, on any Mac running more
        // than sixty of this user's processes.
        let billed = snapshot.apps.reduce(0) { $0 + $1.processCount }
        #expect(billed <= snapshot.totalProcessCount)
        // A listed process is never larger than the app it belongs to.
        for row in snapshot.processes {
            guard let path = row.executablePath else { continue }
            let identity = AppUsage.identity(forExecutable: path)
            guard let app = snapshot.apps.first(where: { $0.path == identity.path }) else { continue }
            #expect(app.memoryBytes >= row.memoryBytes, "\(app.name) smaller than its own \(row.name)")
        }
    }
}

/// Where the panel puts the reader's eye: the rows that step back, what was missed
/// while it was closed, and the module it opens on.
@MainActor
@Suite("Where the panel points")
struct AttentionTests {

    private static let now = SnapshotFixtures.referenceDate
    private let all = PanelModule.allCases

    private func engine(_ snapshot: SystemSnapshot) -> MetricsEngine {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionTests-\(UUID().uuidString)")
        let engine = MetricsEngine(settingsStore: SettingsStore(directory: dir))
        engine.loadFixture(snapshot: snapshot, history: SnapshotFixtures.history(),
                           dayHistory: SnapshotFixtures.dayHistory(),
                           monthHistory: SnapshotFixtures.monthHistory())
        return engine
    }

    @Test("with nothing to say every row keeps its contrast")
    func calmPanel() {
        let emphasis = PanelRowEmphasis.assign(all, alerting: [], noticed: nil, expanded: [], dims: true)
        #expect(emphasis.values.allSatisfy { $0 == .normal })
    }

    @Test("a row in alert sends the calm ones back, except the one the reader opened")
    func recedes() {
        let emphasis = PanelRowEmphasis.assign(all, alerting: [.cpu, .thermal], noticed: nil,
                                               expanded: [.disk], dims: true)
        #expect(emphasis[.cpu] == .normal)
        #expect(emphasis[.thermal] == .normal)
        #expect(emphasis[.memory] == .receded)
        #expect(emphasis[.disk] == .normal)
        #expect(emphasis.values.filter { $0 == .receded }.count == all.count - 3)
    }

    @Test("a notice marks its row, and the setting only stops the dimming")
    func noticed() {
        let on = PanelRowEmphasis.assign(all, alerting: [], noticed: .memory, expanded: [], dims: true)
        #expect(on[.memory] == .noticed)
        #expect(on[.cpu] == .receded)
        let off = PanelRowEmphasis.assign(all, alerting: [], noticed: .memory, expanded: [], dims: false)
        #expect(off[.memory] == .noticed)
        #expect(off[.cpu] == .normal)
        // In alert as well, the row is an alert: red outranks blue.
        let both = PanelRowEmphasis.assign(all, alerting: [.memory], noticed: .memory, expanded: [], dims: true)
        #expect(both[.memory] == .normal)
    }

    private func event(_ kind: PanelEvent.Kind, level: PanelAlertLevel, minutesAgo: Double,
                       lasting: Double = 4) -> PanelEvent {
        let start = Self.now.addingTimeInterval(-60 * minutesAgo)
        return PanelEvent(kind: kind, level: level, start: start, end: start.addingTimeInterval(60 * lasting),
                          peak: 0.9, position: 0.5, culprit: "Xcode")
    }

    @Test("a panel closed for a moment has nothing to recap")
    func recapNeedsAGap() {
        let events = [event(.cpu, level: .warning, minutesAgo: 3, lasting: 2)]
        #expect(PanelRecap.make(events: events, since: Self.now.addingTimeInterval(-4 * 60), now: Self.now) == nil)
        #expect(PanelRecap.make(events: events, since: nil, now: Self.now) == nil)
        #expect(PanelRecap.make(events: events, since: Self.now.addingTimeInterval(-10 * 60), now: Self.now) != nil)
    }

    @Test("the recap is the loudest stretch since the panel closed, the later of two as loud")
    func recapPicks() throws {
        let since = Self.now.addingTimeInterval(-3_600)
        let events = [
            event(.cpu, level: .critical, minutesAgo: 120),      // ended before the panel closed
            event(.heat, level: .warning, minutesAgo: 50),
            event(.memory, level: .critical, minutesAgo: 40),
            event(.cpu, level: .critical, minutesAgo: 20),
            event(.cpu, level: .warning, minutesAgo: 8),
        ]
        let recap = try #require(PanelRecap.make(events: events, since: since, now: Self.now))
        #expect(recap.event == events[3])
        // A stretch still running when the panel closed was only half seen.
        let straddling = [event(.cpu, level: .warning, minutesAgo: 62, lasting: 10)]
        #expect(PanelRecap.make(events: straddling, since: since, now: Self.now) != nil)
    }

    @Test("a calm panel opens on what was missed, in the past tense, and stays calm")
    func recapLine() throws {
        let engine = engine(SnapshotFixtures.nominal)
        let formatter = MetricFormatter()
        let events = PanelEvents.detect(in: engine.dayHistory)
        let recap = try #require(PanelRecap.make(events: events, since: Self.now.addingTimeInterval(-6 * 3_600),
                                                 now: Self.now))
        let insight = PanelInsight.make(modules: all, engine: engine, formatter: formatter, recap: recap)
        #expect(insight.isPast)
        #expect(insight.level == .none)
        #expect(!insight.isNotice, "a stretch that is over must not mark a row as unusual now")
        #expect(insight.isNotable)
        #expect(insight.headline == recap.event.pastTitle(using: formatter))
        #expect(insight.detail == recap.event.culprit)
        // Without a recap the same panel is quiet.
        #expect(!PanelInsight.make(modules: all, engine: engine, formatter: formatter).isPast)
    }

    @Test("a reading in alert now outranks anything that was missed")
    func alertOutranksRecap() throws {
        let engine = engine(SnapshotFixtures.underLoad)
        let recap = PanelRecap(event: event(.cpu, level: .critical, minutesAgo: 30), since: Self.now.addingTimeInterval(-3_600))
        let insight = PanelInsight.make(modules: all, engine: engine, formatter: MetricFormatter(), recap: recap)
        #expect(insight.level != .none)
        #expect(!insight.isPast)
    }

    @Test("the panel opens on the module in alert, unless told not to")
    func opensOnAlert() {
        var panel = PanelSettings()
        #expect(PanelController.moduleToOpen(panel: panel, alerting: .memory, declined: nil) == .memory)
        #expect(PanelController.moduleToOpen(panel: panel, alerting: nil, declined: nil) == nil)
        // Folded by the user the last time: one refusal is an answer.
        #expect(PanelController.moduleToOpen(panel: panel, alerting: .memory, declined: .memory) == nil)
        #expect(PanelController.moduleToOpen(panel: panel, alerting: .cpu, declined: .memory) == .cpu)
        panel.collapsedModules = panel.collapsedModules(toggling: .memory)
        #expect(PanelController.moduleToOpen(panel: panel, alerting: .memory, declined: nil) == nil, "already open")
        panel = PanelSettings(hiddenModules: [.memory])
        #expect(PanelController.moduleToOpen(panel: panel, alerting: .memory, declined: nil) == nil)
        panel = PanelSettings(opensOnAlert: false)
        #expect(PanelController.moduleToOpen(panel: panel, alerting: .memory, declined: nil) == nil)
    }

    @Test("the new panel settings survive a round trip and default sensibly")
    func settingsRoundTrip() throws {
        let fresh = PanelSettings()
        #expect(fresh.opensOnAlert)
        #expect(!fresh.showsGauges)
        #expect(fresh.shows(.moduleCalm))
        #expect(fresh.shows(.systemUpdateEffect))
        var panel = PanelSettings(showsGauges: true, opensOnAlert: false)
        panel.hiddenElements = [.moduleCalm]
        let decoded = try JSONDecoder().decode(PanelSettings.self, from: JSONEncoder().encode(panel))
        #expect(decoded.showsGauges)
        #expect(!decoded.opensOnAlert)
        #expect(!decoded.shows(.moduleCalm))
    }
}

/// This Mac before and after a macOS update.
@Suite("Before and after an update")
struct UpdateEffectTests {

    private static let now = Date(timeIntervalSince1970: 1_767_225_600)

    @Test("a changed build is an update, dated at the first launch that sees it")
    func record() {
        let first = SystemUpdateRecord.advance(nil, version: "26.0", build: "25A1", now: Self.now)
        #expect(first == SystemUpdateRecord(version: "26.0", build: "25A1"))
        #expect(SystemUpdateRecord.advance(first, version: "26.0", build: "25A1", now: Self.now) == first)
        let later = Self.now.addingTimeInterval(86_400)
        let updated = SystemUpdateRecord.advance(first, version: "26.1", build: "25B7", now: later)
        #expect(updated.previousVersion == "26.0")
        #expect(updated.updatedAt == later)
        #expect(updated.version == "26.1")
        // A build that could not be read proves nothing either way.
        #expect(SystemUpdateRecord.advance(updated, version: "26.1", build: "", now: later).updatedAt == nil)
    }

    /// Hourly readings for `days` before and after an update `after` days ago.
    private func month(before: [SeriesKey: Double], after: [SeriesKey: Double],
                       updatedDaysAgo: Int, skipping: Int = 1) -> MinuteHistory {
        var month = MinuteHistory(capacity: MinuteHistory.monthCapacity,
                                  bucketDuration: MinuteHistory.monthBucketDuration)
        let update = Self.now.addingTimeInterval(-86_400 * Double(updatedDaysAgo))
        for hour in stride(from: (updatedDaysAgo + 8) * 24, through: 0, by: -skipping) {
            let date = Self.now.addingTimeInterval(-3_600 * Double(hour))
            month.advance(to: date)
            for (key, value) in date < update ? before : after { month.record(key, value) }
        }
        return month
    }

    @Test("a reading that moved past the noise is notable, one that did not is the same")
    func changes() throws {
        let month = month(before: [.cpuTemperature: 46, .cpuTotal: 0.12, .memoryPressure: 0.20],
                          after: [.cpuTemperature: 51, .cpuTotal: 0.14, .memoryPressure: 0.12],
                          updatedDaysAgo: 4)
        let update = Self.now.addingTimeInterval(-4 * 86_400)
        let effect = try #require(UpdateEffect.make(month: month, updatedAt: update, now: Self.now))
        #expect(abs(effect.days - 4) < 0.01)
        let byKey = Dictionary(uniqueKeysWithValues: effect.changes.map { ($0.key, $0) })
        let heat = try #require(byKey[.cpuTemperature])
        #expect(abs(heat.delta - 5) < 0.01)
        #expect(heat.isNotable)
        #expect(try #require(byKey[.cpuTotal]).isNotable == false)
        let pressure = try #require(byKey[.memoryPressure])
        #expect(pressure.isNotable)
        #expect(pressure.delta < 0)
        #expect(effect.hasNotableChange)
    }

    @Test("no update, or too little of either side, is no comparison")
    func needsBothSides() {
        let month = month(before: [.cpuTotal: 0.1], after: [.cpuTotal: 0.3], updatedDaysAgo: 4)
        #expect(UpdateEffect.make(month: month, updatedAt: nil, now: Self.now) == nil)
        // Updated twelve hours ago: half a day is not a habit.
        let fresh = Self.now.addingTimeInterval(-12 * 3_600)
        #expect(UpdateEffect.make(month: month, updatedAt: fresh, now: Self.now) == nil)
        // An update so old that the week before it has left the month.
        let old = Self.now.addingTimeInterval(-29 * 86_400)
        #expect(UpdateEffect.make(month: month, updatedAt: old, now: Self.now) == nil)
    }

    @Test("the comparison stops a week after the update")
    func window() throws {
        let month = month(before: [.cpuTotal: 0.1], after: [.cpuTotal: 0.3], updatedDaysAgo: 12)
        let update = Self.now.addingTimeInterval(-12 * 86_400)
        let effect = try #require(UpdateEffect.make(month: month, updatedAt: update, now: Self.now))
        #expect(effect.days == 7)
    }
}
