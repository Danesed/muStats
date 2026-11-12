import SwiftUI

/// Where everything on the live chip sits: the package, the die on it, the blocks on
/// the die and the cores in the blocks, and the memory modules beside it.
///
/// Worked out once from the size and the core counts, and shared by the drawing of
/// the silicon and the lights laid over it, so a light cannot miss its core.
///
/// The arrangement is the one Apple's own pictures of these chips have: the die to
/// the left of the package and the memory modules stacked to its right, since on
/// Apple silicon the memory is on the package and not on the board.
struct ChipFloorplan: Equatable {
    struct Block: Equatable {
        var frame: CGRect
        /// The strip the block's name and reading are set in.
        var label: CGRect
        /// One rectangle per core.
        var cells: [CGRect]
        /// Grid positions no core fills, drawn as plain logic so the block has no hole.
        var spare: [CGRect]
    }

    var size: CGSize
    var die: CGRect
    var performance: Block
    /// Nil on a Mac with one kind of core.
    var efficiency: Block?
    var gpu: Block
    /// The strip along the bottom of the die that carries the chip's name.
    var nameplate: CGRect
    var modules: [Block]

    /// Memory cells in the order they fill: the first module bottom row first, then
    /// the second.
    var memoryCells: [CGRect] { modules.flatMap(\.cells) }

    static let memoryColumns = 4
    static let memoryRows = 5

    static func make(size: CGSize, performance: Int, efficiency: Int, gpu: Int) -> ChipFloorplan {
        let inner = CGRect(origin: .zero, size: size).insetBy(dx: 11, dy: 11)
        let gap: CGFloat = 11
        let memoryWidth = (inner.width * 0.225).rounded()
        let die = CGRect(x: inner.minX, y: inner.minY,
                         width: inner.width - memoryWidth - gap, height: inner.height)

        // The die: a ring of bond pads, the blocks, and the nameplate under them.
        let core = die.insetBy(dx: 9, dy: 9)
        let plate: CGFloat = 17
        let nameplate = CGRect(x: core.minX, y: core.maxY - plate, width: core.width, height: plate)
        let area = CGRect(x: core.minX, y: core.minY, width: core.width, height: core.height - plate - 5)
        let split: CGFloat = 5
        let cpuWidth = ((area.width - split) * 0.55).rounded()
        let cpu = CGRect(x: area.minX, y: area.minY, width: cpuWidth, height: area.height)
        let gpuFrame = CGRect(x: cpu.maxX + split, y: area.minY,
                              width: area.width - cpuWidth - split, height: area.height)

        let performanceFrame: CGRect
        var efficiencyBlock: Block?
        if efficiency > 0 {
            // A performance core is the larger core, so its block takes more of the
            // column than its count alone would give it.
            let weight = Double(max(performance, 1)) * 1.7
            let share = min(max(weight / (weight + Double(efficiency)), 0.45), 0.68)
            let height = ((cpu.height - split) * share).rounded()
            performanceFrame = CGRect(x: cpu.minX, y: cpu.minY, width: cpu.width, height: height)
            let rest = CGRect(x: cpu.minX, y: cpu.minY + height + split,
                              width: cpu.width, height: cpu.height - height - split)
            efficiencyBlock = block(rest, count: efficiency, gap: 3)
        } else {
            performanceFrame = cpu
        }

        let moduleGap: CGFloat = 9
        let moduleHeight = ((inner.height - moduleGap) / 2).rounded(.down)
        let modules = (0..<2).map { index -> Block in
            let frame = CGRect(x: die.maxX + gap, y: inner.minY + CGFloat(index) * (moduleHeight + moduleGap),
                               width: memoryWidth, height: moduleHeight)
            return memoryModule(frame)
        }

        return ChipFloorplan(size: size, die: die,
                             performance: block(performanceFrame, count: max(performance, 0), gap: 4),
                             efficiency: efficiencyBlock,
                             gpu: block(gpuFrame, count: max(gpu, 1), gap: gpu > 40 ? 2 : 3),
                             nameplate: nameplate, modules: modules)
    }

    /// A block with its label strip and `count` cores tiled under it.
    static func block(_ frame: CGRect, count: Int, gap: CGFloat) -> Block {
        let content = frame.insetBy(dx: 5, dy: 5)
        let labelHeight: CGFloat = 11
        let label = CGRect(x: content.minX, y: content.minY, width: content.width, height: labelHeight)
        let area = CGRect(x: content.minX, y: content.minY + labelHeight + 4,
                          width: content.width, height: content.height - labelHeight - 4)
        let slots = grid(count: count, in: area, gap: gap)
        return Block(frame: frame, label: label, cells: Array(slots.prefix(count)),
                     spare: Array(slots.dropFirst(count)))
    }

    /// A memory module: its label, and a bank of cells that fills from the bottom.
    static func memoryModule(_ frame: CGRect) -> Block {
        let content = frame.insetBy(dx: 6, dy: 5)
        let labelHeight: CGFloat = 11
        let label = CGRect(x: content.minX, y: content.minY, width: content.width, height: labelHeight)
        let area = CGRect(x: content.minX, y: content.minY + labelHeight + 4,
                          width: content.width, height: content.height - labelHeight - 4)
        let gap: CGFloat = 2
        let width = (area.width - CGFloat(memoryColumns - 1) * gap) / CGFloat(memoryColumns)
        let height = (area.height - CGFloat(memoryRows - 1) * gap) / CGFloat(memoryRows)
        var cells: [CGRect] = []
        for row in (0..<memoryRows).reversed() {
            for column in 0..<memoryColumns {
                cells.append(CGRect(x: area.minX + CGFloat(column) * (width + gap),
                                    y: area.minY + CGFloat(row) * (height + gap),
                                    width: width, height: height))
            }
        }
        return Block(frame: frame, label: label, cells: cells, spare: [])
    }

    /// `count` cells tiled to fill `area`, row by row, in the arrangement whose cells
    /// come out nearest to square with the fewest positions left over. Four cores are
    /// a two-by-two of large ones, twenty-four a tight grid of small ones, and both
    /// fill their block the way cores fill a die.
    static func grid(count: Int, in area: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0, area.width > 0, area.height > 0 else { return [] }
        var best: (columns: Int, rows: Int, score: Double)?
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let width = (area.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            let height = (area.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            guard width >= 2, height >= 2 else { continue }
            let shape = abs(log(Double(width / height)))
            let spare = Double(columns * rows - count) / Double(count)
            let score = shape + spare * 0.9
            if best == nil || score < best!.score { best = (columns, rows, score) }
        }
        guard let best else { return [] }
        let width = (area.width - CGFloat(best.columns - 1) * gap) / CGFloat(best.columns)
        let height = (area.height - CGFloat(best.rows - 1) * gap) / CGFloat(best.rows)
        var slots: [CGRect] = []
        slots.reserveCapacity(best.columns * best.rows)
        for row in 0..<best.rows {
            for column in 0..<best.columns {
                slots.append(CGRect(x: area.minX + CGFloat(column) * (width + gap),
                                    y: area.minY + CGFloat(row) * (height + gap),
                                    width: width, height: height))
            }
        }
        return slots
    }
}
