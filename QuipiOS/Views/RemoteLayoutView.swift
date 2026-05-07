import SwiftUI

struct RemoteLayoutView: View {
    @Binding var windows: [WindowState]
    @Binding var selectedWindowId: String?
    var isConnected: Bool
    var macName: String = "Mac"
    var onConnect: ((String) -> Void)? = nil
    var onWindowAction: ((String, WindowAction) -> Void)? = nil
    /// Forwarded to ConnectionStatusBar — opens the multi-backend picker.
    var onTapStatus: (() -> Void)? = nil
    var pairedHint: String? = nil
    /// Horizontal swipe on the layout area cycles the active backend.
    /// `direction` is +1 (next) or -1 (previous). Wired to
    /// `BackendConnectionManager.cycleActive(direction:)`.
    var onCycleBackend: ((Int) -> Void)? = nil
    /// QA mode pair (set when the user has paired a target+terminal). When
    /// non-nil and BOTH window IDs are present in `windows`, the layout
    /// switches to side-by-side QA layout instead of the grid.
    var qaPair: QAPair? = nil
    /// Backend identifier used to scope per-backend state (e.g. divider
    /// position) in QA layout. Empty string is acceptable when no QA pair.
    var backendId: String = ""
    /// Send the user's typed text to whichever window is `selectedWindowId`.
    /// Wired to QuipApp's existing `sendText` path.
    var onSendText: (String) -> Void = { _ in }
    /// Tap exit (✕) in QA layout's header chip — clears the pair locally
    /// and on the Mac.
    var onExitQA: () -> Void = {}
    /// Tap header chip (or re-pair button) in QA layout — re-opens the
    /// picker so the user can change one or both halves.
    var onRePairQA: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }
    @State private var swipeOffset: CGFloat = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colors.backgroundGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let pair = qaPair,
               let target = windows.first(where: { $0.id == pair.targetId }),
               let terminal = windows.first(where: { $0.id == pair.terminalId }) {
                QAPairLayoutView(
                    target: target,
                    terminal: terminal,
                    selectedWindowId: $selectedWindowId,
                    backendId: backendId,
                    onSendText: onSendText,
                    onExit: onExitQA,
                    onRePair: onRePairQA
                )
            } else {
                gridLayout
            }
        }
        .environment(\.quipColors, colors)
    }

    /// Existing pre-QA grid — kept exactly as before, just lifted into a
    /// computed view so the body can branch.
    private var gridLayout: some View {
        VStack(spacing: 0) {
            // Connection status bar
            ConnectionStatusBar(
                isConnected: isConnected,
                macName: macName,
                onConnect: onConnect,
                onTapStatus: onTapStatus,
                pairedHint: pairedHint
            )

            // Window layout area — takes all available space.
            // Backend cycle gesture lives here (NOT on the terminal panel,
            // where horizontal swipe is reserved for window cycling).
            // 60pt threshold + 2:1 horizontal-to-vertical ratio prevents
            // accidental triggers from vertical scrolls inside the area.
            layoutArea
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .offset(x: swipeOffset)
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.75),
                           value: swipeOffset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            guard onCycleBackend != nil else { return }
                            let dx = value.translation.width
                            let dy = value.translation.height
                            if abs(dx) < abs(dy) * 2 {
                                if swipeOffset != 0 { swipeOffset = 0 }
                                return
                            }
                            let damped = dx * 0.3
                            swipeOffset = max(-60, min(60, damped))
                        }
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            swipeOffset = 0
                            guard let onCycleBackend,
                                  abs(dx) >= 60,
                                  abs(dx) >= abs(dy) * 2 else { return }
                            onCycleBackend(dx < 0 ? 1 : -1)
                        }
                )

            // Selected window indicator at bottom
            if let selected = windows.first(where: { $0.id == selectedWindowId }) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: selected.color))
                        .frame(width: 8, height: 8)
                    Text(selected.folder?.isEmpty == false ? selected.folder! : selected.app)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(hex: selected.color))
                    Text(selected.folder?.isEmpty == false ? selected.app : selected.name)
                        .font(.caption2)
                        .foregroundStyle(colors.textTertiary)
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Layout Area

    private var layoutArea: some View {
        GeometryReader { geometry in
            let layoutSize = geometry.size

            ZStack {
                // Subtle background
                RoundedRectangle(cornerRadius: 16)
                    .fill(colors.surface.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(colors.surfaceBorder, lineWidth: 0.5)
                    )

                if windows.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(colors.textFaint)
                        Text(isConnected ? "No windows detected" : "Connect to see windows")
                            .font(.subheadline)
                            .foregroundStyle(colors.textFaint)
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
