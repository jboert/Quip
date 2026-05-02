import SwiftUI

struct ConnectionStatusBar: View {
    var isConnected: Bool
    var macName: String = "Mac"
    var onConnect: ((String) -> Void)? = nil
    /// Tap on the status label opens the multi-backend picker. Nil disables
    /// the gesture (legacy single-backend builds).
    var onTapStatus: (() -> Void)? = nil
    /// Hint shown next to "Connected to X" — e.g. "2 paired" — so the user
    /// knows tapping the row leads to a switcher rather than just a label.
    var pairedHint: String? = nil

    @State private var manualIP: String = ""
    @State private var dotPulse: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }

    var body: some View {
        VStack(spacing: 6) {
            // Status row
            statusRow
                .contentShape(Rectangle())
                .onTapGesture { onTapStatus?() }

            // Always show IP entry when disconnected
            disconnectedEntry
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.6))
        .onAppear { dotPulse = true }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? colors.statusConnected : colors.statusDisconnected)
                .frame(width: 8, height: 8)
            Text(isConnected ? "Connected to \(macName)" : "Not connected")
                .font(.caption.weight(.medium))
                .foregroundStyle(isConnected ? colors.textPrimary.opacity(0.9) : colors.textSecondary)
            if let hint = pairedHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(colors.textSecondary)
            }
            Spacer()
            if onTapStatus != nil {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(colors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var disconnectedEntry: some View {
        if !isConnected {
            HStack(spacing: 8) {
                TextField("192.168.x.x:8765", text: $manualIP)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(colors.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.go)
                    .onSubmit { doConnect() }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button { doConnect() } label: {
                    Text("Connect")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(manualIP.isEmpty ? colors.surface : colors.buttonPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(manualIP.isEmpty)
            }
        }
    }

    private func doConnect() {
        guard !manualIP.isEmpty else { return }
        onConnect?(manualIP)
    }
}
