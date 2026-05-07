import SwiftUI

/// Side-by-side QA layout. Renders the two paired windows in a 50/50 split
/// (or whatever the user has dragged the divider to within 30/70 .. 70/30).
/// Tap a pane to select; horizontal swipe across the divider flips the
/// selection.
///
/// Header chip exposes pair names, re-pair (tap chip), and exit (✕).
/// Bottom input bar mirrors the existing input affordance with an extra
/// chevron-down minimize button so the user can reclaim full pane height.
struct QAPairLayoutView: View {
    let target: WindowState
    let terminal: WindowState
    @Binding var selectedWindowId: String?
    let backendId: String
    var onSendText: (String) -> Void
    var onExit: () -> Void
    var onRePair: () -> Void

    @AppStorage private var dividerRatio: Double
    @State private var positionSwapped: Bool
    @State private var draftText: String = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }

    init(target: WindowState, terminal: WindowState,
         selectedWindowId: Binding<String?>,
         backendId: String,
         onSendText: @escaping (String) -> Void,
         onExit: @escaping () -> Void,
         onRePair: @escaping () -> Void) {
        self.target = target
        self.terminal = terminal
        self._selectedWindowId = selectedWindowId
        self.backendId = backendId
        self._dividerRatio = AppStorage(wrappedValue: 0.5,
                                        "qaPair.dividerRatio.\(backendId)")
        self.onSendText = onSendText
        self.onExit = onExit
        self.onRePair = onRePair
        let key = BackendSession.swapKey(forBackendId: backendId)
        self._positionSwapped = State(initialValue: UserDefaults.standard.bool(forKey: key))
    }

    private var selectedIsTarget: Bool { selectedWindowId == target.id }
    private var selectedIsReadOnly: Bool { selectedIsTarget }  // v1 — Sim is read-only

    var body: some View {
        VStack(spacing: 0) {
            headerChip

            GeometryReader { geo in
                let dividerW: CGFloat = 4
                let leftW = max(geo.size.width * 0.30,
                                min(geo.size.width * 0.70,
                                    geo.size.width * dividerRatio))
                let leftWindow: WindowState  = positionSwapped ? target    : terminal
                let rightWindow: WindowState = positionSwapped ? terminal  : target
                HStack(spacing: 0) {
                    pane(window: leftWindow, width: leftW)
                    divider(totalWidth: geo.size.width, height: geo.size.height)
                        .frame(width: dividerW)
                    pane(window: rightWindow, width: geo.size.width - leftW - dividerW)
                }
                .gesture(swipeFlipGesture)
            }

            inputBar
        }
        .background(colors.background)
        .onTapGesture { inputFocused = false }  // tap-outside dismiss
    }

    // MARK: - Header chip

    private var headerChip: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: target.color)).frame(width: 8, height: 8)
            Text(target.folder?.isEmpty == false ? target.folder! : target.app)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(hex: target.color))
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption2)
                .foregroundStyle(colors.textTertiary)
            Text(terminal.folder?.isEmpty == false ? terminal.folder! : terminal.app)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(hex: terminal.color))

            Spacer()

            Button {
                withAnimation(.spring(duration: 0.2, bounce: 0.15)) {
                    positionSwapped.toggle()
                }
                let key = BackendSession.swapKey(forBackendId: backendId)
                UserDefaults.standard.set(positionSwapped, forKey: key)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.textTertiary)
            }
            .accessibilityLabel("Swap pane positions")

            Button { onRePair() } label: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.textTertiary)
            }

            Button { onExit() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(colors.surface.opacity(0.5))
    }

    // MARK: - Pane

    private func pane(window: WindowState, width: CGFloat) -> some View {
        let isSelected = selectedWindowId == window.id
        return WindowRectangle(
            window: window,
            isSelected: isSelected,
            onSelect: {
                withAnimation(.spring(duration: 0.2, bounce: 0.15)) {
                    selectedWindowId = window.id
                }
            },
            onAction: { _ in /* QA pane suppresses per-window actions */ }
        )
        .frame(width: max(0, width))
        .padding(8)
    }

    // MARK: - Divider

    private func divider(totalWidth: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(colors.divider)
            .frame(height: height)
            .contentShape(Rectangle().inset(by: -3))  // 10pt total hit zone
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let proposed = dividerRatio + Double(value.translation.width / totalWidth)
                        dividerRatio = max(0.30, min(0.70, proposed))
                    }
                    .onEnded { _ in
                        // Snap to nearest of [0.30, 0.50, 0.70] for tactile feel.
                        let snaps = [0.30, 0.50, 0.70]
                        if let nearest = snaps.min(by: { abs($0 - dividerRatio) < abs($1 - dividerRatio) }) {
                            withAnimation(.spring(duration: 0.18, bounce: 0.1)) {
                                dividerRatio = nearest
                            }
                        }
                    }
            )
    }

    // MARK: - Swipe-to-flip selection

    private var swipeFlipGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) >= 40, abs(dx) >= abs(dy) * 2 else { return }
                let next: String = (selectedWindowId == target.id) ? terminal.id : target.id
                withAnimation(.spring(duration: 0.18, bounce: 0.15)) {
                    selectedWindowId = next
                }
            }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                inputFocused = false
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(colors.textTertiary)
            }

            TextField("Type to selected", text: $draftText)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .padding(8)
                .background(colors.surface.opacity(0.5))
                .cornerRadius(8)
                .disabled(selectedIsReadOnly)

            Button {
                guard !draftText.isEmpty, !selectedIsReadOnly else { return }
                onSendText(draftText)
                draftText = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(
                        (draftText.isEmpty || selectedIsReadOnly)
                            ? colors.textFaint
                            : Color.accentColor
                    )
            }
            .disabled(draftText.isEmpty || selectedIsReadOnly)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(colors.surface.opacity(0.5))
        .overlay(alignment: .top) {
            if selectedIsReadOnly {
                Text("Read-only — switch to terminal to type")
                    .font(.caption2)
                    .foregroundStyle(colors.textTertiary)
                    .padding(.top, -16)
            }
        }
    }
}
