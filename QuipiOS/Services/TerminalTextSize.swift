import CoreGraphics

/// The phone's own font size for terminal text (GH #38). It changes only how
/// the phone draws the text it already has; the Mac terminal's font is never
/// touched, so the desktop session does not reflow.
enum TerminalTextSize {
    static let minimum: Double = 7
    static let maximum: Double = 22
    static let standard: Double = 10

    static func clamped(_ size: Double) -> Double {
        min(maximum, max(minimum, size))
    }

    /// One A− / A+ tap per step of 1 pt.
    static func stepped(_ size: Double, by steps: Int) -> Double {
        clamped(size.rounded() + Double(steps))
    }

    /// The size after a pinch of `scale`, rounded to the half point so
    /// repeated pinches settle instead of drifting.
    static func pinched(_ size: Double, scale: CGFloat) -> Double {
        clamped((size * Double(scale) * 2).rounded() / 2)
    }
}

/// Pinch zoom for the screenshot view: 1× (fit to width) up to 4×.
enum ScreenshotZoom {
    static let maximum: CGFloat = 4

    static func clamped(_ scale: CGFloat) -> CGFloat {
        min(maximum, max(1, scale))
    }
}
