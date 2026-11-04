import Testing
@testable import MuStatsKit

@Suite("SampleRing")
struct SampleRingTests {

    @Test("wraps and preserves oldest-to-newest order")
    func wrapping() {
        var ring = SampleRing(capacity: 3)
        for value in [1, 2, 3, 4, 5] { ring.append(Float(value)) }
        #expect(ring.count == 3)
        #expect(ring.values == [3, 4, 5])
        #expect(ring.last == 5)
    }

    @Test("non-finite samples never enter the buffer")
    func rejectsNonFinite() {
        var ring = SampleRing(capacity: 2)
        ring.append(Float.nan)
        ring.append(Float.infinity)
        #expect(ring.values == [0, 0])
    }

    @Test("gaps preserve positions without entering aggregates or the current value")
    func gaps() {
        var ring = SampleRing(capacity: 4)
        ring.append(Float(2))
        ring.appendGap()
        ring.append(Float(8))
        ring.appendGap()
        #expect(ring.values == [2, .infinity, 8, .infinity])
        #expect(ring.hasGaps)
        #expect(ring.sampledCount == 2)
        #expect(ring.minimum == 2)
        #expect(ring.maximum == 8)
        #expect(ring.average == 5)
        #expect(ring.last == nil)
        let resized = ring.resized(to: 3)
        #expect(resized.values == [.infinity, 8, .infinity])
        #expect(resized.average == 8)
        for value in [1, 3, 5, 7] { ring.append(Float(value)) }
        #expect(!ring.hasGaps)
        #expect(ring.average == 4)
        #expect(ring.last == 7)
    }

    @Test("a completed sample leaves a gap only in established series not recorded in that sample")
    func sampleAlignment() {
        var history = MetricHistory(capacity: 5)
        history.beginSample()
        history.record(.cpuTotal, 0.2)
        history.endSample()
        #expect(history[.gpuUtilization].count == 0)
        history.beginSample()
        history.record(.networkUpload, 10)
        history.endSample()
        history.beginSample()
        history.record(.cpuTotal, 0.4)
        history.endSample()
        #expect(history[.cpuTotal].values == [Float(0.2), .infinity, Float(0.4)])
        #expect(history[.networkUpload].values == [10, .infinity])
    }
}
