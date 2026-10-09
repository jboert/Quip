import SwiftUI
import UIKit

/// Hold-and-drag reordering for a horizontal row of buttons (Q-65).
///
/// Hold a button for 0.35 s and it lifts; drag it and the others slide
/// out of its way; let go and the order sticks. Release without moving and
/// the item's own hold action runs instead (the arrange button's realign,
/// the keyboard button's paste), so nothing a long press did before is lost.
/// A quick press is a tap and runs the button's action. UIKit recognizers
/// decide (a long press that a still finger satisfies, and a tap that waits
/// for it to fail), because SwiftUI's Button and long press cannot share
/// touch-down.
@MainActor
@Observable
final class RowReorderState {
    var draggingID: String?
    var translation: CGFloat = 0
    var startMidX: CGFloat = 0
    /// Every item's frame in the row's named coordinate space, kept current
    /// across reorders so the lifted item can stay under the finger.
    var frames: [String: CGRect] = [:]

    func offset(for id: String) -> CGFloat {
        guard id == draggingID, let frame = frames[id] else { return 0 }
        return startMidX + translation - frame.midX
    }

    func lift(_ id: String) {
        guard draggingID == nil, let frame = frames[id] else { return }
        draggingID = id
        startMidX = frame.midX
        translation = 0
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func drop() {
        draggingID = nil
        translation = 0
    }
}

struct RowItemFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// PURE helpers, unit-tested.
enum RowReorderMath {
    /// The slot the dragged item should occupy: the number of other items
    /// whose centre it has passed. Items without a frame are not in the row.
    static func targetIndex(order: [String], dragging id: String, centerX: CGFloat,
                            frames: [String: CGRect]) -> Int {
        var index = 0
        for other in order where other != id {
            guard let frame = frames[other] else { continue }
            if centerX > frame.midX { index += 1 }
        }
        return index
    }

    /// `order` with `id` moved to `index` (its index among the others).
    static func move(_ order: [String], id: String, to index: Int) -> [String] {
        var rest = order.filter { $0 != id }
        let at = max(0, min(index, rest.count))
        rest.insert(id, at: at)
        return rest
    }
}

private struct RowReorderItem: ViewModifier {
    let id: String
    let space: String
    let state: RowReorderState
    let order: [String]
    let tap: (() -> Void)?
    let hold: (() -> Void)?
    let onMove: (String, Int) -> Void
    /// Kept for call-site symmetry; UIKit recognizers behave the same in and
    /// out of a scroll view (the overlay disables scrolling while an item is
    /// lifted, so the row cannot pan away under the finger).
    let exclusive: Bool

    private static let slop: CGFloat = 8

    func body(content: Content) -> some View {
        let dragging = state.draggingID == id
        content
            // The Button inside keeps VoiceOver's activate; touches go to the
            // overlay, whose UIKit recognizers tell a tap, a still hold and a
            // hold-and-drag apart. SwiftUI's own gestures could not share
            // touch-down between a Button and a long press.
            .allowsHitTesting(false)
            .overlay(RowTouchOverlay(
                onTap: { tap?() },
                onHoldBegan: {
                    withAnimation(.spring(duration: 0.22, bounce: 0.15)) { state.lift(id) }
                },
                onHoldMoved: { dx in
                    guard state.draggingID == id else { return }
                    state.translation = dx
                    let center = state.startMidX + dx
                    let target = RowReorderMath.targetIndex(order: order, dragging: id,
                                                            centerX: center, frames: state.frames)
                    if target != order.firstIndex(of: id) {
                        withAnimation(.spring(duration: 0.22, bounce: 0.1)) { onMove(id, target) }
                    }
                },
                onHoldEnded: { dx in
                    guard state.draggingID == id else { return }
                    if abs(dx) < Self.slop { hold?() }
                    withAnimation(.spring(duration: 0.22, bounce: 0.15)) { state.drop() }
                }))
            .rowFrame(id, space: space, state: state)
            .offset(x: state.offset(for: id))
            .scaleEffect(dragging ? 1.08 : 1)
            .opacity(dragging ? 0.92 : 1)
            .zIndex(dragging ? 10 : 0)
            .animation(.spring(duration: 0.22, bounce: 0.15), value: dragging)
    }
}

/// A clear UIKit view carrying a tap recognizer and a long-press recognizer
/// (0.35 s, 8 pt of allowed movement). The tap waits for the long press to
/// fail, so a quick press taps and a held one lifts; a held finger that
/// never moves still lifts, which no SwiftUI drag gesture reports.
private struct RowTouchOverlay: UIViewRepresentable {
    let onTap: () -> Void
    let onHoldBegan: () -> Void
    let onHoldMoved: (CGFloat) -> Void
    let onHoldEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.35
        press.allowableMovement = 8
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: press)
        view.addGestureRecognizer(press)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: RowTouchOverlay
        private var startX: CGFloat = 0
        private weak var scrollView: UIScrollView?

        init(_ parent: RowTouchOverlay) { self.parent = parent }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            parent.onTap()
        }

        @objc func press(_ recognizer: UILongPressGestureRecognizer) {
            let x = recognizer.location(in: nil).x
            switch recognizer.state {
            case .began:
                startX = x
                // A lifted item must not scroll away under the finger.
                scrollView = recognizer.view.flatMap { enclosingScrollView($0) }
                scrollView?.isScrollEnabled = false
                parent.onHoldBegan()
            case .changed:
                parent.onHoldMoved(x - startX)
            case .ended, .cancelled, .failed:
                scrollView?.isScrollEnabled = true
                scrollView = nil
                parent.onHoldEnded(x - startX)
            default:
                break
            }
        }

        private func enclosingScrollView(_ view: UIView) -> UIScrollView? {
            var next = view.superview
            while let v = next {
                if let scroll = v as? UIScrollView { return scroll }
                next = v.superview
            }
            return nil
        }
    }
}

private struct RowFrameReporter: ViewModifier {
    let id: String
    let space: String
    let state: RowReorderState

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                Color.clear.preference(key: RowItemFramesKey.self, value: [id: geo.frame(in: .named(space))])
            })
            .onPreferenceChange(RowItemFramesKey.self) { frames in
                state.frames.merge(frames, uniquingKeysWith: { $1 })
            }
    }
}

extension View {
    /// Makes this row item hold-and-draggable. `order` is the row's current
    /// item order (what `onMove` reorders); `space` names the row's
    /// coordinate space (`.coordinateSpace(name:)` on the row container).
    func rowReorderItem(_ id: String, state: RowReorderState, space: String, order: [String],
                        tap: (() -> Void)?, hold: (() -> Void)? = nil, exclusive: Bool = true,
                        onMove: @escaping (String, Int) -> Void) -> some View {
        modifier(RowReorderItem(id: id, space: space, state: state, order: order,
                                tap: tap, hold: hold, onMove: onMove, exclusive: exclusive))
    }

    /// Reports this item's frame only (a fixed item others can be dragged past).
    func rowFrame(_ id: String, space: String, state: RowReorderState) -> some View {
        modifier(RowFrameReporter(id: id, space: space, state: state))
    }
}
