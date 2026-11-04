import Testing
import Foundation
@testable import MuStatsKit

@MainActor
@Suite("History regressions")
struct HistoryRegressionTests {

    private func makeEngine() -> (MetricsEngine, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuStatsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (MetricsEngine(settingsStore: SettingsStore(directory: directory)), directory)
    }

    @Test("a stopped source leaves a gap while an active source keeps its cached reading")
    func stoppedSourceLeavesGap() {
        final class GPU: MetricSource {
            let identifier = CollectorID.gpu
            let preferredInterval: TimeInterval = 60
            func collect(context: SampleContext) -> MetricState<GPUSnapshot> {
                .value(SnapshotFixtures.gpu(utilization: 0.75))
            }
        }
        let (engine, _) = makeEngine()
        let slot = SourceSlot(GPU())
        let now = Monotonic.now
        slot.tick(now: now, activity: .panel, isEnabled: true,
                  baseInterval: 1, didWakeFromSleep: false)
        var snapshot = SystemSnapshot(cpu: .value(SnapshotFixtures.cpu(busy: 0.2)),
                                      gpu: slot.state,
                                      capturedAt: Date(timeIntervalSince1970: 1_200_000))
        engine.ingest(snapshot)
        slot.tick(now: now.advanced(by: .seconds(1)), activity: .panel, isEnabled: true,
                  baseInterval: 1, didWakeFromSleep: false)
        snapshot.gpu = slot.state
        snapshot.capturedAt.addTimeInterval(1)
        engine.ingest(snapshot)

        slot.tick(now: now.advanced(by: .seconds(2)), activity: .menuBar, isEnabled: false,
                  baseInterval: 1, didWakeFromSleep: false)
        snapshot.gpu = slot.state
        snapshot.capturedAt.addTimeInterval(60)
        engine.ingest(snapshot)

        #expect(engine.dayHistory.series(.gpuUtilization).counts.suffix(2).map(Int.init) == [2, 0])
        #expect(engine.dayHistory.series(.cpuTotal).counts.suffix(2).map(Int.init) == [2, 1])
        #expect(engine.history[.gpuUtilization].count == 3)
        #expect(engine.history[.gpuUtilization].last == nil)
        #expect(engine.history[.gpuUtilization].average == 0.75)
        #expect(engine.history[.cpuTotal].count == 3)
    }

    @Test("a new history is saved after its first hour")
    func firstSessionIsSaved() async {
        let (engine, directory) = makeEngine()
        var snapshot = SystemSnapshot(cpu: .value(SnapshotFixtures.cpu(busy: 0.2)),
                                      capturedAt: Date(timeIntervalSince1970: 1_200_000))
        engine.ingest(snapshot)
        snapshot.capturedAt.addTimeInterval(3_600)
        engine.ingest(snapshot)
        let file = MinuteHistoryFile(directory: directory)
        for _ in 0..<100 {
            if file.load() != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let saved = file.load()
        #expect(saved?.newestBucket == 20_060)
        #expect(saved?.series(.cpuTotal).sampledCount == 2)
    }
}
