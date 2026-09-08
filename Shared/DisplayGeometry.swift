// DisplayGeometry.swift
// Quip — Pure geometry for a multi-display Mac desktop.
//
// Lives in Shared/ because BOTH peers need the same arithmetic and neither can
// be trusted to re-derive it: the Mac normalizes each window against its OWN
// display before broadcasting, and the phone re-composes those per-display
// rects onto one merged "whole desktop" canvas when the user picks the "All"
// chip. If the two disagree by even a sign, windows land off-canvas — which is
// exactly the bug this file exists to end (a single-display assumption in
// `broadcastLayout` normalized second-screen windows to x > 1).
//
// Everything here is `static` and free of AppKit so the Foundation-only test
// harness can prove the math without attaching monitors.

import Foundation

/// One connected display, as the phone sees it.
///
/// `spanFrame` is the display's own rect normalized into the union of every
/// connected display (the "desktop span"). That is what makes the merged view
/// possible: a window's frame is normalized against its display, and the
/// display's `spanFrame` places that display inside the span, so
/// `DisplayGeometry.spanFrame(ofWindow:onDisplay:)` composes the two without
/// the phone ever seeing a pixel coordinate.
struct DisplayState: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Stable across focus changes and reconnects — the `CGDirectDisplayID`
    /// as a string, NOT an enumeration index. An index-based id silently
    /// re-points at a different monitor the moment displays are reordered or
    /// one is unplugged, which would strand the phone's saved chip selection
    /// on the wrong screen.
    let id: String
    /// `NSScreen.localizedName`, e.g. "C34J79x" / "Studio Display".
    let name: String
    /// True for `NSScreen.screens.first` — the display CoreGraphics measures
    /// from. Deliberately NOT `NSScreen.main`, which is the *focused* screen
    /// and therefore changes when the user clicks the other monitor.
    let isPrimary: Bool
    /// width / height of this display, for a correctly-proportioned thumbnail.
    let aspect: Double
    /// This display's rect inside the union of all displays, normalized 0-1.
    /// A single-display Mac gets `(0, 0, 1, 1)`.
    let spanFrame: WindowFrame

    init(id: String, name: String, isPrimary: Bool, aspect: Double, spanFrame: WindowFrame) {
        self.id = id
        self.name = name
        self.isPrimary = isPrimary
        self.aspect = aspect
        self.spanFrame = spanFrame
    }
}

/// Rect helpers shared by both peers. A plain tuple-ish value type is used
/// instead of `CGRect` so this file stays Foundation-only (CoreGraphics is
/// available on both platforms, but keeping it out lets the 2-second swiftc
/// harness compile the file with no framework search paths at all).
struct DisplayRect: Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }
}

enum DisplayGeometry {

    /// Normalize a window's rect against the display it sits on. Both rects
    /// must already be in the SAME coordinate space (the Mac converts its
    /// `NSScreen` frames into CG space first — see `WindowManager.cgFrame(for:)`).
    ///
    /// Returns a zeroed frame for a degenerate display so a disconnected or
    /// mid-reconfiguration screen can't produce NaN/inf on the wire.
    static func normalize(window: DisplayRect, on display: DisplayRect) -> WindowFrame {
        guard display.width > 0, display.height > 0 else {
            return WindowFrame(x: 0, y: 0, width: 0, height: 0)
        }
        return WindowFrame(
            x: (window.x - display.x) / display.width,
            y: (window.y - display.y) / display.height,
            width: window.width / display.width,
            height: window.height / display.height
        )
    }

    /// The bounding box of every display — the "desktop span".
    /// Empty input yields a unit rect so callers never divide by zero.
    static func span(of displays: [DisplayRect]) -> DisplayRect {
        guard let first = displays.first else {
            return DisplayRect(x: 0, y: 0, width: 1, height: 1)
        }
        var minX = first.x, minY = first.y, maxX = first.maxX, maxY = first.maxY
        for d in displays.dropFirst() {
            minX = min(minX, d.x)
            minY = min(minY, d.y)
            maxX = max(maxX, d.maxX)
            maxY = max(maxY, d.maxY)
        }
        return DisplayRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A display's own rect normalized into the desktop span. This is what
    /// ships as `DisplayState.spanFrame`.
    static func spanFrame(of display: DisplayRect, in span: DisplayRect) -> WindowFrame {
        normalize(window: display, on: span)
    }

    /// Compose a per-display window frame onto the merged desktop canvas.
    /// Inverse of the split the Mac performs: the phone's "All" chip renders
    /// `spanFrame(ofWindow:onDisplay:)` against a span-aspect canvas and every
    /// window lands where it really is, on either monitor.
    static func spanFrame(ofWindow window: WindowFrame, onDisplay display: WindowFrame) -> WindowFrame {
        WindowFrame(
            x: display.x + window.x * display.width,
            y: display.y + window.y * display.height,
            width: window.width * display.width,
            height: window.height * display.height
        )
    }

    /// Which display a window belongs to: the one containing its center point.
    /// Falls back to the primary (else the first) display when the center
    /// falls in a gap between mismatched monitors — a window must never lose
    /// its display and vanish from every chip.
    static func displayID(forWindow window: DisplayRect,
                          displays: [(id: String, isPrimary: Bool, rect: DisplayRect)]) -> String? {
        guard !displays.isEmpty else { return nil }
        if let hit = displays.first(where: { $0.rect.contains(x: window.midX, y: window.midY) }) {
            return hit.id
        }
        return (displays.first(where: { $0.isPrimary }) ?? displays[0]).id
    }
}
