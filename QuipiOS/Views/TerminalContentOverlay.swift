import SwiftUI

struct TerminalContentOverlay: View {
    let content: String
    let screenshot: String?
    let windowName: String
    var onDismiss: () -> Void
    var onRefresh: () -> Void
    var onSendAction: (String) -> Void
    // Sends literal text (e.g. "/plan ") to the target window via SendTextMessage
    // on the parent side. Used by buttons that type characters rather than fire a
    // named quick-action keystroke.
    var onSendText: (String) -> Void
    @Environment(\.quipColors) private var colors

    let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            colors.overlayBackground
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(windowName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                    Spacer()
                    Button { onRefresh() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                    .padding(.trailing, 8)
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06))

                // Content — prefer screenshot, fall back to text
                ScrollViewReader { proxy in
                    ScrollView {
                        if let screenshot, let imageData = Data(base64Encoded: screenshot),
                           let uiImage = UIImage(data: imageData) {
                            // Landscape gets a bit more padding than portrait —
                            // the overlay has more horizontal room, and the
                            // screenshot renders huge without some margin.
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 48)
                                .id("bottom")
                        } else {
                            Text(content)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .textSelection(.enabled)
                                .id("bottom")
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                // Keyboard action buttons
                HStack(spacing: 6) {
                    keyButton("Return", icon: "return") { onSendAction("press_return") }
                    keyButton("⌫", icon: "delete.left") { onSendAction("press_backspace") }
                    keyButton("Ctrl+C", icon: "xmark.octagon") { onSendAction("press_ctrl_c") }
                    keyButton("Ctrl+D", icon: "eject") { onSendAction("press_ctrl_d") }
                    keyButton("Esc", icon: "escape") { onSendAction("press_escape") }
                    keyButton("Tab", icon: "arrow.right.to.line") { onSendAction("press_tab") }
                    keyButton("/plan", icon: nil) { onSendText("/plan ") }
                    keyButton("/btw", icon: nil) { onSendText("/btw ") }
                    keyButton("Y", icon: nil) { onSendAction("press_y") }
                    keyButton("N", icon: nil) { onSendAction("press_n") }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
            }
            .background(colors.overlayContainer)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(8)
        }
        .onReceive(refreshTimer) { _ in
            onRefresh()
        }
    }

    private func keyButton(_ label: String, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                }
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}
