import SwiftUI

struct ConnectionStatusBar: View {
    var isConnected: Bool
    var macName: String = "Mac"
    var onConnect: ((String) -> Void)? = nil

    @State private var manualIP: String = ""
    @State private var dotPulse: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            // Status row
            HStack(spacing: 8) {
                Circle()
                    .fill(isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text(isConnected ? "Connected to \(macName)" : "Not connected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(isConnected ? 0.9 : 0.5))

                Spacer()
            }

            // Always show IP entry when disconnected
            if !isConnected {
                HStack(spacing: 8) {
                    TextField("192.168.x.x:8765", text: $manualIP)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                        .submitLabel(.go)
                        .onSubmit { doConnect() }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button { doConnect() } label: {
                        Text("Connect")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(manualIP.isEmpty ? Color.white.opacity(0.08) : Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(manualIP.isEmpty)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.6))
        .onAppear { dotPulse = true }
    }

    private func doConnect() {
        guard !manualIP.isEmpty else { return }
        onConnect?(manualIP)
    }
}
