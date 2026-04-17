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
    // Tells the parent to open the image-source picker (camera / library).
    var onAttachImage: () -> Void = {}
    @Environment(\.quipColors) private var colors
    /// Shared pending-image state injected by the parent so the landscape
    /// preview strip reflects the same image as the portrait row.
    @EnvironmentObject private var pendingImage: PendingImageState
    /// Shares the same @AppStorage key as InlineTerminalContent so the
    /// text-size preference carries between orientations.
    @AppStorage("contentZoomLevel") private var contentZoomLevel = 1
    /// Same unified quick-button list as the portrait view — toggle on/off
    /// in Settings → Quick Buttons.
    @AppStorage("enabledQuickButtons") private var enabledQuickButtonsRaw: String = "plan,yes,no,esc,ctrlC"

    /// Text-input state local to landscape so the overlay can stage and
    /// send a typed prompt without pulling in the portrait @Binding.
    @State private var showTextInput = false
    @State private var textInputValue = ""

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
                    Button {
                        contentZoomLevel = ContentZoomLevel.from(raw: contentZoomLevel).next
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                    .padding(.trailing, 8)
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
                            // Landscape is ~2x wider than portrait so the
                            // same widthFraction (tuned for portrait) comes
                            // out way too large. Further shrink by ~60% so
                            // the screenshot's text renders comparably to
                            // portrait at the same zoom level.
                            let zoom = ContentZoomLevel.from(raw: contentZoomLevel)
                            let landscapeShrink: CGFloat = 0.58
                            let maxW = UIScreen.main.bounds.width * zoom.widthFraction * landscapeShrink
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: maxW)
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

                // Pending image thumbnail — only appears when an image is staged.
                PendingImagePreviewStrip(state: pendingImage)

                // Text-input bar — shown when the keyboard button in the
                // keys row is tapped. Sends with pressReturn: false so the
                // text lands in Claude's prompt line rather than submitting.
                if showTextInput {
                    HStack(spacing: 6) {
                        TextField("Type a prompt\u{2026}", text: $textInputValue)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onSubmit { sendTypedText() }

                        Button { sendTypedText() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(textInputValue.isEmpty ? Color.white.opacity(0.3) : Color.blue)
                        }
                        .disabled(textInputValue.isEmpty)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.04))
                }

                // Keyboard action buttons — Return, the keyboard toggle,
                // then the user's enabled quick-buttons list from Settings.
                HStack(spacing: 6) {
                    keyButton("Return", icon: "return") { onSendAction("press_return") }
                    // Keyboard toggle is a *primary* action in landscape
                    // (typed prompts live here), so it gets a chunkier
                    // button and tints when active rather than sitting at
                    // key-sized default.
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showTextInput.toggle()
                            if !showTextInput { textInputValue = "" }
                        }
                    } label: {
                        Image(systemName: showTextInput ? "keyboard.chevron.compact.down" : "keyboard")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(showTextInput ? .white : Color.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(showTextInput ? Color.blue.opacity(0.7) : Color.white.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }

                    // Attach image — mirrors the portrait button; triggers the
                    // shared picker sheet via the parent callback.
                    Button {
                        onAttachImage()
                    } label: {
                        Image(systemName: pendingImage.hasPendingImage ? "photo.fill" : "photo")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(pendingImage.hasPendingImage ? Color.blue : Color.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .accessibilityLabel("Attach image")
                    let quickButtons = QuickButton.decode(enabledQuickButtonsRaw)
                    ForEach(Array(quickButtons.enumerated()), id: \.element.id) { index, button in
                        if index > 0, quickButtons[index - 1].isSlashCommand != button.isSlashCommand {
                            Spacer().frame(width: 10)
                        }
                        keyButton(button.label, icon: button.systemImage) {
                            switch button.action {
                            case .sendText(let text, let pressReturn):
                                if pressReturn {
                                    onSendText(text)
                                    onSendAction("press_return")
                                } else {
                                    onSendText(text)
                                }
                            case .quickAction(let name):
                                onSendAction(name)
                            }
                        }
                    }
                    Spacer(minLength: 0)
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

    private func keyButton(_ label: String?, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                }
                if let label {
                    Text(label)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private func sendTypedText() {
        let text = textInputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSendText(text)
        textInputValue = ""
    }
}
