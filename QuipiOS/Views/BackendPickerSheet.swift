import SwiftUI

/// Multi-backend switcher. Lists every paired backend with a reachability
/// hint, lets the user tap to switch, swipe-to-forget, or open the existing
/// add-by-URL/Bonjour flow via "Add backend".
///
/// Cold-switch model for v1: tapping a row calls `manager.setActive(_:)` which
/// disconnects the placeholder client and reconnects to the new URL.
/// Reconnect is sub-2s on LAN. The Hot model — all paired backends live, swap
/// is sub-frame — is a follow-up that requires moving QuipApp's @State into
/// per-`BackendSession` slices.
struct BackendPickerSheet: View {
    @Bindable var manager: BackendConnectionManager
    /// Live connection flag — when the active row is the connected one we
    /// show a green dot, anything else is a neutral grey since we don't
    /// (yet) probe inactive backends in v1's cold-switch model.
    var isActiveConnected: Bool
    @Binding var isPresented: Bool
    /// Tapped "Add backend". Host pops the existing connect-by-URL UI.
    var onAdd: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(manager.paired) { backend in
                        row(backend)
                    }
                    .onDelete { indices in
                        for i in indices {
                            let id = manager.paired[i].id
                            manager.forget(id)
                        }
                    }
                }

                Section {
                    Button {
                        isPresented = false
                        onAdd()
                    } label: {
                        Label("Add backend", systemImage: "plus.circle.fill")
                    }
                    .disabled(manager.paired.count >= BackendConnectionManager.maxPairedBackends)

                    if manager.paired.count >= BackendConnectionManager.maxPairedBackends {
                        Text("Limit reached — forget a backend to add another.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Backends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ backend: PairedBackend) -> some View {
        let isActive = backend.id == manager.activeBackendID
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor(isActive: isActive, enabled: backend.enabled))
                .frame(width: 8, height: 8)
            Button {
                if !isActive {
                    manager.setActive(backend.id)
                }
                isPresented = false
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backend.name.isEmpty ? "Backend" : backend.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(backend.enabled ? .primary : .secondary)
                        Text(backend.url)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Auto-connect toggle — gated behind a button so a stray tap on
            // the row body doesn't disable the only live backend. Bolt icon
            // matches the "live socket" mental model.
            Button {
                manager.setEnabled(backend.id, !backend.enabled)
            } label: {
                Image(systemName: backend.enabled ? "bolt.fill" : "bolt.slash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(backend.enabled ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(backend.enabled ? "Disconnect" : "Connect")
        }
    }

    private func dotColor(isActive: Bool, enabled: Bool) -> Color {
        if !enabled { return .secondary.opacity(0.25) }
        if isActive { return isActiveConnected ? colors.statusConnected : .yellow }
        return .secondary.opacity(0.4)
    }
}
