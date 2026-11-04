import Foundation
import Testing
@testable import MuStatsKit

@Suite("Sampling on demand", .serialized)
struct PerformanceDemandTests {
    @MainActor
    private final class SnapshotCounter {
        var count = 0
    }

    private func context(_ first: Bool = false) -> SampleContext {
        SampleContext(elapsed: first ? 0 : 0.15, isFirstSample: first, activity: .panel)
    }

    @Test("CPU counts are absent until requested")
    func cpuCountsFollowDemand() throws {
        let cpu = CPUCollector()
        cpu.setCountRequests(processes: false, threads: false)
        cpu.start()
        defer { cpu.stop() }
        _ = cpu.collect(context: context(true))
        Thread.sleep(forTimeInterval: 0.15)
        let basic = try #require(cpu.collect(context: context()).value)
        #expect(basic.processCount == nil)
        #expect(basic.threadCount == nil)

        cpu.setCountRequests(processes: true, threads: false)
        Thread.sleep(forTimeInterval: 0.15)
        let counts = try #require(cpu.collect(context: context()).value)
        #expect((counts.processCount ?? 0) > 0)
        #expect(counts.threadCount == nil)

        cpu.setCountRequests(processes: false, threads: true)
        Thread.sleep(forTimeInterval: 0.15)
        let threads = try #require(cpu.collect(context: context()).value)
        #expect(threads.processCount == nil)
        #expect((threads.threadCount ?? 0) > 0)
    }

    @Test("Wi-Fi identity does not trigger the detailed read")
    func wifiDetailsFollowDemand() {
        var identities = 0
        var detailedReads = 0
        let identity = {
            identities += 1
            return "Example network" as String?
        }
        let details = {
            detailedReads += 1
            return WiFiInfo(ssid: "Example network", rssi: -50) as WiFiInfo?
        }
        let basic = NetworkCollector.readWiFi(detailsEnabled: false, identity: identity, details: details)
        #expect(basic?.ssid == "Example network")
        #expect(basic?.rssi == nil)
        #expect(identities == 1)
        #expect(detailedReads == 0)

        let full = NetworkCollector.readWiFi(detailsEnabled: true, identity: identity, details: details)
        #expect(full?.rssi == -50)
        #expect(identities == 1)
        #expect(detailedReads == 1)
    }

    @Test("capacity remains available while disk I/O is disabled or baselining")
    func diskCapacityDoesNotRequireIO() throws {
        let disk = DiskCollector()
        disk.setIOEnabled(false)
        disk.start()
        defer { disk.stop() }
        let capacity = try #require(disk.collect(context: context(true)).value)
        #expect(capacity.rootVolume != nil)
        #expect(!capacity.ioAvailable)

        disk.setIOEnabled(true)
        let baseline = try #require(disk.collect(context: context()).value)
        #expect(baseline.rootVolume != nil)
        #expect(!baseline.ioAvailable)
        Thread.sleep(forTimeInterval: 0.15)
        let measured = try #require(disk.collect(context: context()).value)
        #expect(measured.ioAvailable)
        disk.setIOEnabled(false)
        let stopped = try #require(disk.collect(context: context()).value)
        #expect(!stopped.ioAvailable)
        #expect(stopped.rootVolume != nil)
    }

    @Test("the panel requests a process list only for a visible detail")
    func processesFollowDetail() {
        #expect(!SamplingCore.panelWantsProcesses(activity: .panel, details: []))
        #expect(SamplingCore.panelWantsProcesses(activity: .panel, details: [.cpu, .processes]))
        #expect(!SamplingCore.panelWantsProcesses(activity: .menuBar, details: [.processes]))
    }

    @Test("a disabled process source cannot consume a pending witness")
    func witnessWaitsForEnabledSource() {
        var pending = true
        let decide = {
            let requested = pending
            pending = false
            return requested
        }
        #expect(!SamplingCore.enabledWitness([.cpu, .memory], wants: decide))
        #expect(pending)
        #expect(SamplingCore.enabledWitness([.cpu, .memory, .processes], wants: decide))
        #expect(!pending)
    }

    @Test("configuration changes do not publish while sampling is suspended")
    @MainActor
    func suspensionDoesNotPublish() async throws {
        let counter = SnapshotCounter()
        let core = SamplingCore { _ in counter.count += 1 }
        core.setActivity(.suspended)
        core.start()
        core.setEnabledSources([.system])
        core.apply(.init(baseInterval: 2, enabledSources: [.power], publicIPLookupEnabled: false))
        core.setEnabledSources([.system])
        core.setPanelDetails([.disk], processCount: false)
        core.setPanelDetails([], processCount: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == 0)

        core.setActivity(.menuBar)
        for _ in 0..<30 where counter.count == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(counter.count > 0)
        core.stop()
    }

    private final class FakeSource: MetricSource {
        let identifier: CollectorID
        let preferredInterval: TimeInterval
        init(_ id: CollectorID, _ interval: TimeInterval) {
            identifier = id
            preferredInterval = interval
        }
        func collect(context: SampleContext) -> MetricState<Int> { .value(1) }
    }

    @Test("next timer follows the earliest enabled source's cadence")
    func nextDeadlineFollowsSources() throws {
        let power = SourceSlot(FakeSource(.power, 5))
        let system = SourceSlot(FakeSource(.system, 30))
        let cpu = SourceSlot(FakeSource(.cpu, 1))
        let now = Monotonic.now
        for slot in [power, system, cpu] {
            slot.tick(now: now, activity: .menuBar, isEnabled: true,
                      baseInterval: 2, didWakeFromSleep: false)
        }
        let later = now.advanced(by: .seconds(1))
        let powerDelay = try #require(power.nextDelay(now: later, activity: .menuBar,
                                                     baseInterval: 2, multiplier: 6))
        let systemDelay = try #require(system.nextDelay(now: later, activity: .menuBar,
                                                       baseInterval: 2, multiplier: 1))
        let cpuDelay = try #require(cpu.nextDelay(now: later, activity: .menuBar,
                                                 baseInterval: 2, multiplier: 1))
        #expect(abs(min(powerDelay, systemDelay) - 29) < 0.001)
        #expect(abs(cpuDelay - 1) < 0.001)
        power.invalidateBaseline()
        #expect(power.nextDelay(now: later, activity: .menuBar, baseInterval: 2, multiplier: 6) == 0)
    }
}
