import Foundation

/// The arithmetic behind drag-to-resize in the layout preview.
///
/// Everything here works in the preview's normalized space — x/y/width/height in
/// 0...1 of the target display — so the same numbers drive the on-screen tile and
/// the CGRect handed to Arrange. Pure and free of SwiftUI so the edge cases
/// (dragging past the opposite edge, past the display bounds, below the minimum
/// tile size) can be tested without a window on screen.
enum LayoutResize {

    /// Which part of a tile the user grabbed. Corners move two edges at once.
    enum Handle: CaseIterable {
        case top, bottom, leading, trailing
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var movesLeadingEdge: Bool {
            self == .leading || self == .topLeading || self == .bottomLeading
        }
        var movesTrailingEdge: Bool {
            self == .trailing || self == .topTrailing || self == .bottomTrailing
        }
        var movesTopEdge: Bool {
            self == .top || self == .topLeading || self == .topTrailing
        }
        var movesBottomEdge: Bool {
            self == .bottom || self == .bottomLeading || self == .bottomTrailing
        }
    }

    /// Smallest tile the user can drag to, as a fraction of the display. Below
    /// this a window is unusable and its handles overlap each other.
    static let minimumSide: Double = 0.08

    /// Apply a drag to one edge/corner of `rect`.
    ///
    /// - Parameters:
    ///   - rect: the tile before the drag, normalized.
    ///   - handle: which edge or corner is being dragged.
    ///   - deltaX: horizontal drag distance, as a fraction of display width.
    ///   - deltaY: vertical drag distance, as a fraction of display height.
    /// - Returns: the resized tile, clamped to the display and to `minimumSide`.
    ///   The opposite edge never moves — dragging the leading edge right past the
    ///   trailing edge stops at the minimum width rather than inverting the rect.
    static func resize(_ rect: NormalizedRect,
                       handle: Handle,
                       deltaX: Double,
                       deltaY: Double) -> NormalizedRect {
        var minX = rect.x
        var maxX = rect.x + rect.width
        var minY = rect.y
        var maxY = rect.y + rect.height

        if handle.movesLeadingEdge {
            minX = clamp(minX + deltaX, lower: 0, upper: maxX - minimumSide)
        }
        if handle.movesTrailingEdge {
            maxX = clamp(maxX + deltaX, lower: minX + minimumSide, upper: 1)
        }
        if handle.movesTopEdge {
            minY = clamp(minY + deltaY, lower: 0, upper: maxY - minimumSide)
        }
        if handle.movesBottomEdge {
            maxY = clamp(maxY + deltaY, lower: minY + minimumSide, upper: 1)
        }

        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Guard against a rect that has drifted outside the display — a layout
    /// preset change, a saved custom frame from a different aspect, a decode.
    static func clampToDisplay(_ rect: NormalizedRect) -> NormalizedRect {
        let width = clamp(rect.width, lower: minimumSide, upper: 1)
        let height = clamp(rect.height, lower: minimumSide, upper: 1)
        return NormalizedRect(
            x: clamp(rect.x, lower: 0, upper: 1 - width),
            y: clamp(rect.y, lower: 0, upper: 1 - height),
            width: width,
            height: height
        )
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        // An inverted range means the rect was already degenerate; prefer the
        // lower bound so the result stays inside the display.
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }
}
