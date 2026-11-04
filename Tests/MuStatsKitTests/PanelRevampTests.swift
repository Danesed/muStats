import Testing
import Foundation
import SwiftUI
@testable import MuStatsKit
@testable import MuStatsUI

@Suite("Panel module order")
struct PanelModuleOrderTests {

    @Test("with nothing stored the order is the declaration order")
    func defaultOrder() {
        #expect(PanelSettings().visibleModules == PanelModule.allCases)
    }

    @Test("a stored order is kept, and modules it does not name follow")
    func partialOrderAppendsTheRest() {
        let panel = PanelSettings(moduleOrder: [.battery, .cpu, .battery])
        #expect(panel.visibleModules.prefix(2) == [.battery, .cpu])
        #expect(panel.visibleModules.count == PanelModule.allCases.count)
        #expect(Set(panel.visibleModules) == Set(PanelModule.allCases))
    }

    @Test("a dragged module takes the place of the one it is dropped on")
    func dropTakesTargetsPlace() {
        let panel = PanelSettings()
        let up = panel.moduleOrder(moving: .battery, before: .cpu)
        #expect(up.first == .battery)
        #expect(up[1] == .cpu)
        let down = panel.moduleOrder(moving: .cpu, before: .gpu)
        #expect(down.prefix(3) == [.memory, .gpu, .cpu])
        #expect(panel.moduleOrder(moving: .cpu, before: .cpu) == PanelModule.allCases)
    }

    @Test("the order round trips, and files written before it decode empty")
    func codable() throws {
        let panel = PanelSettings(moduleOrder: [.system, .cpu])
        let decoded = try JSONDecoder().decode(PanelSettings.self, from: JSONEncoder().encode(panel))
        #expect(decoded.moduleOrder == [.system, .cpu])
        let old = try JSONDecoder().decode(PanelSettings.self, from: Data("{}".utf8))
        #expect(old.moduleOrder.isEmpty)
    }
}

@Suite("Panel headline units")
struct PanelUsedOfTotalTests {
    private let formatter = MetricFormatter()
    private let gib = 1_073_741_824.0

    @Test("a used figure in another unit is expressed in the total's")
    func mixedUnits() {
        #expect(PanelSummary.usedOfTotal(1006 * 1_048_576, 13 * gib, formatter: formatter) == "1.0/13 GB")
    }

    @Test("same unit reads as before")
    func sameUnit() {
        #expect(PanelSummary.usedOfTotal(10 * gib, 18 * gib, formatter: formatter) == "10/18 GB")
        #expect(PanelSummary.usedOfTotal(8.6 * gib, 18 * gib, formatter: formatter) == "8.6/18 GB")
    }
}

@Suite("Panel culprit")
struct PanelCulpritTests {

    @Test("an app's helpers are counted under the app")
    func helpersAddUp() {
        let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/"
        let processes = [
            ProcessRow(pid: 1, name: "Google Chrome Helper (Renderer)",
                       executablePath: chrome + "Renderer.app/Contents/MacOS/Renderer", memoryBytes: 600),
            ProcessRow(pid: 2, name: "Google Chrome Helper",
                       executablePath: chrome + "Helper.app/Contents/MacOS/Helper", memoryBytes: 600),
            ProcessRow(pid: 3, name: "kernel_task", memoryBytes: 1000),
        ]
        let top = PanelCulprit.top(processes) { Double($0.memoryBytes) }
        #expect(top == PanelCulprit.Entry(name: "Google Chrome", value: 1200))
    }

    @Test("nothing using the resource names nobody")
    func idleNamesNobody() {
        let processes = [ProcessRow(pid: 1, name: "idle", cpuPercent: 0)]
        #expect(PanelCulprit.top(processes, by: \.cpuPercent) == nil)
    }
}

@MainActor
@Suite("Panel insight")
struct PanelInsightTests {

    private func engine(_ snapshot: SystemSnapshot) -> MetricsEngine {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelInsightTests-\(UUID().uuidString)")
        let engine = MetricsEngine(settingsStore: SettingsStore(directory: dir))
        engine.loadFixture(snapshot: snapshot, history: MetricHistory())
        return engine
    }

    @Test("a calm machine says so and points nowhere")
    func quiet() {
        let insight = PanelInsight.make(modules: PanelModule.allCases, engine: engine(SnapshotFixtures.nominal),
                                        formatter: MetricFormatter())
        #expect(insight == .quiet)
    }

    @Test("under load the worst module speaks, memory first among equals, naming the app")
    func underLoad() {
        let insight = PanelInsight.make(modules: PanelModule.allCases,
                                        engine: engine(SnapshotFixtures.underLoad),
                                        formatter: MetricFormatter())
        #expect(insight.level == .critical)
        #expect(insight.module == .memory)
        #expect(insight.detail != nil)
    }

    @Test("a module not in the panel cannot speak")
    func onlyVisibleModules() {
        let insight = PanelInsight.make(modules: [.network, .system],
                                        engine: engine(SnapshotFixtures.underLoad),
                                        formatter: MetricFormatter())
        #expect(insight == .partial)
    }

    @Test("uncollected readings do not claim everything is normal")
    func collecting() {
        let insight = PanelInsight.make(modules: PanelModule.allCases, engine: engine(.empty),
                                        formatter: MetricFormatter())
        #expect(insight == .collecting)
    }

    @Test("a failed reading leaves a calm insight partial, but does not suppress an alert")
    func partialReadings() {
        var snapshot = SnapshotFixtures.nominal
        snapshot.gpu = .failure(.failed("unavailable"))
        #expect(PanelInsight.make(modules: PanelModule.allCases, engine: engine(snapshot),
                                  formatter: MetricFormatter()) == .partial)
        snapshot.cpu = .value(SnapshotFixtures.cpu(busy: 0.96))
        #expect(PanelInsight.make(modules: PanelModule.allCases, engine: engine(snapshot),
                                  formatter: MetricFormatter()).module == .cpu)
    }
}

@Suite("History gaps")
struct HistoryGapTests {

    private func plot(_ columns: [BandColumn?]) -> BandPlot {
        BandPlot(rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                 scale: ChartScale(upperBound: 1, isDerived: false, peak: 1), columns: columns)
    }

    @Test("only a stretch with samples on both sides is a gap")
    func interiorOnly() {
        let c = BandColumn(low: 0.1, mean: 0.2, high: 0.3)
        #expect(plot([nil, nil, c, c, nil, nil, c, nil]).interiorGaps == [4..<6])
        #expect(plot([nil, c, c, c]).interiorGaps.isEmpty)
    }
}

@Suite("Today's events")
struct PanelEventTests {

    private func series(_ means: [Float], key: SeriesKey = .cpuTotal, notes: [Int: String] = [:]) -> MinuteSeries {
        MinuteSeries(key: key, minima: means, averages: means, maxima: means,
                     counts: means.map { $0 < 0 ? 0 : 1 }, notes: notes,
                     end: Date(timeIntervalSince1970: 86_400))
    }

    private var cpu: PanelEvents.Rule { PanelEvents.rules[0] }

    @Test("a stretch above the line becomes one event, named by its most frequent process")
    func stretch() {
        let s = series([0.2, 0.85, 0.97, 0.9, 0.2, 0.2, 0.2, 0.2],
                       notes: [1: "swift-frontend", 2: "swift-frontend", 3: "Xcode"])
        let events = PanelEvents.detect(series: s, notes: s, rule: cpu)
        #expect(events.count == 1)
        #expect(events.first?.level == .critical)
        #expect(events.first?.culprit == "swift-frontend")
        #expect(abs((events.first?.peak ?? 0) - 0.97) < 0.001)
    }

    @Test("a one-minute spike is not an event, and a short dip does not split one")
    func spikesAndDips() {
        let spike = series([0.2, 0.99, 0.2, 0.2, 0.2, 0.2])
        #expect(PanelEvents.detect(series: spike, notes: spike, rule: cpu).isEmpty)
        let dip = series([0.9, 0.9, 0.3, 0.9, 0.9, 0.2, 0.2, 0.2, 0.2])
        #expect(PanelEvents.detect(series: dip, notes: dip, rule: cpu).count == 1)
    }

    @Test("minutes never sampled do not count as above the line")
    func unsampled() {
        let s = series([-1, -1, -1, -1])
        #expect(PanelEvents.detect(series: s, notes: s, rule: cpu).isEmpty)
    }

    @Test("the cache keeps events until the history revision changes")
    func cache() {
        var day = MinuteHistory(capacity: 5)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = PanelEventsCache()
        #expect(cache.events(in: day, revision: 0).isEmpty)
        day.advance(to: time)
        day.record(.cpuTotal, 0.9)
        day.advance(to: time.addingTimeInterval(60))
        day.record(.cpuTotal, 0.95)
        #expect(cache.events(in: day, revision: 0).isEmpty)
        #expect(cache.events(in: day, revision: 1).count == 1)
    }

    @Test("overlapping pins share the numbers of their event rows")
    func clusteredPins() {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ kind: PanelEvent.Kind, _ position: Double) -> PanelEvent {
            PanelEvent(kind: kind, level: .warning, start: time, end: time.addingTimeInterval(120),
                       peak: 0.9, position: position, culprit: nil)
        }
        let events = [event(.cpu, 0.2), event(.memory, 0.21), event(.heat, 0.8)]
        let groups = PanelEventPinGroup.grouped(events, plotWidth: 300)
        #expect(groups.map(\.label) == ["1,2", "3"])
        #expect(events[0].id != events[1].id)
        #expect(PanelEventPinGroup.grouped(events, plotWidth: 10).count == 1)
    }
}

@Suite("A minute of the day reads back as the panel would have shown it")
struct PanelMomentTests {
    private let formatter = MetricFormatter(settings: GeneralSettings())

    @Test("a sampled minute lists its readings and the process behind the high")
    func sampledMinute() {
        var day = MinuteHistory()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        day.advance(to: when)
        day.record(.cpuTotal, 0.5)
        day.record(.cpuTotal, 0.7)
        day.record(.memoryUsed, 0.62)
        day.record(.memoryPressure, 0.3)
        day.record(.cpuTemperature, 71)
        day.note(.cpu, name: "swift-frontend", value: 0.7)
        let moment = PanelMoment(day: day, at: when, formatter: formatter)
        #expect(moment.rows.map(\.label) == ["CPU", "Memory", "Temperature"])
        #expect(moment.rows.first?.value == formatter.percent(0.6))
        #expect(moment.rows.first?.culprit == "swift-frontend")
        // Pressure under a half says nothing, so the memory row leaves it out.
        #expect(moment.rows[1].value == formatter.percent(0.62))
    }

    @Test("a minute with no samples is empty, not zero")
    func emptyMinute() {
        var day = MinuteHistory()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        day.advance(to: when)
        day.record(.cpuTotal, 0.4)
        let earlier = when.addingTimeInterval(-600)
        #expect(PanelMoment(day: day, at: earlier, formatter: formatter).isEmpty)
        #expect(day.average(.cpuTotal, at: earlier) == nil)
        #expect(abs((day.average(.cpuTotal, at: when) ?? 0) - 0.4) < 1e-6)
    }
}

@Suite("Battery life is said in minutes")
struct BatteryForecastTests {
    @Test("a process drawing half the pack doubles what is left")
    func halfTheDraw() {
        let gain = BatteryForecast.gain(timeLeft: 3_600, draw: 10, processWatts: 5) ?? 0
        #expect(abs(gain - 3_600) < 1)
    }

    @Test("no process frees the whole draw, however much it claims")
    func neverAllOfIt() {
        let gain = BatteryForecast.gain(timeLeft: 3_600, draw: 10, processWatts: 40) ?? 0
        // Three quarters freed at most: 1 h becomes 4 h.
        #expect(abs(gain - 3 * 3_600) < 1)
    }

    @Test("on power there is no draw to forecast from")
    func onPower() {
        var power = PowerSnapshot()
        power.hasBattery = true
        power.isPluggedIn = true
        power.batteryWatts = 12
        #expect(BatteryForecast.draw(power) == nil)
        power.isPluggedIn = false
        power.batteryWatts = -12
        #expect(BatteryForecast.draw(power) == 12)
    }

    @Test("before the system has an estimate, the charge left over the draw stands in")
    func fallbackEstimate() {
        var power = PowerSnapshot()
        power.hasBattery = true
        power.isPluggedIn = false
        power.batteryWatts = -10
        power.currentCapacitymAh = 5_000
        power.voltage = 12
        // 60 Wh at 10 W is six hours.
        #expect(abs((BatteryForecast.timeLeft(power) ?? 0) - 6 * 3_600) < 1)
    }
}

@Suite("What keeps the Mac awake reads like a person would say it")
struct SleepBlockerTests {
    private func assertion(_ type: String, _ name: String, process: String, level: Int = 255) -> [String: Any] {
        ["AssertType": type, "AssertName": name, "Process Name": process, "AssertLevel": level]
    }

    @Test("one row per process, the strongest hold, the display-on hold left out")
    func parsing() {
        let found = SleepBlockers.blockers(from: [
            (pid: 360, assertions: [assertion("PreventUserIdleSystemSleep", "Powerd - Prevent sleep while display is on", process: "powerd")]),
            (pid: 92148, assertions: [
                assertion("PreventUserIdleDisplaySleep", "Amphetamine (Single-Use - Display)", process: "Amphetamine"),
                assertion("PreventUserIdleSystemSleep", "Amphetamine (Single-Use - System)", process: "Amphetamine"),
            ]),
            (pid: 839, assertions: [assertion("PreventUserIdleSystemSleep", "BTLEAdvertisement.5832B539-ACA8-4040-86A6-2E1BF7476E87", process: "useractivityd")]),
            (pid: 12, assertions: [assertion("UserIsActive", "tickle", process: "WindowServer")]),
            (pid: 13, assertions: [assertion("PreventUserIdleSystemSleep", "released", process: "Zoom", level: 0)]),
        ])
        #expect(found.map(\.processName) == ["Amphetamine", "useractivityd"])
        #expect(found.first?.hold == .system)
        #expect(found.first?.reason == "Amphetamine (Single-Use - System)")
        // An identifier says nothing to a person, so it is dropped.
        #expect(found.last?.reason == "")
    }
}

@Suite("Wi-Fi or provider")
struct NetworkDiagnosisTests {
    private func router(_ ms: Double, loss: Double = 0) -> MetricState<PingSummary> {
        .value(PingSummary(loss: loss, averageRTT: ms / 1000))
    }

    @Test("ping's summary lines parse into loss and the mean round trip")
    func parsePing() {
        let out = """
        --- 10.0.0.1 ping statistics ---
        5 packets transmitted, 5 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 1.812/3.204/5.991/1.441 ms
        """
        let summary = PingSummary.parse(out)
        #expect(summary?.loss == 0)
        #expect(abs((summary?.averageRTT ?? 0) - 0.003204) < 1e-9)
        let lost = PingSummary.parse("5 packets transmitted, 0 packets received, 100.0% packet loss")
        #expect(lost?.loss == 1)
        #expect(lost?.averageRTT == nil)
    }

    @Test("a slow router blames the local link")
    func slowRouter() {
        let verdict = NetworkDiagnosis.make(router: router(80), internetLatency: .value(0.2), internetLoss: .value(0))
        #expect(verdict == .localLink(routerRTT: 0.08, routerLoss: 0))
    }

    @Test("a quick router and a slow internet blames the provider")
    func provider() {
        let verdict = NetworkDiagnosis.make(router: router(3), internetLatency: .value(0.4), internetLoss: .value(0))
        #expect(verdict == .provider(internetRTT: 0.4, internetLoss: 0))
    }

    @Test("both quick is healthy, and a router that ignores pings says nothing")
    func healthyAndSilent() {
        #expect(NetworkDiagnosis.make(router: router(3), internetLatency: .value(0.03), internetLoss: .value(0)) == .healthy)
        #expect(NetworkDiagnosis.make(router: .value(PingSummary(loss: 1, averageRTT: nil)),
                                      internetLatency: .value(0.4), internetLoss: .value(0)) == nil)
    }
}

@Suite("Alerts worked out from the Mac")
struct SmartAlertTests {
    private let formatter = MetricFormatter(settings: GeneralSettings())

    private func row(_ pid: Int32, _ name: String, cpu: Double = 0, watts: Double? = nil,
                     apple: Bool = false) -> ProcessRow {
        var r = ProcessRow(pid: pid, name: name, cpuPercent: cpu, memoryBytes: 0)
        r.energyImpact = watts
        r.isAppleSignedSystem = apple
        return r
    }

    @Test("a core kept busy for ten minutes while away is a runaway, once")
    func runaway() {
        var watch = RunawayWatch()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var alerts: [SmartAlert] = []
        for minute in 0...11 {
            let now = start.addingTimeInterval(Double(minute) * 60)
            if let alert = watch.update(processes: [row(42, "node", cpu: 98)], ownPID: 1,
                                        idle: 3_600, ignored: [], now: now) {
                alerts.append(alert)
            }
        }
        #expect(alerts.count == 1)
        #expect(alerts.first?.pid == 42)
        #expect(alerts.first?.category == .runaway)
    }

    @Test("not while someone is at the Mac, not for Apple's own, not when ignored")
    func runawayExclusions() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func run(_ rows: [ProcessRow], idle: TimeInterval, ignored: Set<String> = []) -> Int {
            var watch = RunawayWatch()
            var count = 0
            for minute in 0...15 {
                let now = start.addingTimeInterval(Double(minute) * 60)
                if watch.update(processes: rows, ownPID: 1, idle: idle, ignored: ignored, now: now) != nil { count += 1 }
            }
            return count
        }
        #expect(run([row(42, "node", cpu: 98)], idle: 5) == 0)
        #expect(run([row(43, "mds_stores", cpu: 98, apple: true)], idle: 3_600) == 0)
        #expect(run([row(44, "node", cpu: 98)], idle: 3_600, ignored: ["node"]) == 0)
    }

    @Test("a minute without it ends the streak")
    func runawayGap() {
        var watch = RunawayWatch()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var fired = false
        for minute in 0...12 where minute != 6 {
            let now = start.addingTimeInterval(Double(minute) * 60 + (minute > 6 ? 120 : 0))
            if watch.update(processes: [row(42, "node", cpu: 98)], ownPID: 1, idle: 3_600, ignored: [], now: now) != nil {
                fired = true
            }
        }
        #expect(!fired)
    }

    @Test("unusual needs a week of this hour and a clear margin")
    func unusual() {
        let usual = UnusualWatch.Usual(median: 0.12, spread: 0.03)
        #expect(UnusualWatch.isUnusual(current: 0.64, usual: usual, floor: 0.35, margin: 0.25))
        #expect(!UnusualWatch.isUnusual(current: 0.30, usual: usual, floor: 0.35, margin: 0.25))
        // A Mac that is often busy at this hour does not alert on being busy.
        let noisy = UnusualWatch.Usual(median: 0.4, spread: 0.2)
        #expect(!UnusualWatch.isUnusual(current: 0.8, usual: noisy, floor: 0.35, margin: 0.25))
    }

    @Test("the usual is the median of this hour on earlier days")
    func usualFromMonth() {
        var month = MinuteHistory(capacity: MinuteHistory.monthCapacity,
                                  bucketDuration: MinuteHistory.monthBucketDuration)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for day in stride(from: 10, through: 1, by: -1) {
            month.advance(to: now.addingTimeInterval(-86_400 * Double(day)))
            month.record(.cpuTotal, day == 3 ? 0.9 : 0.1)
        }
        month.advance(to: now)
        let usual = UnusualWatch.usual(.cpuTotal, month: month, now: now)
        #expect(abs((usual?.median ?? 0) - 0.1) < 1e-6)
        #expect(UnusualWatch.usual(.cpuTemperature, month: month, now: now) == nil)
    }

    @Test("unplugging asks for a read, then names a heavy app with what quitting it buys")
    func unplug() {
        var watch = UnplugWatch()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var power = PowerSnapshot()
        power.hasBattery = true
        power.isPluggedIn = true
        _ = watch.update(power: power, processes: nil, ownPID: 1, formatter: formatter, now: start)
        power.isPluggedIn = false
        power.batteryWatts = -12
        power.timeToEmpty = 2 * 3_600
        let first = watch.update(power: power, processes: nil, ownPID: 1, formatter: formatter,
                                 now: start.addingTimeInterval(2))
        #expect(first.requestsWitness)
        #expect(first.alert == nil)
        let second = watch.update(power: power, processes: [row(7, "com.docker.backend", watts: 6)],
                                  ownPID: 1, formatter: formatter, now: start.addingTimeInterval(6))
        #expect(second.alert?.pid == 7)
        #expect(second.alert?.body.contains("Quitting it would add about") == true)
        // Settled: no second word about the same unplugging.
        let third = watch.update(power: power, processes: [row(7, "com.docker.backend", watts: 6)],
                                 ownPID: 1, formatter: formatter, now: start.addingTimeInterval(10))
        #expect(third.alert == nil)
    }
}

@Suite("Where the space went")
struct StorageScanTests {
    private func sample(_ hoursAgo: Double, _ gb: Double, now: Date) -> StorageFolder.Sample {
        StorageFolder.Sample(date: now.addingTimeInterval(-hoursAgo * 3_600), bytes: UInt64(gb * 1e9))
    }

    @Test("the change is measured against the reading closest to a day before")
    func changeSinceYesterday() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = StorageFolder(id: "d", label: "DerivedData", path: "/tmp", isCleanable: true,
                                   samples: [sample(72, 10, now: now), sample(25, 20, now: now),
                                             sample(13, 30, now: now), sample(0, 38, now: now)])
        #expect(folder.change?.bytes == 18_000_000_000)
    }

    @Test("readings fold to one per half day and a week at most")
    func fold() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var samples = [sample(200, 1, now: now), sample(30, 2, now: now), sample(3, 3, now: now)]
        samples = StorageScan.fold(samples, sample(0, 4, now: now))
        // The week-old one is gone, the one from three hours ago replaced.
        #expect(samples.map(\.bytes) == [2_000_000_000, 4_000_000_000])
    }

    @Test("listening ports read without failing, and stay out of the dynamic range")
    func ports() {
        let ports = ListeningPorts.current()
        #expect(ports.allSatisfy { $0.port < ListeningPorts.dynamicRange })
    }
}

@Suite("The menu bar rings")
struct RingsMenuBarTests {
    @Test("rings with no other readouts read only their own sources, and are one item")
    func rings() {
        var settings = Settings()
        settings.menuBar.showsRings = true
        settings.menuBar.ringMetrics = [.cpuUsage, .battery]
        settings.menuBar.items = settings.menuBar.items.map { var item = $0; item.isEnabled = false; return item }
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal, history: MetricHistory(),
                                       settings: settings, isStale: false)
        #expect(model.items.isEmpty)
        #expect(model.rings?.rings.map(\.metric) == [.cpuUsage, .battery])
        #expect(model.rings?.rings.allSatisfy { $0.fraction != nil } == true)
        let sources = settings.requiredSources(panelVisible: false)
        #expect(sources.isSuperset(of: [.cpu, .power]))
        #expect(!sources.contains(.network))
        #expect(MenuBarItemLayout(settings: settings.menuBar) == .combined)
    }

    @Test("readouts sit beside the rings, less the readings a ring already shows")
    func mixed() {
        var settings = Settings()
        settings.menuBar.showsRings = true
        settings.menuBar.ringMetrics = [.cpuUsage, .memoryUsage, .diskUsage]
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage),
                                  MenuBarItemConfig(metric: .cpuTemperature),
                                  MenuBarItemConfig(metric: .networkThroughput)]
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal, history: MetricHistory(),
                                       settings: settings, isStale: false)
        #expect(model.rings?.rings.count == 3)
        #expect(model.items.map(\.id) == settings.menuBar.items.dropFirst().map(\.id))
        let sources = settings.requiredSources(panelVisible: false)
        #expect(sources.isSuperset(of: [.cpu, .memory, .disk, .network]))
        #expect(MenuBarItemLayout(settings: settings.menuBar) == .combined)
    }

    @Test("a ring's own colour replaces the set's, darker on a light bar, and is stored")
    func customColour() throws {
        let own = ThemeColor(red: 1, green: 0.5, blue: 0)
        let custom: [ThemeColor?] = [nil, own, nil]
        let set = RingColors.ocean
        #expect(set.tone(ring: 0, custom: custom, onDark: true) == set.tones[0].dark)
        #expect(set.tone(ring: 1, custom: custom, onDark: true) == (1, 0.5, 0))
        let light = set.tone(ring: 1, custom: custom, onDark: false)
        #expect(light.0 < 1 && light.1 < 0.5)

        var settings = MenuBarSettings()
        #expect(settings.customRingColors.count == MenuBarSettings.maximumRings)
        settings.customRingColors = MenuBarSettings.sanitizedRingColors(custom)
        let decoded = try JSONDecoder().decode(MenuBarSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.customRingColors == custom)
        let old = try JSONDecoder().decode(MenuBarSettings.self, from: Data(#"{"ringColors":"neon"}"#.utf8))
        #expect(old.customRingColors == [nil, nil, nil])
    }

    @Test("fractions stay in range and move in forty-eighths")
    func fractions() {
        var settings = Settings()
        settings.menuBar.showsRings = true
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.underLoad, history: MetricHistory(),
                                       settings: settings, isStale: false)
        for ring in model.rings?.rings ?? [] {
            let f = ring.fraction ?? -1
            #expect(f >= 0 && f <= 1)
            #expect((f * 48).rounded() == f * 48)
        }
    }

    @Test("the rings start in Aurora, not Fitness, and every set has three tones")
    func colours() throws {
        #expect(MenuBarSettings().ringColors == .aurora)
        let decoded = try JSONDecoder().decode(MenuBarSettings.self, from: Data(#"{"ringColors":"neon"}"#.utf8))
        #expect(decoded.ringColors == .neon)
        let unknown = try JSONDecoder().decode(MenuBarSettings.self, from: Data(#"{"ringColors":"plaid"}"#.utf8))
        #expect(unknown.ringColors == .aurora)
        #expect(RingColors.allCases.count == 6)
        #expect(RingColors.allCases.allSatisfy { $0.tones.count == 3 })
    }

    @Test("a stored list is kept to one to three distinct readings a ring can draw")
    func sanitised() {
        #expect(MenuBarSettings.sanitizedRings([]) == MenuBarSettings.defaultRingMetrics)
        #expect(MenuBarSettings.sanitizedRings([.cpuUsage, .cpuUsage, .uptime]) == [.cpuUsage])
        #expect(MenuBarSettings.sanitizedRings([.cpuUsage, .memoryUsage, .diskUsage, .battery]).count == 3)
    }
}


@Suite("The menu bar holds changes nobody could see")
struct MenuBarStabilizerTests {
    @Test("a rate within a fifth in the same unit is held; a unit change is not")
    func rates() {
        func line(_ s: String) -> MenuBarLine { MenuBarLine(valueText: s, widestText: "999 KB/s") }
        #expect(MenuBarStabilizer.isSmallChange(line("340 KB/s"), line("352 KB/s")))
        #expect(!MenuBarStabilizer.isSmallChange(line("340 KB/s"), line("520 KB/s")))
        #expect(!MenuBarStabilizer.isSmallChange(line("980 KB/s"), line("1.0 MB/s")))
        #expect(MenuBarStabilizer.isSmallChange(line("3 KB/s"), line("9 KB/s")))
        // Not a rate: a percentage has its own rules and is never held here.
        #expect(!MenuBarStabilizer.isSmallChange(line("34%"), line("35%")))
    }

    @Test("a bar moves only by a visible step")
    func levels() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage, style: .bar)]
        var stabilizer = MenuBarStabilizer()
        var first = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal, history: MetricHistory(),
                                       settings: settings, isStale: false)
        first.items[0].level = 0.30
        stabilizer.apply(&first)
        var small = first
        small.items[0].level = 0.32
        stabilizer.apply(&small)
        #expect(small.items[0].level == 0.30)
        var big = first
        big.items[0].level = 0.40
        stabilizer.apply(&big)
        #expect(big.items[0].level == 0.40)
    }
}

@Suite("The live chip fits any chip")
struct LiveChipFitTests {
    @Test("four cores draw large, an Ultra's many still fit")
    func fit() {
        let block = CGSize(width: 140, height: 130)
        let small = PanelLiveChip.fit(count: 4, in: block, gap: 4, maxCell: 28)
        #expect(small.cell == 28)
        let ultra = PanelLiveChip.fit(count: 24, in: block, gap: 4, maxCell: 28)
        let rows = (24 + ultra.columns - 1) / ultra.columns
        #expect(ultra.cell > 0)
        #expect(CGFloat(ultra.columns) * ultra.cell + CGFloat(ultra.columns - 1) * 4 <= block.width)
        #expect(CGFloat(rows) * ultra.cell + CGFloat(rows - 1) * 4 <= block.height)
        let gpu = PanelLiveChip.fit(count: 80, in: CGSize(width: 140, height: 90), gap: 3, maxCell: 14)
        #expect(gpu.cell >= 5)
    }
}

@Suite("Storage scan stays out of protected folders")
struct StorageScanPrivacyTests {
    @Test("Apple's own app folders are not entered")
    func skipsAppleFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        let apple = root.appendingPathComponent("com.apple.Music")
        let other = root.appendingPathComponent("com.example.tool")
        try FileManager.default.createDirectory(at: apple, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(count: 64_000).write(to: apple.appendingPathComponent("blob"))
        try Data(count: 64_000).write(to: other.appendingPathComponent("blob"))
        defer { try? FileManager.default.removeItem(at: root) }
        let all = try #require(StorageScan.measure(other, isCancelled: { false }))
        let both = try #require(StorageScan.measure(root, isCancelled: { false }))
        #expect(all > 0)
        #expect(both == all, "the com.apple folder was counted")
    }
}
