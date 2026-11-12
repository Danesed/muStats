import SwiftUI
import MuStatsKit

/// What a module's gauge draws: the reading on its full scale, and where it usually
/// sits at this hour, both as fractions of the track.
struct PanelGaugeReading: Equatable {
    var value: Double
    var usual: ClosedRange<Double>?

    /// The part of the reading past the top of the usual range, when the reading is
    /// far enough past it to be called unusual.
    ///
    /// A quarter of all hours sit above the top of the middle half by definition, and
    /// colouring every one of them would teach the reader to ignore the colour. The
    /// fence is the box plot's: one and a half times the range's own width above its
    /// top, and never less than a tenth of the scale, so a Mac regular to the point
    /// of having no width is not unusual every time it moves.
    var excess: ClosedRange<Double>? {
        guard let usual, value > Self.fence(above: usual) else { return nil }
        return usual.upperBound...value
    }

    static func fence(above usual: ClosedRange<Double>) -> Double {
        usual.upperBound + max(0.1, 1.5 * (usual.upperBound - usual.lowerBound))
    }

    /// The gauge for `module`, or nil for a module whose reading has no ceiling to
    /// draw it against: a rate, a count, an uptime.
    @MainActor
    static func make(for module: PanelModule, engine: MetricsEngine, showsUsual: Bool) -> PanelGaugeReading? {
        let now = engine.history.lastSampleDate ?? Date()
        func reading(_ value: Double, key: SeriesKey?, scale: ClosedRange<Double> = 0...1) -> PanelGaugeReading {
            func place(_ raw: Double) -> Double {
                min(max((raw - scale.lowerBound) / (scale.upperBound - scale.lowerBound), 0), 1)
            }
            let usual = showsUsual
                ? key.flatMap { Usual.range($0, month: engine.monthHistory, at: now) } : nil
            return PanelGaugeReading(value: place(value),
                                     usual: usual.map { place($0.low)...place($0.high) })
        }
        switch module {
        case .cpu:
            return engine.cpu.value.map { reading($0.total.busy, key: .cpuTotal) }
        case .memory:
            return engine.memory.value.map { reading($0.usedFraction, key: .memoryUsed) }
        case .gpu:
            return engine.gpu.value?.primary?.utilization.map { reading($0, key: .gpuUtilization) }
        case .disk:
            // Fullness has a trend, not a habit, so the disk has a bar and no range.
            return engine.disk.value?.rootVolume.map { reading($0.usedFraction, key: nil) }
        case .battery:
            guard let power = engine.power.value, power.hasBattery,
                  let percentage = power.percentage else { return nil }
            return reading(percentage, key: nil, scale: 0...100)
        case .thermal:
            // The band the temperature chart states, so the two agree on what is hot.
            let scale = PanelModule.thermal.historySeries?.domain ?? 30...100
            return engine.thermal.value?.cpuCelsius.map { reading($0, key: .cpuTemperature, scale: scale) }
        case .network, .processes, .system:
            return nil
        }
    }
}

/// The rule under a module row, drawn as the reading.
///
/// A row used to end in a hairline that separated it from the next and said nothing.
/// This is the same line carrying the number: a bar as long as the reading on a track
/// as long as its scale, over a wider band that marks where this Mac usually sits at
/// this hour. Length along a shared baseline is the comparison the eye makes most
/// accurately, so six rows read as six bars on one axis, and the band puts each one in
/// context: a bar that stops inside its band is an ordinary hour, a bar that runs past
/// it shows by how much, in the colour the status line uses for "more than usual".
struct PanelGauge: View {
    let reading: PanelGaugeReading
    /// What the stretch past the usual range is drawn in: the row's alert colour when
    /// it has one, otherwise the colour the status line uses for "more than usual".
    var excessTint: Color = PanelGauge.unusualTint

    /// Tall enough for the band to read as a band, short enough to stay a rule. Even,
    /// like the bar, so both land on whole pixels on a 1x display.
    static let height: CGFloat = 6
    static let barHeight: CGFloat = 2
    static let unusualTint = Color.blue

    var body: some View {
        let tint = Design.Palette.primaryText
        ZStack {
            GaugeSegment(range: 0...1, thickness: Self.barHeight)
                .fill(tint.opacity(0.09))
            if let usual = reading.usual {
                // Squarer than the bar and wider than a knob: a range, not a handle.
                GaugeSegment(range: usual, thickness: Self.height, minimum: 6, cornerRadius: 1.5)
                    .fill(tint.opacity(0.2))
            }
            // Fades in from the left so the eye is drawn to where the bar ends, which
            // is the reading; where it starts is the same for every row.
            GaugeSegment(range: 0...reading.value, thickness: Self.barHeight)
                .fill(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0.95)],
                                     startPoint: .leading, endPoint: .trailing))
            if let excess = reading.excess {
                GaugeSegment(range: excess, thickness: Self.barHeight)
                    .fill(excessTint)
            }
        }
        .frame(height: Self.height)
        .animation(Design.Motion.respectingAccessibility(Design.Motion.value), value: reading)
        .accessibilityHidden(true)
    }
}

/// A stretch of a gauge's scale. A shape with animatable ends, so a bar glides to a
/// new reading instead of jumping to it.
struct GaugeSegment: Shape {
    var lower: Double
    var upper: Double
    var thickness: CGFloat
    var minimum: CGFloat = 0
    var cornerRadius: CGFloat?

    init(range: ClosedRange<Double>, thickness: CGFloat, minimum: CGFloat = 0, cornerRadius: CGFloat? = nil) {
        self.lower = range.lowerBound
        self.upper = range.upperBound
        self.thickness = thickness
        self.minimum = minimum
        self.cornerRadius = cornerRadius
    }

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(lower, upper) }
        set { lower = newValue.first; upper = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: Self.rect(lower: lower, upper: upper, thickness: thickness,
                                    in: rect, minimum: minimum),
             cornerRadius: cornerRadius ?? thickness / 2)
    }

    /// Where a stretch of the scale lands on the track. One narrower than `minimum`
    /// is widened around its middle and kept inside the track.
    static func rect(lower: Double, upper: Double, thickness: CGFloat, in rect: CGRect,
                     minimum: CGFloat = 0) -> CGRect {
        var left = rect.width * CGFloat(min(max(lower, 0), 1))
        var right = rect.width * CGFloat(min(max(upper, 0), 1))
        if right - left < minimum {
            let centre = min(max((left + right) / 2, minimum / 2), rect.width - minimum / 2)
            left = centre - minimum / 2
            right = centre + minimum / 2
        }
        return CGRect(x: rect.minX + left, y: rect.midY - thickness / 2,
                      width: max(right - left, 0), height: thickness)
    }
}
