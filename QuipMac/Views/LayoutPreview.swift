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

    private struct DragState {
        let fromIndex: Int
        var currentPoint: CGPoint
    }

    var body: some View {
        GeometryReader { geo in
            let pb = previewRect(in: geo.size)

            ZStack {
                monitorBackground(previewBounds: pb)

                // Tiles
                ForEach(Array(enabledWindows.enumerated()), id: \.element.id) { index, window in
                    if index < frames.count {
                        let rect = tileRect(frame: frames[index], in: pb)
                        let color = Color(hex: window.assignedColor)
                        let isDragging = dragState?.fromIndex == index
                        let isTarget = targetIndex(in: pb) == index && dragState != nil && dragState?.fromIndex != index

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
                    }
                }

                // Dragged tile overlay (follows cursor)
                if let ds = dragState, ds.fromIndex < enabledWindows.count, ds.fromIndex < frames.count {
                    let window = enabledWindows[ds.fromIndex]
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
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if dragState == nil {
                            // Find which tile the drag started in
                            if let idx = indexAt(point: value.startLocation, in: pb) {
                                dragState = DragState(fromIndex: idx, currentPoint: value.location)
                            }
                        } else {
                            dragState?.currentPoint = value.location
                        }
                    }
                    .onEnded { value in
                        if let ds = dragState {
                            if let toIdx = indexAt(point: value.location, in: pb), toIdx != ds.fromIndex {
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

    private func targetIndex(in pb: CGRect) -> Int? {
        guard let ds = dragState else { return nil }
        return indexAt(point: ds.currentPoint, in: pb)
    }

    private func indexAt(point: CGPoint, in pb: CGRect) -> Int? {
        for i in 0..<min(enabledWindows.count, frames.count) {
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
