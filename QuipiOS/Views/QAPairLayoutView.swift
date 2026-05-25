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
    @Binding var contentTextById: [String: String]
    @Binding var contentScreenshotById: [String: String]
    @Binding var contentURLsById: [String: [String]]
    let backendId: String
    var onRefresh: () -> Void
    var onSendText: (String) -> Void
    var onExit: () -> Void
    var onRePair: () -> Void

    @AppStorage private var dividerRatio: Double
    @State private var positionSwapped: Bool
    @State private var draftText: String = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }

    init(
        target: WindowState,
        terminal: WindowState,
        selectedWindowId: Binding<String?>,
        contentTextById: Binding<[String: String]>,
        contentScreenshotById: Binding<[String: String]>,
        contentURLsById: Binding<[String: [String]]>,
        backendId: String,
        onRefresh: @escaping () -> Void = {},
        onSendText: @escaping (String) -> Void,
        onExit: @escaping () -> Void,
        onRePair: @escaping () -> Void
    ) {
        self.target = target
        self.terminal = terminal
        self._selectedWindowId = selectedWindowId
        self._contentTextById = contentTextById
        self._contentScreenshotById = contentScreenshotById
        self._contentURLsById = contentURLsById
        self.backendId = backendId
        self._dividerRatio = AppStorage(wrappedValue: 0.5,
                                        "qaPair.dividerRatio.\(backendId)")
        self.onRefresh = onRefresh
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
            Image(systemName: "circle.fill")
                .font(.system(size: 3))
                .foregroundStyle(colors.textTertiary)
            Text(terminal.folder?.isEmpty == false ? terminal.folder! : terminal.app)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(hex: terminal.color))

            Spacer()

            Button {
                let newValue = !positionSwapped
                withAnimation(.spring(duration: 0.2, bounce: 0.15)) {
                    positionSwapped = newValue
                }
                let key = BackendSession.swapKey(forBackendId: backendId)
                UserDefaults.standard.set(newValue, forKey: key)
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
        let text = contentTextById[window.id] ?? ""
        let screenshot = contentScreenshotById[window.id]
        let urls = contentURLsById[window.id] ?? []
        return InlineTerminalContent(
            content: text,
            screenshot: screenshot,
            urls: urls,
            windowName: window.folder?.isEmpty == false ? window.folder! : window.name,
            windowColor: Color(hex: window.color),
            isExpanded: .constant(false),
            onRefresh: { onRefresh() },
            onSendAction: { _, _ in },
            onCycleWindow: nil
        )
        .frame(width: max(0, width))
        .padding(8)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(duration: 0.2, bounce: 0.15)) {
                selectedWindowId = window.id
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WindowAccessibility.qaPaneIdentifier(for: window))
        .accessibilityLabel(WindowAccessibility.qaPaneLabel(for: window))
        .accessibilityValue(WindowAccessibility.value(isSelected: isSelected, isEnabled: window.enabled))
        .accessibilityHint("Double-tap to select this QA pane.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Divider

    private func divider(totalWidth: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(colors.divider)
                .frame(height: height)
            Capsule()
                .fill(colors.textTertiary.opacity(0.5))
                .frame(width: 3, height: 24)
        }
        .contentShape(Rectangle().inset(by: -20))  // ~44pt hit zone (4pt visible + 40pt invisible)
        .highPriorityGesture(  // Win over parent swipeFlipGesture on slow drags.
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let proposed = dividerRatio + Double(value.translation.width / totalWidth)
                    dividerRatio = max(0.30, min(0.70, proposed))
                }
                .onEnded { _ in
                    let snaps = [0.30, 0.50, 0.70]
                    if let nearest = snaps.min(by: { abs($0 - dividerRatio) < abs($1 - dividerRatio) }) {
                        withAnimation(.spring(duration: 0.18, bounce: 0.1)) {
                            dividerRatio = nearest
                        }
                    }
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.spring(duration: 0.18, bounce: 0.1)) {
                dividerRatio = 0.5
            }
        }
        .accessibilityLabel("Pane divider")
        .accessibilityHint("Drag to resize panes; double-tap to reset to 50/50.")
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
