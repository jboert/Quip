import SwiftUI

/// Q-87: thumbnails of the files Claude opened from this terminal, newest
/// first, above the terminal content. Tap opens full screen; ✕ removes it and
/// closes its Preview window on the Mac when there is one.
struct ClaudePreviewStrip: View {
    let items: [ClaudePreviewItem]
    let onOpen: (ClaudePreviewItem) -> Void
    let onDismiss: (ClaudePreviewItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    cell(item)
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .frame(height: 76)
    }

    private func cell(_ item: ClaudePreviewItem) -> some View {
        Button { onOpen(item) } label: {
            thumbnail(item)
                .frame(width: 56, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(item.name)")
        .overlay(alignment: .topTrailing) {
            Button { onDismiss(item) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 12, y: -12)
            .accessibilityLabel(item.hasDesktopWindow ? "Close \(item.name) on Mac" : "Remove \(item.name)")
        }
    }

    @ViewBuilder private func thumbnail(_ item: ClaudePreviewItem) -> some View {
        if let b64 = item.thumb, let data = Data(base64Encoded: b64), let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: item.isPDF ? "doc.richtext" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
