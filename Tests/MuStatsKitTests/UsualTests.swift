import Testing
import Foundation
import SwiftUI
@testable import MuStatsKit
@testable import MuStatsUI

/// "This Mac's normal": the usual range, the disk forecast, and where they are shown.
@MainActor
@Suite("This Mac's usual")
struct UsualTests {

    private static let now = Date(timeIntervalSince1970: 1_767_225_600)

    /// A month tier with one reading per listed day at the hour of `now`.
    private func month(_ key: SeriesKey, daysAgo values: [Int: Double]) -> MinuteHistory {
        var month = MinuteHistory(capacity: MinuteHistory.monthCapacity,
                                  bucketDuration: MinuteHistory.monthBucketDuration)
        for day in values.keys.sorted(by: >) {
            month.advance(to: Self.now.addingTimeInterval(-86_400 * Double(day)))
            month.record(key, values[day]!)
        }
        month.advance(to: Self.now)
        return month
    }

    @Test("fewer than a week of days at this hour is not a habit")
    func needsAWeek() {
        let short = month(.cpuTotal, daysAgo: Dictionary(uniqueKeysWithValues: (1...6).map { ($0, 0.2) }))
        #expect(Usual.range(.cpuTotal, month: short, at: Self.now) == nil)
        let enough = month(.cpuTotal, daysAgo: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 0.2) }))
        #expect(Usual.range(.cpuTotal, month: enough, at: Self.now)?.days == 7)
    }

    @Test("the range is the middle half of the earlier days, today left out")
    func quartiles() throws {
        // 0.10, 0.20 ... 0.90 on nine earlier days, and a wild reading today.
        var values = Dictionary(uniqueKeysWithValues: (1...9).map { ($0, Double($0) / 10) })
        values[0] = 0.99
        let range = try #require(Usual.range(.cpuTotal, month: month(.cpuTotal, daysAgo: values), at: Self.now))
        #expect(abs(range.low - 0.3) < 1e-6)
        #expect(abs(range.median - 0.5) < 1e-6)
        #expect(abs(range.high - 0.7) < 1e-6)
        #expect(range.contains(0.5) && !range.contains(0.99))
    }

    @Test("another hour of the day has its own range")
    func perHour() {
        let month = month(.cpuTotal, daysAgo: Dictionary(uniqueKeysWithValues: (1...9).map { ($0, 0.2) }))
        #expect(Usual.range(.cpuTotal, month: month, at: Self.now.addingTimeInterval(3 * 3_600)) == nil)
    }

    @Test("rates and charge have no usual range drawn")
    func drawnKeys() {
        #expect(Usual.isDrawn(for: .cpuTotal) && Usual.isDrawn(for: .cpuTemperature))
        #expect(!Usual.isDrawn(for: .networkDownload) && !Usual.isDrawn(for: .batteryPercent))
    }

    // MARK: Disk forecast

    /// Hourly "disk used" readings over `days`, on a straight line.
    private func disk(days: Int, from start: Double, perDay: Double) -> MinuteHistory {
        var month = MinuteHistory(capacity: MinuteHistory.monthCapacity,
                                  bucketDuration: MinuteHistory.monthBucketDuration)
        for hour in stride(from: days * 24, through: 0, by: -1) {
            month.advance(to: Self.now.addingTimeInterval(-3_600 * Double(hour)))
            month.record(.diskUsed, start + perDay * (Double(days) - Double(hour) / 24))
        }
        return month
    }

    @Test("a disk filling one percent a day from 80% is full in twenty days")
    func fills() throws {
        let forecast = try #require(DiskForecast.make(month: disk(days: 10, from: 0.70, perDay: 0.01), now: Self.now))
        #expect(abs(forecast.growthPerDay - 0.01) < 1e-4)
        #expect(abs(forecast.daysUntilFull - 20) < 0.5)
    }

    @Test("a steady disk, an emptying one and a far horizon have no forecast")
    func noForecast() {
        #expect(DiskForecast.make(month: disk(days: 10, from: 0.70, perDay: 0), now: Self.now) == nil)
        #expect(DiskForecast.make(month: disk(days: 10, from: 0.70, perDay: -0.01), now: Self.now) == nil)
        #expect(DiskForecast.make(month: disk(days: 10, from: 0.10, perDay: 0.002), now: Self.now) == nil)
    }

    @Test("two days of readings are a download, not a trend")
    func needsDays() {
        #expect(DiskForecast.make(month: disk(days: 2, from: 0.70, perDay: 0.05), now: Self.now) == nil)
    }

    // MARK: Where it is shown

    @Test("the row's band needs a fixed scale and sits between the quartiles")
    func sparklineBand() throws {
        var ring = SampleRing(capacity: 60)
        for i in 0..<60 { ring.append(0.3 + 0.1 * sin(Double(i))) }
        let usual = UsualRange(low: 0.2, median: 0.3, high: 0.6, days: 9)
        let size = CGSize(width: 44, height: 14)
        let drawn = PanelSparkline.paths(ring, key: .cpuTotal, domain: nil, usual: usual, in: size)
        let band = try #require(drawn.band).boundingRect
        // 12 points of plot for 0...1, one point of inset: 60% and 20% from the top.
        #expect(abs(band.minY - (1 + 12 * 0.4)) < 0.01)
        #expect(abs(band.maxY - (1 + 12 * 0.8)) < 0.01)
        #expect(band.width == 44)
        // A rate's scale follows its peak, so a band on it would move with the data.
        #expect(PanelSparkline.paths(ring, key: .networkDownload, domain: nil, usual: usual, in: size).band == nil)
        #expect(PanelSparkline.paths(ring, key: .cpuTotal, domain: nil, in: size).band == nil)
    }

    @Test("a narrow habit is still drawn as a band")
    func thinBand() throws {
        var ring = SampleRing(capacity: 60)
        for _ in 0..<60 { ring.append(0.3) }
        ring.append(0.31)
        let usual = UsualRange(low: 0.30, median: 0.30, high: 0.31, days: 9)
        let band = try #require(PanelSparkline.paths(ring, key: .cpuTotal, domain: nil, usual: usual,
                                                     in: CGSize(width: 44, height: 14)).band)
        #expect(abs(band.boundingRect.height - PanelSparkline.minimumBand) < 0.01)
    }

    @Test("the chart's band covers the hours that have a habit and skips the others")
    func chartBand() {
        // A habit at the hour of `now` only: the columns near it get a range, the
        // ones half a day earlier do not.
        let month = month(.cpuTotal, daysAgo: Dictionary(uniqueKeysWithValues: (1...9).map { ($0, 0.2) }))
        let ranges = UsualBand.ranges(columns: 25, key: .cpuTotal, month: month) { fraction in
            Self.now.addingTimeInterval(-86_400 * (1 - fraction))
        }
        #expect(ranges.last??.median == 0.2 || abs((ranges.last??.median ?? 0) - 0.2) < 1e-6)
        #expect(ranges[12] == nil)
    }

    @Test("the status line sets an alert against the habit, and stays quiet without one")
    func statusLine() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsualTests-\(UUID().uuidString)")
        let engine = MetricsEngine(settingsStore: SettingsStore(directory: dir))
        engine.loadFixture(snapshot: SnapshotFixtures.underLoad, history: SnapshotFixtures.history(),
                           monthHistory: SnapshotFixtures.monthHistory())
        let insight = PanelInsight.make(modules: PanelModule.allCases, engine: engine, formatter: MetricFormatter())
        #expect(insight.module == .memory)
        #expect(insight.comparison != nil)
        #expect(insight.isNotable)

        let bare = MetricsEngine(settingsStore: SettingsStore(directory: dir))
        bare.loadFixture(snapshot: SnapshotFixtures.underLoad, history: MetricHistory())
        #expect(PanelInsight.make(modules: PanelModule.allCases, engine: bare,
                                  formatter: MetricFormatter()).comparison == nil)
    }

    @Test("a notice shows the status line that is set to speak only when notable")
    func noticeIsNotable() {
        #expect(!PanelRootView.showsStatusLine(.whenNotable, level: .none))
        #expect(PanelRootView.showsStatusLine(.whenNotable, level: .none, isNotice: true))
        #expect(!PanelRootView.showsStatusLine(.never, level: .none, isNotice: true))
    }

    // MARK: The windowed series

    @Test("the trailing series equals the whole series cut down")
    func trailingSeries() {
        let day = SnapshotFixtures.dayHistory()
        for key in [SeriesKey.cpuTotal, .memoryUsed, .networkDownload] {
            for buckets in [1, 60, 500, 1_440, 5_000] {
                #expect(day.series(key, trailing: buckets) == day.series(key).trailing(buckets))
            }
        }
        let empty = MinuteHistory()
        #expect(empty.series(.cpuTotal, trailing: 60).count == 60)
    }
}

/// The gauge under a module row: the reading against its scale and its habit.
@MainActor
@Suite("Row gauges")
struct PanelGaugeTests {

    private func engine(_ snapshot: SystemSnapshot, month: Bool = true) -> MetricsEngine {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelGaugeTests-\(UUID().uuidString)")
        let engine = MetricsEngine(settingsStore: SettingsStore(directory: dir))
        if month {
            engine.loadFixture(snapshot: snapshot, history: SnapshotFixtures.history(),
                               monthHistory: SnapshotFixtures.monthHistory())
        } else {
            engine.loadFixture(snapshot: snapshot, history: SnapshotFixtures.history())
        }
        return engine
    }

    @Test("a module with a ceiling has a gauge, a rate or a count has none")
    func whichModules() {
        let engine = engine(SnapshotFixtures.nominal)
        for module in [PanelModule.cpu, .memory, .gpu, .disk, .battery, .thermal] {
            #expect(PanelGaugeReading.make(for: module, engine: engine, showsUsual: true) != nil)
        }
        for module in [PanelModule.network, .processes, .system] {
            #expect(PanelGaugeReading.make(for: module, engine: engine, showsUsual: true) == nil)
        }
    }

    @Test("the reading is a fraction of the scale the module states")
    func scales() throws {
        let engine = engine(SnapshotFixtures.nominal)
        let cpu = try #require(PanelGaugeReading.make(for: .cpu, engine: engine, showsUsual: true))
        #expect(abs(cpu.value - (engine.cpu.value?.total.busy ?? -1)) < 1e-9)
        #expect(cpu.usual != nil)
        // Temperature on the chart's 30 to 100 band.
        let thermal = try #require(PanelGaugeReading.make(for: .thermal, engine: engine, showsUsual: true))
        let celsius = try #require(engine.thermal.value?.cpuCelsius)
        #expect(abs(thermal.value - (celsius - 30) / 70) < 1e-9)
        // Fullness and charge have no habit.
        #expect(PanelGaugeReading.make(for: .disk, engine: engine, showsUsual: true)?.usual == nil)
        #expect(PanelGaugeReading.make(for: .battery, engine: engine, showsUsual: true)?.usual == nil)
    }

    @Test("without a month of history, or with the range switched off, the bar stands alone")
    func noUsual() {
        #expect(PanelGaugeReading.make(for: .cpu, engine: engine(SnapshotFixtures.nominal, month: false),
                                       showsUsual: true)?.usual == nil)
        #expect(PanelGaugeReading.make(for: .cpu, engine: engine(SnapshotFixtures.nominal),
                                       showsUsual: false)?.usual == nil)
    }

    @Test("only a reading well past the range is marked: the box plot's fence, a tenth of the scale at least")
    func fence() {
        let usual = 0.20...0.30
        #expect(abs(PanelGaugeReading.fence(above: usual) - 0.45) < 1e-9)
        #expect(PanelGaugeReading(value: 0.40, usual: usual).excess == nil)
        #expect(PanelGaugeReading(value: 0.60, usual: usual).excess == 0.30...0.60)
        // A habit with no width still needs a tenth of the scale.
        #expect(PanelGaugeReading(value: 0.29, usual: 0.2...0.2).excess == nil)
        #expect(PanelGaugeReading(value: 0.31, usual: 0.2...0.2).excess != nil)
        #expect(PanelGaugeReading(value: 0.9, usual: nil).excess == nil)
    }

    @Test("gauges are opt-in, and an open module draws none and keeps its hairline")
    func visibility() {
        let engine = engine(SnapshotFixtures.nominal)
        var panel = PanelSettings()
        // Off until asked for: the row already states the number.
        #expect(PanelModuleView.gauge(for: .cpu, engine: engine, panel: panel, isExpanded: false) == nil)
        panel.showsGauges = true
        #expect(PanelModuleView.gauge(for: .cpu, engine: engine, panel: panel, isExpanded: false) != nil)
        #expect(PanelModuleView.gauge(for: .cpu, engine: engine, panel: panel, isExpanded: true) == nil)
    }

    @Test("a narrow range is widened to a readable mark and stays on the track")
    func segment() {
        let track = CGRect(x: 0, y: 0, width: 300, height: 5)
        let plain = GaugeSegment.rect(lower: 0.2, upper: 0.5, thickness: 2, in: track)
        #expect(plain == CGRect(x: 60, y: 1.5, width: 90, height: 2))
        let narrow = GaugeSegment.rect(lower: 0.5, upper: 0.5, thickness: 5, in: track, minimum: 6)
        #expect(narrow == CGRect(x: 147, y: 0, width: 6, height: 5))
        let edge = GaugeSegment.rect(lower: 1, upper: 1, thickness: 5, in: track, minimum: 6)
        #expect(edge.maxX == 300 && edge.width == 6)
    }
}
