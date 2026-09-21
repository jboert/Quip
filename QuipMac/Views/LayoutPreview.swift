// LayoutPreview.swift
// QuipMac — Visual preview of the window layout on the selected display

import SwiftUI

struct LayoutPreview: View {
    let windows: [ManagedWindow]
    let frames: [NormalizedRect]
    let layoutMode: LayoutMode
    let isDragToResizeEnabled: Bool
    @Binding var customFrames: [String: NormalizedRect]
    var onReorder: ((_ fromIndex: Int, _ toIndex: Int) -> Void)?

    @State private var dragState: DragState?
    @State private var resizeState: ResizeState?

    private struct DragState {
        let fromIndex: Int
        var currentPoint: CGPoint
    }

    /// A live resize: which tile, which handle, and the rect the tile had when
    /// the drag started. Deltas are applied against `original` rather than
    /// accumulated, so a drag that reverses lands exactly back where it began.
    private struct ResizeState {
        let windowId: String
        let handle: LayoutResize.Handle
        let original: NormalizedRect
    }

    /// Side of the square hit target drawn at each edge/corner, in points.
    private static let handleSide: CGFloat = 14

    var body: some View {
        let enabled = enabledWindows

        GeometryReader { geo in
            let pb = previewRect(in: geo.size)

            ZStack {
                monitorBackground(previewBounds: pb)

                // Tiles
                ForEach(Array(enabled.enumerated()), id: \.element.id) { index, window in
                    if index < frames.count {
                        let rect = tileRect(frame: effectiveFrame(for: window, at: index), in: pb)
                        let color = Color(hex: window.assignedColor)
                        let isDragging = dragState?.fromIndex == index
                        let isTarget = targetIndex(in: pb, enabledWindowCount: enabled.count) == index
                            && dragState != nil
                            && dragState?.fromIndex != index

                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(color.opacity(isTarget ? 0.4 : 0.2))
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(isTarget ? Color.white : color, lineWidth: isTarget ? 3 : 2)
                            VStack(spacing: 2) {
                                Text(window.subtitle.isEmpty ? window.app : window.subtitle)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(color)
                                    .lineLimit(1)
                                if rect.height > 50 {
                                    Text(window.subtitle.isEmpty ? window.name : window.app)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(6)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(isDragging ? 0.4 : 1.0)
                        .scaleEffect(isTarget ? 1.06 : 1.0)
                        .animation(.spring(duration: 0.15), value: isTarget)

                        if isDragToResizeEnabled {
                            resizeHandles(for: window, at: index, rect: rect, color: color, previewBounds: pb)
                        }
                    }
                }

                // Dragged tile overlay (follows cursor)
                if let ds = dragState, ds.fromIndex < enabled.count, ds.fromIndex < frames.count {
                    let window = enabled[ds.fromIndex]
                    let origRect = tileRect(frame: frames[ds.fromIndex], in: pb)
                    let color = Color(hex: window.assignedColor)

                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(color.opacity(0.3))
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(color, lineWidth: 2)
                        Text(window.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                    }
                    .frame(width: origRect.width, height: origRect.height)
                    .position(ds.currentPoint)
                    .shadow(color: .black.opacity(0.4), radius: 10)
                    .zIndex(100)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            // Reorder and resize both want a drag inside a tile, so they are
            // modal rather than simultaneous: the toggle picks one. Handles are
            // only hit-testable in resize mode, and this gesture is only
            // installed outside it.
            .gesture(
                isDragToResizeEnabled ? nil : DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if dragState == nil {
                            // Find which tile the drag started in
                            if let idx = indexAt(point: value.startLocation, in: pb, windowCount: enabled.count) {
                                dragState = DragState(fromIndex: idx, currentPoint: value.location)
                            }
                        } else {
                            dragState?.currentPoint = value.location
                        }
                    }
                    .onEnded { value in
                        if let ds = dragState {
                            if let toIdx = indexAt(point: value.location, in: pb, windowCount: enabled.count),
                               toIdx != ds.fromIndex {
                                onReorder?(ds.fromIndex, toIdx)
                            }
                        }
                        dragState = nil
                    }
            )
        }
        .padding(16)
    }

    private var enabledWindows: [ManagedWindow] {
        windows.filter(\.isEnabled)
    }

    // MARK: - Drag to resize

    /// A window the user has resized keeps its own rect; everything else follows
    /// the layout preset. Same rule MainWindow uses to build Arrange targets, so
    /// what the preview shows is what Arrange does.
    private func effectiveFrame(for window: ManagedWindow, at index: Int) -> NormalizedRect {
        if let custom = customFrames[window.id] {
            return LayoutResize.clampToDisplay(custom)
        }
        return frames[index]
    }

    @ViewBuilder
    private func resizeHandles(for window: ManagedWindow,
                               at index: Int,
                               rect: CGRect,
                               color: Color,
                               previewBounds pb: CGRect) -> some View {
        ForEach(Array(LayoutResize.Handle.allCases.enumerated()), id: \.offset) { _, handle in
            let point = handlePoint(handle, in: rect)
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Circle().strokeBorder(color, lineWidth: 2))
                .frame(width: Self.handleSide, height: Self.handleSide)
                .position(x: point.x, y: point.y)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if resizeState == nil {
                                resizeState = ResizeState(
                                    windowId: window.id,
                                    handle: handle,
                                    original: effectiveFrame(for: window, at: index)
                                )
                            }
                            applyResize(translation: value.translation, previewBounds: pb)
                        }
                        .onEnded { value in
                            applyResize(translation: value.translation, previewBounds: pb)
                            resizeState = nil
                        }
                )
                .accessibilityLabel("Resize \(window.name)")
        }
    }

    private func handlePoint(_ handle: LayoutResize.Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .top:             return CGPoint(x: rect.midX, y: rect.minY)
        case .bottom:          return CGPoint(x: rect.midX, y: rect.maxY)
        case .leading:         return CGPoint(x: rect.minX, y: rect.midY)
        case .trailing:        return CGPoint(x: rect.maxX, y: rect.midY)
        case .topLeading:      return CGPoint(x: rect.minX, y: rect.minY)
        case .topTrailing:     return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeading:   return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomTrailing:  return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// Translate a point-space drag into the normalized space the frames live
    /// in, then hand the arithmetic to LayoutResize. Applied against the rect
    /// captured at drag start, so reversing a drag returns to the exact original.
    private func applyResize(translation: CGSize, previewBounds pb: CGRect) {
        guard let state = resizeState, pb.width > 0, pb.height > 0 else { return }
        let resized = LayoutResize.resize(
            state.original,
            handle: state.handle,
            deltaX: Double(translation.width / pb.width),
            deltaY: Double(translation.height / pb.height)
        )
        customFrames[state.windowId] = resized
    }

    private func targetIndex(in pb: CGRect, enabledWindowCount: Int) -> Int? {
        guard let ds = dragState else { return nil }
        return indexAt(point: ds.currentPoint, in: pb, windowCount: enabledWindowCount)
    }

    private func indexAt(point: CGPoint, in pb: CGRect, windowCount: Int) -> Int? {
        for i in 0..<min(windowCount, frames.count) {
            let rect = tileRect(frame: frames[i], in: pb)
            if rect.contains(point) { return i }
        }
        return nil
    }

    private func tileRect(frame: NormalizedRect, in pb: CGRect) -> CGRect {
        let gap: CGFloat = 3
        return CGRect(
            x: pb.origin.x + frame.x * pb.width + gap,
            y: pb.origin.y + frame.y * pb.height + gap,
            width: frame.width * pb.width - gap * 2,
            height: frame.height * pb.height - gap * 2
        )
    }

    private func previewRect(in size: CGSize) -> CGRect {
        let ar: CGFloat = 16.0 / 10.0
        var w = size.width - 32
        var h = w / ar
        if h > size.height - 32 { h = size.height - 32; w = h * ar }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func monitorBackground(previewBounds pb: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                .frame(width: pb.width + 8, height: pb.height + 8)
                .position(x: pb.midX, y: pb.midY)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: pb.width, height: pb.height)
                .position(x: pb.midX, y: pb.midY)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                .frame(width: pb.width, height: pb.height)
                .position(x: pb.midX, y: pb.midY)
        }
    }
}
