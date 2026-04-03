import SwiftUI

/// A standalone context menu panel for windows, intended for use as a sheet
/// or overlay when the built-in `.contextMenu` modifier is not desired.
///
/// The primary context menu is already integrated into `WindowRectangle`
/// via the `.contextMenu` modifier. This view provides an alternative
/// presentation for custom overlay-style menus.
struct ContextMenuView: View {
    let window: WindowState
    var onAction: ((WindowAction) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    private var accentColor: Color {
        Color(hex: window.color)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 1) {
                    Text(window.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(window.app)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer()

                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()
                .background(.white.opacity(0.08))

            // Action rows
            VStack(spacing: 0) {
                contextActionRow(
                    icon: "return",
                    label: "Press Return",
                    action: .pressReturn
                )

                contextActionRow(
                    icon: "xmark.octagon",
                    label: "Cancel (Ctrl+C)",
                    action: .cancel
                )

                contextActionRow(
                    icon: "trash",
                    label: "Clear Terminal",
                    action: .clearTerminal
                )

                contextActionRow(
                    icon: "arrow.clockwise",
                    label: "Restart Claude",
                    action: .restartClaude
                )

                Divider()
                    .background(.white.opacity(0.08))
                    .padding(.vertical, 4)

                contextActionRow(
                    icon: window.enabled ? "eye.slash" : "eye",
                    label: window.enabled ? "Disable Window" : "Enable Window",
                    action: .toggleEnabled,
                    isDestructive: !window.enabled ? false : true
                )
            }
            .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(accentColor.opacity(0.15), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private func contextActionRow(
        icon: String,
        label: String,
        action: WindowAction,
        isDestructive: Bool = false
    ) -> some View {
        Button {
            onAction?(action)
            onDismiss?()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isDestructive ? .red.opacity(0.8) : accentColor.opacity(0.7))
                    .frame(width: 24)

                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(
                        isDestructive ? .red.opacity(0.8) : .white.opacity(0.85)
                    )

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(ContextMenuButtonStyle())
    }
}

private struct ContextMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.white.opacity(0.06)
                    : Color.clear
            )
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        ContextMenuView(
            window: WindowState(
                id: "1",
                name: "Claude Code",
                app: "Terminal",
                enabled: true,
                frame: WindowFrame(x: 0, y: 0, width: 0.5, height: 0.5),
                state: "waiting_for_input",
                color: "#F5A623"
            )
        )
    }
}
