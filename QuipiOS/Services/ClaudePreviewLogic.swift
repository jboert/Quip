import CoreGraphics
import Foundation

/// Q-87 phone rules that don't need a view: which previews a terminal shows,
/// and the zoom arithmetic for the full-screen viewer.
enum ClaudePreviewLogic {
    /// The previews to show with `selectedWindowId`: its own, plus any the Mac
    /// could not tie to a terminal it still lists (unattached, or the terminal
    /// has since closed). Those would otherwise be invisible everywhere.
    static func visible(_ items: [ClaudePreviewItem], selectedWindowId: String?,
                        knownWindowIds: Set<String>) -> [ClaudePreviewItem] {
        items.filter { item in
            guard let owner = item.terminalWindowId, knownWindowIds.contains(owner) else { return true }
            return owner == selectedWindowId
        }
    }
}

/// Zoom scales for an image shown in a `UIScrollView` whose content view is the
/// image at 1 point per image pixel. Scale `s` draws one image pixel as `s`
/// points.
enum ZoomMath {
    /// Whole image visible.
    static func fitScale(image: CGSize, viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / image.width, viewport.height / image.height)
    }

    /// One image pixel per screen pixel ("100 %").
    static func pixelScale(screenScale: CGFloat) -> CGFloat {
        1 / max(screenScale, 1)
    }

    static func minScale(fit: CGFloat, pixel: CGFloat) -> CGFloat { min(fit, pixel) }

    /// 4× past 100 %, so a single pixel of a render can be inspected.
    static func maxScale(fit: CGFloat, pixel: CGFloat) -> CGFloat { max(fit * 2, pixel * 4) }

    /// Double-tap: at fit go to 100 % (or 2.5× fit when 100 % is about fit, as
    /// for a small image); anywhere else go back to fit.
    static func doubleTapTarget(current: CGFloat, fit: CGFloat, pixel: CGFloat) -> CGFloat {
        let atFit = abs(current - fit) <= fit * 0.02
        guard atFit else { return fit }
        return pixel > fit * 1.2 ? pixel : fit * 2.5
    }

    /// The rect (image coordinates) to zoom to so `point` stays under the
    /// finger at `scale`, clamped inside the image.
    static func zoomRect(around point: CGPoint, scale: CGFloat, viewport: CGSize, image: CGSize) -> CGRect {
        let w = viewport.width / scale, h = viewport.height / scale
        var x = point.x - w / 2, y = point.y - h / 2
        x = min(max(0, x), max(0, image.width - w))
        y = min(max(0, y), max(0, image.height - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Insets that centre content smaller than the viewport.
    static func centeringInsets(content: CGSize, viewport: CGSize) -> (horizontal: CGFloat, vertical: CGFloat) {
        (max(0, (viewport.width - content.width) / 2), max(0, (viewport.height - content.height) / 2))
    }
}
