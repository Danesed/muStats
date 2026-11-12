import Testing
import Foundation
@testable import MuStatsKit
@testable import MuStatsUI

/// What the hot paths are allowed to cost.
///
/// μStats is only worth running if it costs next to nothing, and that is lost one
/// harmless-looking change at a time: nobody notices 200 µs added to a function that
/// runs every second. Each budget here is about ten times what the path measured in
/// a debug build when it was written, so a test fails for a change of kind, a loop
/// that became quadratic or a read that moved into a per-row call, and not for a
/// busy machine. Set `MUSTATS_COST_REPORT` to a file path to have the measurements
/// written out.
@MainActor
@Suite("Cost budget", .serialized)
struct CostBudgetTests {

    private static let now = SnapshotFixtures.referenceDate

    /// The median of `runs` timings of `body`, in microseconds. The median, so one
    /// run that lost its core to something else does not decide the result.
    private func microseconds(runs: Int = 15, _ body: () -> Void) -> Double {
        body()
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000)
        }
        return samples.sorted()[runs / 2]
    }

    private func check(_ name: String, budget: Double, _ measured: Double,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        if let path = ProcessInfo.processInfo.environment["MUSTATS_COST_REPORT"] {
            let line = String(format: "%-44@ %9.1f us   budget %8.0f us\n", name as NSString, measured, budget)
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        #expect(measured <= budget, "\(name) took \(Int(measured)) µs, over its \(Int(budget)) µs budget",
                sourceLocation: sourceLocation)
    }

    @Test("what a closed panel row asks of the month stays a handful of reads")
    func usualRange() {
        let month = SnapshotFixtures.monthHistory()
        var sink = 0.0
        let cost = microseconds {
            for _ in 0..<100 { sink += Usual.range(.cpuTotal, month: month, at: Self.now)?.median ?? 0 }
        } / 100
        #expect(sink >= 0)
        check("Usual.range", budget: 150, cost)
    }

    @Test("the usual band of a day chart is drawn from hourly reads, not from series")
    func usualBand() {
        let month = SnapshotFixtures.monthHistory()
        var sink = 0
        let cost = microseconds {
            sink += UsualBand.ranges(columns: 300, key: .cpuTotal, month: month) {
                Self.now.addingTimeInterval(-86_400 * (1 - $0))
            }.count
        }
        #expect(sink > 0)
        check("UsualBand.ranges, 300 columns", budget: 4_000, cost)
    }

    @Test("an hour of the day is built from sixty buckets, not from the whole day")
    func trailingSeries() {
        let day = SnapshotFixtures.dayHistory()
        var sink = 0
        let cost = microseconds { sink += day.series(.cpuTotal, trailing: 60).count }
        #expect(sink > 0)
        check("MinuteHistory.series(trailing: 60)", budget: 300, cost)
    }

    @Test("the forecasts read the month once")
    func forecasts() {
        let month = SnapshotFixtures.monthHistory()
        var sink = 0.0
        check("DiskForecast.make", budget: 1_000,
              microseconds { sink += DiskForecast.make(month: month, now: Self.now)?.daysUntilFull ?? 0 })
        let update = Self.now.addingTimeInterval(-5 * 86_400)
        check("UpdateEffect.make", budget: 2_500,
              microseconds { sink += UpdateEffect.make(month: month, updatedAt: update, now: Self.now)?.days ?? 0 })
        #expect(sink >= 0)
    }

    @Test("the day's events are found in one walk, once per opening")
    func events() {
        let day = SnapshotFixtures.dayHistory()
        var sink = 0
        let cost = microseconds { sink += PanelEvents.detect(in: day).count }
        #expect(sink >= 0)
        check("PanelEvents.detect", budget: 30_000, cost)
    }

    @Test("a steady network sample re-reads no addresses and no routes")
    func networkSample() throws {
        let collector = NetworkCollector()
        collector.start()
        defer { collector.stop() }
        _ = collector.collect(context: SampleContext(elapsed: 0, isFirstSample: true, activity: .menuBar))
        let context = SampleContext(elapsed: 1, isFirstSample: false, activity: .menuBar)
        let cost = microseconds(runs: 41) { _ = collector.collect(context: context) }
        check("NetworkCollector.collect, steady", budget: 1_500, cost)
    }

    @Test("a process sample bills every app within a few milliseconds")
    func processSample() throws {
        let collector = ProcessCollector()
        collector.start()
        defer { collector.stop() }
        _ = collector.collect(context: SampleContext(elapsed: 0, isFirstSample: true, activity: .panel))
        let context = SampleContext(elapsed: 1, isFirstSample: false, activity: .panel)
        let cost = microseconds(runs: 9) { _ = collector.collect(context: context) }
        check("ProcessCollector.collect", budget: 30_000, cost)
    }
}
