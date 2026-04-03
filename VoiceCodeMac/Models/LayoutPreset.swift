import Foundation

// MARK: - Layout Mode

enum LayoutMode: String, Codable, CaseIterable, Identifiable {
    case columns
    case rows
    case grid
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .columns: "Columns"
        case .rows: "Rows"
        case .grid: "Grid"
        case .custom: "Custom"
        }
    }

    var icon: String {
        switch self {
        case .columns: "rectangle.split.3x1"
        case .rows: "rectangle.split.1x2"
        case .grid: "rectangle.split.2x2"
        case .custom: "rectangle.dashed"
        }
    }
}

// MARK: - Layout Calculator

enum LayoutCalculator {
    static func calculate(mode: LayoutMode, windowCount: Int, customFrames: [String: NormalizedRect]? = nil) -> [NormalizedRect] {
        guard windowCount > 0 else { return [] }

        switch mode {
        case .columns:
            return calculateColumns(count: windowCount)
        case .rows:
            return calculateRows(count: windowCount)
        case .grid:
            return calculateGrid(count: windowCount)
        case .custom:
            if let custom = customFrames {
                return Array(custom.values.prefix(windowCount))
            }
            return calculateGrid(count: windowCount)
        }
    }

    private static func calculateColumns(count: Int) -> [NormalizedRect] {
        let width = 1.0 / Double(count)
        return (0..<count).map { i in
            NormalizedRect(x: Double(i) * width, y: 0, width: width, height: 1.0)
        }
    }

    private static func calculateRows(count: Int) -> [NormalizedRect] {
        let height = 1.0 / Double(count)
        return (0..<count).map { i in
            NormalizedRect(x: 0, y: Double(i) * height, width: 1.0, height: height)
        }
    }

    private static func calculateGrid(count: Int) -> [NormalizedRect] {
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellWidth = 1.0 / Double(cols)
        let cellHeight = 1.0 / Double(rows)

        return (0..<count).map { i in
            let col = i % cols
            let row = i / cols
            return NormalizedRect(
                x: Double(col) * cellWidth,
                y: Double(row) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
        }
    }
}

// MARK: - Normalized Rect (0-1 coordinate space)

struct NormalizedRect: Codable, Sendable, Identifiable {
    var id = UUID()
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func toWindowFrame() -> WindowFrame {
        WindowFrame(x: x, y: y, width: width, height: height)
    }

    func toCGRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.origin.x + x * bounds.width,
            y: bounds.origin.y + y * bounds.height,
            width: width * bounds.width,
            height: height * bounds.height
        )
    }
}

// MARK: - Saved Layout Preset

struct SavedLayoutPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var mode: LayoutMode
    var customFrames: [String: NormalizedRect]?
    var windowOrder: [String]
    var createdAt: Date

    init(name: String, mode: LayoutMode, customFrames: [String: NormalizedRect]? = nil, windowOrder: [String] = []) {
        self.name = name
        self.mode = mode
        self.customFrames = customFrames
        self.windowOrder = windowOrder
        self.createdAt = Date()
    }
}

// MARK: - Custom Layout Presets

enum CustomLayoutTemplate: String, CaseIterable, Identifiable {
    case largeLeftSmallRight = "Large + Right Stack"
    case largeTopSmallBottom = "Large + Bottom Stack"
    case twoLargeSmallRight = "Two Large + Right Column"

    var id: String { rawValue }

    func frames(for count: Int) -> [NormalizedRect] {
        guard count > 0 else { return [] }

        switch self {
        case .largeLeftSmallRight:
            guard count > 1 else { return [NormalizedRect(x: 0, y: 0, width: 1, height: 1)] }
            let smallCount = count - 1
            let smallHeight = 1.0 / Double(smallCount)
            var rects = [NormalizedRect(x: 0, y: 0, width: 0.6, height: 1.0)]
            for i in 0..<smallCount {
                rects.append(NormalizedRect(x: 0.6, y: Double(i) * smallHeight, width: 0.4, height: smallHeight))
            }
            return rects

        case .largeTopSmallBottom:
            guard count > 1 else { return [NormalizedRect(x: 0, y: 0, width: 1, height: 1)] }
            let smallCount = count - 1
            let smallWidth = 1.0 / Double(smallCount)
            var rects = [NormalizedRect(x: 0, y: 0, width: 1.0, height: 0.6)]
            for i in 0..<smallCount {
                rects.append(NormalizedRect(x: Double(i) * smallWidth, y: 0.6, width: smallWidth, height: 0.4))
            }
            return rects

        case .twoLargeSmallRight:
            guard count > 2 else { return LayoutCalculator.calculate(mode: .columns, windowCount: count) }
            let smallCount = count - 2
            let smallHeight = 1.0 / Double(smallCount)
            var rects = [
                NormalizedRect(x: 0, y: 0, width: 0.35, height: 1.0),
                NormalizedRect(x: 0.35, y: 0, width: 0.35, height: 1.0),
            ]
            for i in 0..<smallCount {
                rects.append(NormalizedRect(x: 0.7, y: Double(i) * smallHeight, width: 0.3, height: smallHeight))
            }
            return rects
        }
    }
}
