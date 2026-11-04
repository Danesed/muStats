import Testing
import AppKit
@testable import MuStatsUI

@MainActor
@Suite("Panel window rendering", .serialized)
struct PanelWindowRenderingTests {
    @Test("panel clips hosted content to rounded corners after resizing")
    func roundedCornersAfterResize() async throws {
        _ = NSApplication.shared
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.white.cgColor
        let window = PanelWindow(contentView: content)
        defer { window.close() }

        let backdrop = try #require(window.contentView)
        window.setFrame(NSRect(x: -50_000, y: -50_000, width: 100, height: 120), display: false)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(50))
        for height in [120, 180] {
            window.setFrame(NSRect(x: -50_000, y: -50_000, width: 100, height: height), display: false)
            backdrop.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            let layer = try #require(backdrop.layer)
            let width = Int(layer.bounds.width)
            let height = Int(layer.bounds.height)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                     bitsPerComponent: 8, bytesPerRow: width * 4,
                                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
                layer.render(in: context)
                func alpha(_ x: Int, _ y: Int) -> UInt8 { buffer[(y * width + x) * 4 + 3] }
                #expect(alpha(0, 0) == 0)
                #expect(alpha(width - 1, 0) == 0)
                #expect(alpha(0, height - 1) == 0)
                #expect(alpha(width - 1, height - 1) == 0)
                #expect(alpha(width / 2, height / 2) == 255)
            }
        }
        #expect(!window.hasShadow)
    }
}
