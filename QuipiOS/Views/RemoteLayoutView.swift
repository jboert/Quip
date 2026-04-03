import SwiftUI

struct RemoteLayoutView: View {
    @Binding var windows: [WindowState]
    @Binding var selectedWindowId: String?
    var isConnected: Bool
    var macName: String = "Mac"
    var onConnect: ((String) -> Void)? = nil
    var onWindowAction: ((String, WindowAction) -> Void)? = nil

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.06, blue: 0.08),
                    Color(red: 0.10, green: 0.10, blue: 0.12),
                    Color(red: 0.07, green: 0.07, blue: 0.09),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Connection status bar
                ConnectionStatusBar(
                    isConnected: isConnected,
                    macName: macName,
                    onConnect: onConnect
                )

                // Window layout area — takes all available space
                layoutArea
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)

                // Selected window indicator at bottom
                if let selected = windows.first(where: { $0.id == selectedWindowId }) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: selected.color))
                            .frame(width: 8, height: 8)
                        Text(selected.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(selected.app)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Layout Area

    private var layoutArea: some View {
        GeometryReader { geometry in
            let layoutSize = geometry.size

            ZStack {
                // Subtle background
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.02))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.white.opacity(0.04), lineWidth: 0.5)
                    )

                if windows.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.white.opacity(0.15))
                        Text(isConnected ? "No windows detected" : "Connect to see windows")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.25))
                    }
                } else {
                    ForEach(windows) { window in
                        let rect = windowRect(
                            frame: window.frame,
                            in: layoutSize,
                            inset: 8
                        )

                        WindowRectangle(
                            window: window,
                            isSelected: window.id == selectedWindowId,
                            onSelect: {
                                withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                                    selectedWindowId = window.id
                                }
                            },
                            onAction: { action in
                                onWindowAction?(window.id, action)
                            }
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
        }
    }

    private func windowRect(frame: WindowFrame, in size: CGSize, inset: CGFloat) -> CGRect {
        let usable = CGSize(
            width: size.width - inset * 2,
            height: size.height - inset * 2
        )
        return CGRect(
            x: inset + frame.x * usable.width,
            y: inset + frame.y * usable.height,
            width: frame.width * usable.width,
            height: frame.height * usable.height
        )
    }
}
