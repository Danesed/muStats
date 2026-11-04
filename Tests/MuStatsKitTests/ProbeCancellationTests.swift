import Foundation
import Testing
@testable import MuStatsKit

@Suite("Network probe cancellation")
struct ProbeCancellationTests {
    final class Recorder<Value: Sendable & Equatable>: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: (@Sendable (MetricState<Value>) -> Void)?
        private var cancellations = 0

        func start(_ completion: @escaping @Sendable (MetricState<Value>) -> Void) -> @Sendable () -> Void {
            lock.lock()
            self.completion = completion
            lock.unlock()
            return { [self] in
                lock.lock()
                cancellations += 1
                lock.unlock()
            }
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return cancellations
        }

        func answer(_ result: MetricState<Value>) {
            lock.lock()
            let callback = completion
            lock.unlock()
            callback?(result)
        }
    }

    @Test("closing network details cancels latency and loss requests")
    func closingCancelsRequests() {
        let latency = Recorder<TimeInterval>()
        let loss = Recorder<Double>()
        let latencyProbe = LatencyProbe { latency.start($0) }
        let lossProbe = PacketLossProbe { loss.start($0) }
        latencyProbe.setEnabled(true)
        lossProbe.setEnabled(true)
        latencyProbe.refreshIfDue()
        lossProbe.refreshIfDue()
        latencyProbe.setEnabled(false)
        lossProbe.setEnabled(false)
        #expect(latency.count == 1)
        #expect(loss.count == 1)
        latency.answer(.value(0.1))
        loss.answer(.value(0.1))
        #expect(latencyProbe.currentState().value == nil)
        #expect(lossProbe.currentState().value == nil)
    }

    @Test("changing the router and closing details cancel the old ping")
    func routerCancellation() {
        let recorder = Recorder<PingSummary>()
        let probe = RouterProbe { _, completion in recorder.start(completion) }
        probe.setTarget("192.0.2.1")
        probe.setEnabled(true)
        probe.refreshIfDue()
        probe.setTarget("192.0.2.2")
        #expect(recorder.count == 1)
        probe.refreshIfDue()
        probe.setEnabled(false)
        #expect(recorder.count == 2)
        recorder.answer(.value(PingSummary(loss: 0, averageRTT: 0.01)))
        #expect(probe.currentState().value == nil)
    }

    @Test("closing while a request starts still cancels it")
    func cancellationDuringStart() {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        let probe = LatencyProbe { _ in
            entered.signal()
            _ = proceed.wait(timeout: .now() + 2)
            return { cancelled.signal() }
        }
        probe.setEnabled(true)
        DispatchQueue.global().async { probe.refreshIfDue() }
        let started = entered.wait(timeout: .now() + 2)
        #expect(started == .success)
        probe.setEnabled(false)
        proceed.signal()
        #expect(cancelled.wait(timeout: .now() + 2) == .success)
    }

    @Test("a manual retest bypasses the normal throttle")
    func manualRetest() {
        final class Requests: @unchecked Sendable { var count = 0 }
        let requests = Requests()
        let loss = PacketLossProbe { completion in
            requests.count += 1
            completion(.value(0))
            return nil
        }
        loss.setEnabled(true)
        loss.refreshIfDue()
        loss.refreshIfDue()
        #expect(requests.count == 1)
        loss.triggerProbe()
        #expect(requests.count == 2)
    }

    @Test("HTTP sessions are deferred until the first request")
    func sessionsAreLazy() {
        let latency = LatencyProbe()
        let address = PublicIPFetcher()
        #expect(!latency.hasTransport && !address.hasTransport)
        latency.refreshIfDue()
        address.refreshIfDue()
        #expect(!latency.hasTransport && !address.hasTransport)
        latency.setEnabled(true)
        address.setEnabled(true)
        #expect(!latency.hasTransport && !address.hasTransport)
    }
}
