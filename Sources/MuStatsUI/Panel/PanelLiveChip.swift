import SwiftUI
import MuStatsKit

/// The live chip: this Mac's processor drawn as the package it is, lit by its load.
///
/// An extra, off by default. Nothing here samples: it draws the snapshot the panel
/// already holds, and only while its tab is the one on screen.
///
/// The picture is the one Apple shows of these chips: a die on a package with the
/// memory modules beside it, because on Apple silicon the memory sits on the package.
/// Every part that lights is a reading. Each core is its own cell and glows with its
/// own busy fraction; the GPU reports one utilisation, so its cores glow together;
/// the memory cells fill with what is in use, in the three kinds the memory module
/// lists; and the die warms with the processor's temperature. The fine structure
/// inside a core is drawing, and nothing that is only drawing lights up.
///
/// Two layers. The silicon is one canvas that is drawn again only when the chip's
/// shape changes, which is never for one Mac. The lights are plain shapes over it
/// whose opacity follows the readings, so a new sample is a handful of fades for the
/// compositor and not a redraw.
struct PanelLiveChip: View {
    let engine: MetricsEngine

    @Environment(\.metricFormatter) private var formatter

    static let height: CGFloat = 268

    /// One hue per kind of block, the way the chip is shown on a keynote slide.
    enum Tint {
        static let performance = Color(red: 0.33, green: 0.74, blue: 1.00)
        static let efficiency = Color(red: 0.36, green: 0.93, blue: 0.78)
        static let gpu = Color(red: 0.72, green: 0.54, blue: 1.00)
        /// The same hues nearer to white, for the top of a light: a lit cell is
        /// brightest where the light falls on it.
        static let performanceLit = Color(red: 0.72, green: 0.90, blue: 1.00)
        static let efficiencyLit = Color(red: 0.74, green: 0.99, blue: 0.92)
        static let gpuLit = Color(red: 0.89, green: 0.80, blue: 1.00)
        static let app = Color(red: 0.42, green: 0.74, blue: 1.00)
        static let wired = Color(red: 0.25, green: 0.47, blue: 0.95)
        static let compressed = Color(red: 0.60, green: 0.48, blue: 0.98)
        static let heat = Color(red: 1.00, green: 0.52, blue: 0.20)
        static let pad = Color(red: 0.86, green: 0.74, blue: 0.48)
    }

    var body: some View {
        let cpu = engine.cpu.value
        let gpu = engine.gpu.value?.primary
        let memory = engine.memory.value
        let cores = Self.cores(cpu)
        VStack(alignment: .leading, spacing: Design.Space.s) {
            GeometryReader { proxy in
                let plan = ChipFloorplan.make(
                    size: CGSize(width: proxy.size.width, height: Self.height),
                    performance: cores.performance.count, efficiency: cores.efficiency.count,
                    gpu: Self.gpuCoreCount(gpu))
                ZStack(alignment: .topLeading) {
                    ChipSilicon(plan: plan).equatable()
                    lights(plan, cores: cores, gpu: gpu, memory: memory)
                    // The same structure again, dark, over the lights: a lit core
                    // still shows its cache and its logic, as lines against the glow.
                    ChipEtching(plan: plan).equatable()
                    labels(plan, cores: cores, gpu: gpu, memory: memory)
                }
                .frame(width: plan.size.width, height: plan.size.height, alignment: .topLeading)
            }
            .frame(height: Self.height)
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary(cpu: cpu, gpu: gpu, memory: memory))
            legend
        }
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.s)
    }

    // MARK: Lights

    @ViewBuilder
    private func lights(_ plan: ChipFloorplan, cores: (performance: [Double], efficiency: [Double]),
                        gpu: GPUDevice?, memory: MemorySnapshot?) -> some View {
        // The die's own warmth, under the cores so they shine through it.
        if let celsius = engine.thermal.value?.cpuCelsius {
            RadialGradient(colors: [Tint.heat.opacity(Self.warmth(celsius)), .clear],
                           center: .center, startRadius: 0, endRadius: plan.die.width * 0.62)
                .clipShape(RoundedRectangle(cornerRadius: ChipSilicon.dieRadius, style: .continuous))
                .placed(in: plan.die)
                .blendMode(.screen)
                .animation(Design.Motion.respectingAccessibility(.easeOut(duration: 1.2)), value: celsius)
                .allowsHitTesting(false)
        }
        ForEach(Array(zip(plan.performance.cells, cores.performance).enumerated()), id: \.offset) { _, pair in
            ChipCoreLight(tint: Tint.performance, lit: Tint.performanceLit, load: pair.1).placed(in: pair.0)
        }
        if let efficiency = plan.efficiency {
            ForEach(Array(zip(efficiency.cells, cores.efficiency).enumerated()), id: \.offset) { _, pair in
                ChipCoreLight(tint: Tint.efficiency, lit: Tint.efficiencyLit, load: pair.1).placed(in: pair.0)
            }
        }
        // One utilisation for the whole GPU, so one light in the shape of its cores.
        let gpuLoad = gpu?.utilization ?? 0
        ChipCells(cells: plan.gpu.cells, range: 0...Double(plan.gpu.cells.count), radius: 1.5)
            .fill(LinearGradient(colors: [Tint.gpuLit, Tint.gpu], startPoint: .top, endPoint: .bottom))
            .opacity(Self.brightness(gpuLoad))
            .shadow(color: Tint.gpu.opacity(0.7 * gpuLoad), radius: 5)
            .blendMode(.screen)
            .animation(Design.Motion.respectingAccessibility(.easeOut(duration: 0.6)), value: gpuLoad)
        if let memory {
            let fill = Self.memoryFill(memory, cells: plan.memoryCells.count)
            ChipCells(cells: plan.memoryCells, range: 0...fill.app, radius: 1)
                .fill(Tint.app)
            ChipCells(cells: plan.memoryCells, range: fill.app...fill.wired, radius: 1)
                .fill(Tint.wired)
            ChipCells(cells: plan.memoryCells, range: fill.wired...fill.compressed, radius: 1)
                .fill(Tint.compressed)
            // Pressure is the reading that says the memory is short, and it takes the
            // colour the rest of the panel gives it, on the modules' edge.
            if let color = Self.pressureColor(memory) {
                ForEach(Array(plan.modules.enumerated()), id: \.offset) { _, module in
                    RoundedRectangle(cornerRadius: ChipSilicon.moduleRadius, style: .continuous)
                        .strokeBorder(color, lineWidth: 1)
                        .shadow(color: color.opacity(0.8), radius: 4)
                        .placed(in: module.frame)
                }
            }
        }
    }

    // MARK: Labels

    @ViewBuilder
    private func labels(_ plan: ChipFloorplan, cores: (performance: [Double], efficiency: [Double]),
                        gpu: GPUDevice?, memory: MemorySnapshot?) -> some View {
        label("P-cores", Self.mean(cores.performance).map { formatter.percent($0) }, tint: Tint.performance)
            .placed(in: plan.performance.label, alignment: .leading)
        if let efficiency = plan.efficiency {
            label("E-cores", Self.mean(cores.efficiency).map { formatter.percent($0) }, tint: Tint.efficiency)
                .placed(in: efficiency.label, alignment: .leading)
        }
        label("GPU", gpu?.utilization.map { formatter.percent($0) }, tint: Tint.gpu)
            .placed(in: plan.gpu.label, alignment: .leading)
        if plan.modules.count == 2 {
            label("RAM", memory.map { formatter.percent($0.usedFraction) }, tint: Tint.app)
                .placed(in: plan.modules[0].label, alignment: .leading)
            engraved(memory.map { formatter.memory($0.totalBytes) } ?? "")
                .placed(in: plan.modules[1].label, alignment: .leading)
        }
        // The nameplate: what the chip is, and how hot it runs.
        HStack(spacing: 4) {
            engraved((engine.system.value?.chipName ?? "").uppercased())
            Spacer(minLength: 4)
            if let celsius = engine.thermal.value?.cpuCelsius {
                Text(formatter.temperature(celsius))
                    .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Tint.heat.opacity(0.55 + 0.45 * min(Self.warmth(celsius) * 4, 1)))
            }
        }
        .padding(.horizontal, 6)
        .placed(in: plan.nameplate, alignment: .leading)
    }

    private func label(_ title: String, _ value: String?, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(String(localized: String.LocalizationValue(title)).uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(tint.opacity(0.9))
            if let value {
                Text(value)
                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .contentTransition(.numericText())
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// Lettering as it is on a part: small capitals, widely spaced, the colour of
    /// the marking and not of the light.
    private func engraved(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .kerning(0.9)
            .foregroundStyle(.white.opacity(0.42))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var legend: some View {
        HStack(spacing: Design.Space.s) {
            swatch(Tint.app, "App")
            swatch(Tint.wired, "Wired")
            swatch(Tint.compressed, "Compressed")
            Spacer(minLength: Design.Space.s)
            Text("brighter is busier")
        }
        .font(Design.Text.caption)
        .foregroundStyle(Design.Palette.tertiaryText)
        .lineLimit(1)
    }

    private func swatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: Design.Space.xs) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(localizing: title)
        }
    }

    // MARK: Data

    /// How much of a light shows for a load. Never fully dark, so an idle core is
    /// still a core, and never flat white, so the silicon under it stays visible.
    static func brightness(_ load: Double) -> Double {
        0.04 + 0.84 * min(max(load, 0), 1)
    }

    /// The die's glow for a temperature: nothing below 55 °C, full at 100 °C.
    static func warmth(_ celsius: Double) -> Double {
        0.26 * min(max((celsius - 55) / 45, 0), 1)
    }

    /// Where each kind of memory ends, counted in cells from the first: app, then
    /// wired after it, then compressed. Together they are the memory in use.
    static func memoryFill(_ memory: MemorySnapshot, cells: Int) -> (app: Double, wired: Double, compressed: Double) {
        guard memory.totalBytes > 0 else { return (0, 0, 0) }
        let total = Double(memory.totalBytes)
        let count = Double(cells)
        let app = min(Double(memory.appBytes) / total, 1) * count
        let wired = min(app + Double(memory.wiredBytes) / total * count, count)
        let compressed = min(wired + Double(memory.compressedBytes) / total * count, count)
        return (app, wired, compressed)
    }

    static func pressureColor(_ memory: MemorySnapshot) -> Color? {
        if memory.memoryPressure == .critical || memory.pressureFraction >= 0.85 { return .red }
        if memory.memoryPressure == .warning || memory.pressureFraction >= 0.70 { return .orange }
        return nil
    }

    /// Every core the GPU reports, up to an Ultra's eighty; ten where it reports none.
    static func gpuCoreCount(_ gpu: GPUDevice?) -> Int {
        min(max(gpu?.coreCount ?? 10, 1), 80)
    }

    static func mean(_ loads: [Double]) -> Double? {
        loads.isEmpty ? nil : loads.reduce(0, +) / Double(loads.count)
    }

    /// Per-core busy fractions split by kind. A Mac that does not report kinds puts
    /// every core in the performance cluster.
    static func cores(_ cpu: CPUSnapshot?) -> (performance: [Double], efficiency: [Double]) {
        guard let cpu else { return ([], []) }
        var performance: [Double] = []
        var efficiency: [Double] = []
        for (index, core) in cpu.perCore.enumerated() {
            let kind = index < cpu.coreKinds.count ? cpu.coreKinds[index] : .unknown
            if kind == .efficiency { efficiency.append(core.busy) } else { performance.append(core.busy) }
        }
        return (performance, efficiency)
    }

    private func accessibilitySummary(cpu: CPUSnapshot?, gpu: GPUDevice?, memory: MemorySnapshot?) -> String {
        var parts: [String] = []
        if let cpu { parts.append("CPU \(formatter.percent(cpu.total.busy))") }
        if let utilization = gpu?.utilization { parts.append("GPU \(formatter.percent(utilization))") }
        if let memory { parts.append("memory \(formatter.percent(memory.usedFraction))") }
        return "Live chip: " + parts.joined(separator: ", ")
    }
}

// MARK: - Lights

/// One core's light: a fade the compositor runs, with a bloom that grows with it.
private struct ChipCoreLight: View {
    let tint: Color
    let lit: Color
    let load: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(LinearGradient(colors: [lit, tint, tint], startPoint: .top, endPoint: .bottom))
            .opacity(PanelLiveChip.brightness(load))
            .shadow(color: tint.opacity(0.8 * load), radius: 5)
            // Screened over the silicon: light adds to what is under it.
            .blendMode(.screen)
            .animation(Design.Motion.respectingAccessibility(.easeOut(duration: 0.6)), value: load)
            .allowsHitTesting(false)
    }
}

/// A run of cells as one shape: cell `n` is lit when `n` falls inside `range`, and
/// the cell a bound lands in is lit for that fraction of its width.
struct ChipCells: Shape {
    var cells: [CGRect]
    var lower: Double
    var upper: Double
    var radius: CGFloat

    init(cells: [CGRect], range: ClosedRange<Double>, radius: CGFloat) {
        self.cells = cells
        self.lower = range.lowerBound
        self.upper = range.upperBound
        self.radius = radius
    }

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(lower, upper) }
        set { lower = newValue.first; upper = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, cell) in cells.enumerated() {
            let from = min(max(lower - Double(index), 0), 1)
            let to = min(max(upper - Double(index), 0), 1)
            guard to > from else { continue }
            let lit = CGRect(x: cell.minX + cell.width * CGFloat(from), y: cell.minY,
                             width: cell.width * CGFloat(to - from), height: cell.height)
            path.addRoundedRect(in: lit, cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}

private extension View {
    /// Sized and moved to `rect` in the chip's own coordinates.
    func placed(in rect: CGRect, alignment: Alignment = .center) -> some View {
        frame(width: rect.width, height: rect.height, alignment: alignment)
            .offset(x: rect.minX, y: rect.minY)
    }
}

// MARK: - Silicon

/// Everything on the chip that does not change: the package, the die with its pads
/// and blocks, the structure inside each core, the memory modules and the traces
/// that join them. Equatable on the floorplan, so it is drawn once and kept.
struct ChipSilicon: View, Equatable {
    let plan: ChipFloorplan

    static let dieRadius: CGFloat = 8
    static let moduleRadius: CGFloat = 5

    private typealias Tint = PanelLiveChip.Tint

    var body: some View {
        Canvas { context, _ in
            Self.package(plan, &context)
            Self.traces(plan, &context)
            Self.die(plan, &context)
            Self.block(plan.performance, tint: Tint.performance, detailed: true, &context)
            if let efficiency = plan.efficiency {
                Self.block(efficiency, tint: Tint.efficiency, detailed: true, &context)
            }
            Self.block(plan.gpu, tint: Tint.gpu, detailed: false, &context)
            Self.nameplate(plan, &context)
            for module in plan.modules { Self.module(module, &context) }
        }
        .accessibilityHidden(true)
    }

    private static func gradient(_ colors: [Color], in rect: CGRect, diagonal: Bool = true) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: rect.minX, y: rect.minY),
                        endPoint: CGPoint(x: diagonal ? rect.maxX : rect.minX, y: rect.maxY))
    }

    /// The substrate the die and the memory are mounted on.
    private static func package(_ plan: ChipFloorplan, _ context: inout GraphicsContext) {
        let rect = CGRect(origin: .zero, size: plan.size)
        let path = Path(roundedRect: rect, cornerRadius: 13, style: .continuous)
        context.fill(path, with: gradient([Color(red: 0.115, green: 0.125, blue: 0.14),
                                           Color(red: 0.055, green: 0.06, blue: 0.07)], in: rect))
        // The weave of the board, barely there.
        var weave = context
        weave.clip(to: path)
        var lines = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            lines.move(to: CGPoint(x: x, y: rect.maxY))
            lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 7
        }
        weave.stroke(lines, with: .color(.white.opacity(0.018)), lineWidth: 0.5)
        context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 12.5, style: .continuous),
                       with: gradient([.white.opacity(0.30), .white.opacity(0.05)], in: rect), lineWidth: 1)
    }

    /// The buses between the die and each memory module.
    private static func traces(_ plan: ChipFloorplan, _ context: inout GraphicsContext) {
        var path = Path()
        for module in plan.modules {
            let count = 9
            for index in 0..<count {
                let y = module.frame.minY + module.frame.height * (0.2 + 0.6 * CGFloat(index) / CGFloat(count - 1))
                path.move(to: CGPoint(x: plan.die.maxX, y: y.rounded() + 0.5))
                path.addLine(to: CGPoint(x: module.frame.minX, y: y.rounded() + 0.5))
            }
        }
        context.stroke(path, with: .color(Tint.pad.opacity(0.30)), lineWidth: 0.5)
    }

    private static func die(_ plan: ChipFloorplan, _ context: inout GraphicsContext) {
        let die = plan.die
        let path = Path(roundedRect: die, cornerRadius: dieRadius, style: .continuous)
        // It stands a little off the board.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            layer.fill(Path(roundedRect: die.offsetBy(dx: 0, dy: 3), cornerRadius: dieRadius, style: .continuous),
                       with: .color(.black.opacity(0.75)))
        }
        context.fill(path, with: gradient([Color(red: 0.055, green: 0.085, blue: 0.15),
                                           Color(red: 0.018, green: 0.025, blue: 0.045)], in: die))
        // Polished silicon throws back the light in two colours.
        context.fill(path, with: .linearGradient(
            Gradient(stops: [.init(color: Tint.gpu.opacity(0.16), location: 0),
                             .init(color: .clear, location: 0.42),
                             .init(color: .clear, location: 0.62),
                             .init(color: Tint.efficiency.opacity(0.10), location: 1)]),
            startPoint: CGPoint(x: die.minX, y: die.minY), endPoint: CGPoint(x: die.maxX, y: die.maxY)))

        var inside = context
        inside.clip(to: path)
        // The sea of standard cells between the named blocks.
        var cells = Path()
        var y = die.minY + 2
        while y < die.maxY {
            cells.move(to: CGPoint(x: die.minX, y: y))
            cells.addLine(to: CGPoint(x: die.maxX, y: y))
            y += 3
        }
        var x = die.minX + 2
        while x < die.maxX {
            cells.move(to: CGPoint(x: x, y: die.minY))
            cells.addLine(to: CGPoint(x: x, y: die.maxY))
            x += 9
        }
        inside.stroke(cells, with: .color(.white.opacity(0.032)), lineWidth: 0.5)

        // Bond pads around the edge.
        var pads = Path()
        let pad = CGSize(width: 3.5, height: 1.6)
        var px = die.minX + 12
        while px < die.maxX - 14 {
            pads.addRect(CGRect(x: px, y: die.minY + 3, width: pad.width, height: pad.height))
            pads.addRect(CGRect(x: px, y: die.maxY - 3 - pad.height, width: pad.width, height: pad.height))
            px += 6.5
        }
        var py = die.minY + 12
        while py < die.maxY - 14 {
            pads.addRect(CGRect(x: die.minX + 3, y: py, width: pad.height, height: pad.width))
            pads.addRect(CGRect(x: die.maxX - 3 - pad.height, y: py, width: pad.height, height: pad.width))
            py += 6.5
        }
        inside.fill(pads, with: .color(Tint.pad.opacity(0.42)))

        // Alignment marks in the corners.
        var marks = Path()
        for (cx, cy, dx, dy) in [(die.minX + 4.5, die.minY + 4.5, 1.0, 1.0), (die.maxX - 4.5, die.minY + 4.5, -1.0, 1.0),
                                 (die.minX + 4.5, die.maxY - 4.5, 1.0, -1.0), (die.maxX - 4.5, die.maxY - 4.5, -1.0, -1.0)] {
            marks.move(to: CGPoint(x: cx + 4 * dx, y: cy))
            marks.addLine(to: CGPoint(x: cx, y: cy))
            marks.addLine(to: CGPoint(x: cx, y: cy + 4 * dy))
        }
        inside.stroke(marks, with: .color(.white.opacity(0.30)), lineWidth: 0.75)

        // A bevelled edge: light from the top left.
        context.stroke(Path(roundedRect: die.insetBy(dx: 0.5, dy: 0.5), cornerRadius: dieRadius - 0.5, style: .continuous),
                       with: gradient([.white.opacity(0.42), .white.opacity(0.06)], in: die), lineWidth: 1)
    }

    private static func block(_ block: ChipFloorplan.Block, tint: Color, detailed: Bool,
                              _ context: inout GraphicsContext) {
        let path = Path(roundedRect: block.frame, cornerRadius: 4, style: .continuous)
        context.fill(path, with: .color(.black.opacity(0.34)))
        context.stroke(path, with: .color(tint.opacity(0.32)), lineWidth: 0.75)
        for cell in block.spare { logic(cell, &context) }
        for cell in block.cells {
            if detailed, isDetailed(cell) {
                core(cell, tint: tint, &context)
            } else {
                let path = Path(roundedRect: cell, cornerRadius: 1.5)
                context.fill(path, with: .color(tint.opacity(0.09)))
                if isDetailed(cell) {
                    context.stroke(tiles(cell), with: .color(tint.opacity(0.18)), lineWidth: 0.5)
                }
                context.stroke(path, with: .color(tint.opacity(0.30)), lineWidth: 0.5)
            }
        }
    }

    /// The lines inside one core, as a die shot shows it: the cache as a striped
    /// band across the top, and under it the two halves of the logic, ruled finely.
    struct CoreStructure {
        var cache = CGRect.zero
        var stripes = Path()
        var halves = Path()
        var rules = Path()

        init(_ rect: CGRect) {
            cache = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: (rect.height * 0.26).rounded())
            var x = cache.minX + 2
            while x < cache.maxX - 1 {
                stripes.move(to: CGPoint(x: x, y: cache.minY + 1.5))
                stripes.addLine(to: CGPoint(x: x, y: cache.maxY - 1))
                x += 2
            }
            let body = CGRect(x: rect.minX, y: cache.maxY, width: rect.width, height: rect.maxY - cache.maxY)
                .insetBy(dx: 2.5, dy: 2.5)
            let half = (body.width - 2) / 2
            for column in 0..<2 {
                let part = CGRect(x: body.minX + CGFloat(column) * (half + 2), y: body.minY,
                                  width: half, height: body.height)
                halves.addRoundedRect(in: part, cornerSize: CGSize(width: 1, height: 1))
                var y = part.minY + 2.5
                while y < part.maxY - 1 {
                    rules.move(to: CGPoint(x: part.minX + 1.5, y: y))
                    rules.addLine(to: CGPoint(x: part.maxX - 1.5, y: y))
                    y += 2.5
                }
            }
        }
    }

    /// Whether a cell is large enough for its structure to be more than noise.
    static func isDetailed(_ cell: CGRect) -> Bool { cell.width >= 13 && cell.height >= 13 }

    /// The tiles a GPU core is cut into: a two-by-two, the way its shading units sit.
    static func tiles(_ rect: CGRect) -> Path {
        var path = Path()
        let inner = rect.insetBy(dx: 2.5, dy: 2.5)
        path.move(to: CGPoint(x: inner.midX, y: inner.minY))
        path.addLine(to: CGPoint(x: inner.midX, y: inner.maxY))
        path.move(to: CGPoint(x: inner.minX, y: inner.midY))
        path.addLine(to: CGPoint(x: inner.maxX, y: inner.midY))
        return path
    }

    private static func core(_ rect: CGRect, tint: Color, _ context: inout GraphicsContext) {
        let path = Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous)
        context.fill(path, with: .color(tint.opacity(0.07)))
        var inside = context
        inside.clip(to: path)
        let structure = CoreStructure(rect)
        inside.fill(Path(structure.cache), with: .color(tint.opacity(0.10)))
        inside.stroke(structure.stripes, with: .color(tint.opacity(0.30)), lineWidth: 0.5)
        inside.stroke(structure.halves, with: .color(tint.opacity(0.22)), lineWidth: 0.5)
        inside.stroke(structure.rules, with: .color(tint.opacity(0.13)), lineWidth: 0.5)
        context.stroke(path, with: .color(tint.opacity(0.48)), lineWidth: 0.6)
    }

    /// Unnamed logic: a ruled patch, where a block's grid has a position to spare.
    private static func logic(_ rect: CGRect, _ context: inout GraphicsContext) {
        let path = Path(roundedRect: rect, cornerRadius: 1.5)
        var inside = context
        inside.clip(to: path)
        var rules = Path()
        var y = rect.minY + 1.5
        while y < rect.maxY {
            rules.move(to: CGPoint(x: rect.minX, y: y))
            rules.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += 2
        }
        inside.stroke(rules, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
        context.stroke(path, with: .color(.white.opacity(0.09)), lineWidth: 0.5)
    }

    private static func nameplate(_ plan: ChipFloorplan, _ context: inout GraphicsContext) {
        let path = Path(roundedRect: plan.nameplate, cornerRadius: 3, style: .continuous)
        context.fill(path, with: .color(.black.opacity(0.30)))
        context.stroke(path, with: .color(.white.opacity(0.10)), lineWidth: 0.5)
    }

    /// A memory module: a moulded package with its contacts down two sides and a
    /// bank of cells for the lights to fill.
    private static func module(_ module: ChipFloorplan.Block, _ context: inout GraphicsContext) {
        let frame = module.frame
        let path = Path(roundedRect: frame, cornerRadius: moduleRadius, style: .continuous)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 4))
            layer.fill(Path(roundedRect: frame.offsetBy(dx: 0, dy: 2), cornerRadius: moduleRadius, style: .continuous),
                       with: .color(.black.opacity(0.6)))
        }
        context.fill(path, with: gradient([Color(red: 0.11, green: 0.12, blue: 0.14),
                                           Color(red: 0.04, green: 0.045, blue: 0.055)], in: frame))
        var contacts = Path()
        var y = frame.minY + 8
        while y < frame.maxY - 9 {
            contacts.addRect(CGRect(x: frame.minX + 1.5, y: y, width: 1.6, height: 3))
            contacts.addRect(CGRect(x: frame.maxX - 3.1, y: y, width: 1.6, height: 3))
            y += 5.5
        }
        context.fill(contacts, with: .color(Tint.pad.opacity(0.40)))
        var wells = Path()
        for cell in module.cells { wells.addRoundedRect(in: cell, cornerSize: CGSize(width: 1, height: 1)) }
        context.fill(wells, with: .color(.white.opacity(0.055)))
        context.stroke(wells, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
        // The mark every package has in one corner, to say which way round it goes.
        context.fill(Path(ellipseIn: CGRect(x: frame.maxX - 9, y: frame.minY + 6.5, width: 3, height: 3)),
                     with: .color(.white.opacity(0.16)))
        context.stroke(Path(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: moduleRadius - 0.5, style: .continuous),
                       with: gradient([.white.opacity(0.30), .white.opacity(0.05)], in: frame), lineWidth: 1)
    }
}

/// The structure of the cores once more, in shadow, laid over the lights.
///
/// Light screened over the silicon would wash its lines out exactly when a core is
/// busiest. Drawn again above the light, dark, they stay: a core at full load is a
/// bright cell with its cache and logic still ruled across it.
struct ChipEtching: View, Equatable {
    let plan: ChipFloorplan

    var body: some View {
        Canvas { context, _ in
            let ink = GraphicsContext.Shading.color(.black.opacity(0.24))
            var cores = plan.performance.cells
            if let efficiency = plan.efficiency { cores += efficiency.cells }
            for cell in cores where ChipSilicon.isDetailed(cell) {
                var inside = context
                inside.clip(to: Path(roundedRect: cell, cornerRadius: 2.5, style: .continuous))
                let structure = ChipSilicon.CoreStructure(cell)
                inside.fill(Path(structure.cache), with: .color(.black.opacity(0.10)))
                inside.stroke(structure.stripes, with: ink, lineWidth: 0.5)
                inside.stroke(structure.halves, with: ink, lineWidth: 0.5)
                inside.stroke(structure.rules, with: .color(.black.opacity(0.14)), lineWidth: 0.5)
            }
            for cell in plan.gpu.cells where ChipSilicon.isDetailed(cell) {
                context.stroke(ChipSilicon.tiles(cell), with: ink, lineWidth: 0.5)
            }
            // Memory is rows of cells, and a lit bank still shows its rows.
            var rows = Path()
            for cell in plan.memoryCells where cell.height >= 9 {
                var y = cell.minY + 3
                while y < cell.maxY - 1.5 {
                    rows.move(to: CGPoint(x: cell.minX + 1.5, y: y))
                    rows.addLine(to: CGPoint(x: cell.maxX - 1.5, y: y))
                    y += 3
                }
            }
            context.stroke(rows, with: .color(.black.opacity(0.20)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
