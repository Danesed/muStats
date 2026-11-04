import Testing
import Foundation
import CoreGraphics
import Darwin
@testable import MuStatsKit
@testable import MuStatsUI

@Suite("Panel readings and actions")
struct PanelImprovementTests {
    @Test("a busy core stands out only when the average hides it")
    func hotCore() {
        var cpu = SnapshotFixtures.cpu(busy: 0.18)
        cpu.perCore = [CPULoad(user: 0.96, idle: 0.04), CPULoad(user: 0.1, idle: 0.9)]
        #expect(PanelHotCore.busy(in: cpu) == 0.96)
        cpu.total = CPULoad(user: 0.8, idle: 0.2)
        #expect(PanelHotCore.busy(in: cpu) == nil)
        cpu.total = CPULoad(user: 0.18, idle: 0.82)
        cpu.perCore = [CPULoad(user: 0.7, idle: 0.3)]
        #expect(PanelHotCore.busy(in: cpu) == nil)
    }

    @Test("long network names use their own line")
    func wifiName() {
        #expect(!PanelWiFiLabel.needsOwnLine("Wi-Fi"))
        #expect(PanelWiFiLabel.needsOwnLine("A much longer network name"))
    }

    @Test("a reused PID or an unverifiable start time is never signalled")
    func processIdentity() {
        let start = Date(timeIntervalSince1970: 1000)
        let process = ProcessRow(pid: 123, name: "Example", startTime: start)
        var sent = false
        let send: (Int32, Int32) -> Int32 = { _, _ in sent = true; return 0 }
        let changed = PanelProcessAction.perform(process, signal: SIGTERM, identity: { _ in
            .init(name: "Example", start: start.addingTimeInterval(1))
        }, send: send)
        #expect(changed == .changed)
        #expect(!sent)
        let missing = ProcessRow(pid: 123, name: "Example")
        #expect(PanelProcessAction.perform(missing, signal: SIGTERM,
                                           identity: { _ in nil }, send: send) == .changed)
        #expect(!sent)
        #expect(PanelProcessAction.perform(process, signal: SIGTERM, identity: { _ in
            .init(name: "Example", start: start)
        }, send: send) == .success)
        #expect(sent)
        let failure = PanelProcessAction.perform(process, signal: SIGTERM, identity: { _ in
            .init(name: "Example", start: start)
        }, send: { _, _ in errno = EPERM; return -1 })
        #expect(failure == .failed(EPERM))
    }

    @Test("an unavailable ring is distinguishable from zero")
    func ringMark() {
        func pixels(_ fraction: Double?) -> [UInt8] {
            let width = 48, height = 48, bytesPerRow = width * 4
            let memory = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 4)
            defer { memory.deallocate() }
            memory.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerRow * height)
            let context = CGContext(data: memory, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            RingPalette.draw([fraction], center: CGPoint(x: 24, y: 24), diameter: 40,
                             onDark: true, colors: .aurora, in: context)
            return Array(UnsafeBufferPointer(start: memory.assumingMemoryBound(to: UInt8.self),
                                             count: bytesPerRow * height))
        }
        #expect(pixels(nil) != pixels(0))
    }
}
