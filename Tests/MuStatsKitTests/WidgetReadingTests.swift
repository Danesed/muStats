import Testing
import Foundation
@testable import MuStatsKit
@testable import MuStatsUI
@testable import MuStatsWidgets

@Suite("Widget readings")
struct WidgetReadingTests {
    @Test("single-metric widgets avoid unrelated readings and the CPU sampling delay")
    func onlyRequestedReadings() async {
        let start = ContinuousClock.now
        let memory = await WidgetReading.take(metrics: .memory, window: .seconds(15))
        #expect(start.duration(to: .now) < .seconds(5))
        #expect(memory.memory != nil)
        #expect(memory.cpu == nil && memory.disk == nil && memory.battery == nil)

        let disk = await WidgetReading.take(metrics: .disk, window: .seconds(15))
        #expect(disk.disk != nil)
        #expect(disk.cpu == nil && disk.memory == nil && disk.battery == nil)

        let battery = await WidgetReading.take(metrics: .battery, window: .seconds(15))
        #expect(battery.cpu == nil && battery.memory == nil && battery.disk == nil)

        let cpu = await WidgetReading.take(metrics: .cpu, window: .zero)
        #expect(cpu.memory == nil && cpu.disk == nil && cpu.battery == nil)
        let rings = await WidgetReading.take(metrics: .rings, window: .zero)
        #expect(rings.battery == nil)
    }

    @Test("widget memory uses the panel's units and decimals")
    func memoryMatchesPanel() {
        let formatter = MetricFormatter()
        let mib: UInt64 = 1_048_576
        let gib: UInt64 = 1_073_741_824
        let cases: [(UInt64, UInt64)] = [
            (123 * mib, 512 * mib),
            (mib, 512 * mib),
            (1006 * mib, 13 * gib),
            (8 * gib + 614 * mib, 18 * gib),
            (10 * gib + gib / 2, 18 * gib),
            (512 * gib, 1024 * gib),
            (1536 * gib, 2048 * gib),
        ]
        for (used, total) in cases {
            let value = WidgetFormat.memory(used: used, total: total)
            #expect("\(value.number) \(value.unit)" ==
                    PanelSummary.usedOfTotal(Double(used), Double(total), formatter: formatter))
        }

        #expect(WidgetFormat.memory(used: 123 * mib, total: 512 * mib).unit == "MB")
        #expect(WidgetFormat.memory(used: 10 * gib, total: 18 * gib).unit == "GB")
        #expect(WidgetFormat.memory(used: 512 * gib, total: 1024 * gib).unit == "TB")
        #expect(WidgetFormat.gigabytes(19_327_352_832) == "19")
    }
}
