import SwiftUI

struct WindowRectangle: View {
    let window: WindowState
    let isSelected: Bool
    var onSelect: () -> Void = {}
    var onAction: ((WindowAction) -> Void)? = nil

    @State private var spinAngle: Double = 0
    @State private var showCloseConfirmation = false
    @Environment(\.colorScheme) private var colorScheme
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }

    private var windowColor: Color {
        Color(hex: window.color)
    }

    private var borderOpacity: Double {
        isSelected ? 1.0 : 0.5
    }

    private var borderWidth: Double {
        isSelected ? 2.0 : 1.0
    }

    private var glowRadius: Double {
        switch window.state {
        case "stt_active":
            return 12
        case "waiting_for_input":
            return 8
        case _ where window.isThinking:
            return isSelected ? 6 : 3
        default:
            return isSelected ? 6 : 0
        }
    }

    private var glowColor: Color {
        switch window.state {
        case "stt_active":
            return Color(hex: "#D4A017").opacity(0.7)
        case "waiting_for_input":
            return windowColor.opacity(0.5)
        default:
            return windowColor.opacity(0.4)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background fill
            RoundedRectangle(cornerRadius: 12)
                .fill(windowColor.opacity(isSelected ? 0.2 : 0.1))

            // Border
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    windowColor.opacity(borderOpacity),
                    lineWidth: borderWidth
                )

            // Labels and thinking indicator share the top row so labels
            // truncate to make room for the spinning star on narrow windows.
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    // Primary label is the folder/project when known, else the app
                    // name. Rendered in the window's palette color and bold so it
                    // doubles as the visual identifier of the selection.
                    let primary = (window.folder?.isEmpty == false ? window.folder! : window.app)
                    Text(primary)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(windowColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // Secondary label is the app name when we have a distinct
                    // folder above it; otherwise the window title. Keeping the
                    // app name visible when a folder is shown lets users tell
                    // Terminal.app from iTerm2 at a glance.
                    Text(window.folder?.isEmpty == false ? window.app : window.name)
                        .font(.caption2)
                        .foregroundStyle(colors.textSecondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                if window.isThinking && window.enabled {
                    Text("✽")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(windowColor.opacity(0.8))
                        .rotationEffect(.degrees(spinAngle))
                        .fixedSize()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Disabled overlay
            if !window.enabled {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.5))
                    .overlay {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 14))
                            .foregroundStyle(colors.textTertiary)
                    }
            }
        }
        .shadow(color: glowColor, radius: glowRadius)
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: isSelected)
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button {
                triggerAction(.duplicate)
            } label: {
                Label("Duplicate in new window", systemImage: "rectangle.on.rectangle")
            }

            Button {
                triggerAction(.pressReturn)
            } label: {
                Label("Press Return", systemImage: "return")
            }

            Button {
                triggerAction(.cancel)
            } label: {
                Label("Cancel (Ctrl+C)", systemImage: "xmark.octagon")
            }

            Button {
                triggerAction(.viewOutput)
            } label: {
                Label("View Output", systemImage: "text.alignleft")
            }

            Button {
                triggerAction(.clearTerminal)
            } label: {
                Label("Clear Context", systemImage: "eraser")
            }

            Button {
                triggerAction(.restartClaude)
            } label: {
                Label("Restart Claude", systemImage: "arrow.clockwise")
            }

            Divider()

            Button(role: .destructive) {
                showCloseConfirmation = true
            } label: {
                Label("Close terminal\u{2026}", systemImage: "xmark.square")
            }

            Button {
                triggerAction(.toggleEnabled)
            } label: {
                Label(
                    window.enabled ? "Disable Window" : "Enable Window",
                    systemImage: window.enabled ? "eye.slash" : "eye"
                )
            }
        }
        .alert("Close \(window.name)?", isPresented: $showCloseConfirmation) {
            Button("Cancel", role: .cancel) {}
            // "Remove from Phone" is only meaningful when the window is
            // currently being managed — toggling an already-disabled window
            // here would re-enable it, which is the opposite of what the
            // user asked for. On a disabled window (visible via
            // mirror-desktop), only the destructive Close Terminal remains.
            if window.enabled {
                Button("Remove from Phone") {
                    triggerAction(.toggleEnabled)
                }
            }
            Button("Close Terminal", role: .destructive) {
                triggerAction(.closeWindow)
            }
        } message: {
            Text("Remove from Phone keeps the terminal running on your Mac — you just stop driving it from here. Close Terminal kills any running command and can't be undone.")
        }
        .onAppear {
            if window.isThinking {
                startSpin()
            }
        }
        .onChange(of: window.isThinking) { _, thinking in
            if thinking {
                spinAngle = 0
                startSpin()
            } else {
                spinAngle = 0
            }
        }
    }

    private func startSpin() {
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            spinAngle = 360
        }
    }

    // Long-press opens the context menu but doesn't fire onSelect, so picking
    // an item would otherwise hit whichever window the user long-pressed even
    // if a different one was "selected." Route every menu tap through onSelect
    // first so the selection and the action agree.
    private func triggerAction(_ action: WindowAction) {
        onSelect()
        onAction?(action)
    }
}

enum WindowAction {
    case pressReturn
    case cancel
    case viewOutput
    case clearTerminal
    case restartClaude
    case toggleEnabled
    case duplicate
    case closeWindow
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        HStack(spacing: 16) {
            WindowRectangle(
                window: WindowState(
                    id: "1",
                    name: "Claude Code",
                    app: "Terminal",
                    enabled: true,
                    frame: WindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
                    state: "waiting_for_input",
                    color: "#F5A623"
                ),
                isSelected: true
            )
            .frame(width: 160, height: 100)

            WindowRectangle(
                window: WindowState(
                    id: "2",
                    name: "VS Code",
                    app: "Code",
                    enabled: true,
                    frame: WindowFrame(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    state: "neutral",
                    color: "#4A90D9"
                ),
                isSelected: false
            )
            .frame(width: 160, height: 100)
        }
        .padding()
    }
}
