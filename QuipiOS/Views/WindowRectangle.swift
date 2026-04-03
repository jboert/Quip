import SwiftUI

struct WindowRectangle: View {
    let window: WindowState
    let isSelected: Bool
    var onSelect: () -> Void = {}
    var onAction: ((WindowAction) -> Void)? = nil

    @State private var pulsePhase: Bool = false

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
            return pulsePhase ? 16 : 8
        case "waiting_for_input":
            return pulsePhase ? 10 : 4
        default:
            return isSelected ? 8 : 0
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

            // Labels
            VStack(alignment: .leading, spacing: 3) {
                Text(window.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                Text(window.app)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(10)

            // Disabled overlay
            if !window.enabled {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.5))
                    .overlay {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
        .shadow(color: glowColor, radius: glowRadius)
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: isSelected)
        .animation(
            window.state == "waiting_for_input" || window.state == "stt_active"
                ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                : .default,
            value: pulsePhase
        )
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button {
                onAction?(.pressReturn)
            } label: {
                Label("Press Return", systemImage: "return")
            }

            Button {
                onAction?(.cancel)
            } label: {
                Label("Cancel (Ctrl+C)", systemImage: "xmark.octagon")
            }

            Button {
                onAction?(.clearTerminal)
            } label: {
                Label("Clear Terminal", systemImage: "trash")
            }

            Button {
                onAction?(.restartClaude)
            } label: {
                Label("Restart Claude", systemImage: "arrow.clockwise")
            }

            Divider()

            Button {
                onAction?(.toggleEnabled)
            } label: {
                Label(
                    window.enabled ? "Disable Window" : "Enable Window",
                    systemImage: window.enabled ? "eye.slash" : "eye"
                )
            }
        }
        .onAppear {
            if window.state == "waiting_for_input" || window.state == "stt_active" {
                pulsePhase = true
            }
        }
        .onChange(of: window.state) { _, newValue in
            if newValue == "waiting_for_input" || newValue == "stt_active" {
                pulsePhase = true
            } else {
                pulsePhase = false
            }
        }
    }
}

enum WindowAction {
    case pressReturn
    case cancel
    case clearTerminal
    case restartClaude
    case toggleEnabled
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
