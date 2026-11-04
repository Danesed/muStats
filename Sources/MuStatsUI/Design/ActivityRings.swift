import AppKit
import SwiftUI
import MuStatsKit

/// The rings' drawing and their colours, from the chosen `RingColors`.
public enum RingPalette {
    public static func cgColor(ring index: Int, onDark: Bool, colors: RingColors,
                               custom: [ThemeColor?] = []) -> CGColor {
        let (r, g, b) = colors.tone(ring: index, custom: custom, onDark: onDark)
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    public static func color(ring index: Int, onDark: Bool, colors: RingColors,
                             custom: [ThemeColor?] = []) -> Color {
        Color(cgColor: cgColor(ring: index, onDark: onDark, colors: colors, custom: custom))
    }

    /// How strongly the unfilled part of a ring shows: the track, in the ring's hue.
    public static let trackAlpha: CGFloat = 0.28

    /// Line width and gap for `count` rings in a circle of `diameter`. Fewer rings
    /// are drawn thicker, so a single ring is not a hairline in a big empty circle.
    public static func geometry(count: Int, diameter: CGFloat) -> (line: CGFloat, gap: CGFloat) {
        // At 20pt, three rings are 2pt strokes a point apart, which leaves the inner
        // one a real ring rather than a dot.
        let share: CGFloat = count >= 3 ? 0.10 : count == 2 ? 0.13 : 0.15
        return (diameter * share, diameter * 0.05)
    }

    /// Draws `fractions` (outermost first) as rings centred on `center`, in a Core
    /// Graphics context with y pointing up. A nil fraction marks an unavailable ring.
    public static func draw(_ fractions: [Double?], center: CGPoint, diameter: CGFloat,
                            onDark: Bool, colors: RingColors, custom: [ThemeColor?] = [],
                            in context: CGContext) {
        let (line, gap) = geometry(count: fractions.count, diameter: diameter)
        var radius = diameter / 2 - line / 2
        context.saveGState()
        context.setLineWidth(line)
        context.setLineCap(.round)
        for (index, fraction) in fractions.enumerated() {
            guard radius > line / 2 else { break }
            let color = cgColor(ring: index, onDark: onDark, colors: colors, custom: custom)
            context.setStrokeColor(color.copy(alpha: trackAlpha) ?? color)
            context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            context.strokePath()
            if let fraction, fraction > 0 {
                // From twelve o'clock, clockwise, as the Activity rings run.
                let start = CGFloat.pi / 2
                let end = start - .pi * 2 * CGFloat(min(fraction, 1))
                context.setStrokeColor(color)
                context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
                context.strokePath()
            } else if fraction == nil {
                let half = max(line * 0.55, 1.5)
                let top = CGPoint(x: center.x, y: center.y + radius)
                context.setStrokeColor(color)
                context.setLineWidth(max(1, line * 0.3))
                context.move(to: CGPoint(x: top.x - half, y: top.y - half))
                context.addLine(to: CGPoint(x: top.x + half, y: top.y + half))
                context.move(to: CGPoint(x: top.x - half, y: top.y + half))
                context.addLine(to: CGPoint(x: top.x + half, y: top.y - half))
                context.strokePath()
                context.setLineWidth(line)
            }
            radius -= line + gap
        }
        context.restoreGState()
    }
}
