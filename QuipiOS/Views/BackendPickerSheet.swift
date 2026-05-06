import SwiftUI

/// Multi-backend switcher. Lists every paired backend with a reachability
/// hint, lets the user tap to switch, swipe-to-forget, or open the existing
/// add-by-URL/Bonjour flow via "Add backend".
///
/// Hot model: every paired backend has its own live `BackendSession` with
/// `client` + `reachability` — switching active is just an `activeBackendID`
/// pointer flip. The picker reads each session's `reachability` directly so
/// every row shows its current live status (`.connected` / `.connecting` /
/// `.unreachable` / `.needsAuth`), not a stale "active vs grey" binary.
struct BackendPickerSheet: View {
    @Bindable var manager: BackendConnectionManager
    /// Retained for source-compat with the cold-switch v1 caller; ignored
    /// now that per-session reachability is read directly. Remove once
    /// every call site stops passing it.
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
        let session = manager.sessions[backend.id]
        let status = Self.classification(enabled: backend.enabled,
                                          reachability: session?.reachability)
        HStack(spacing: 10) {
            Circle()
                .fill(status.dot(colors: colors))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
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
                        // GH H+G: row caption shows live status above the URL,
                        // not just the URL — answers "is this one connected
                        // right now?" without flipping to it.
                        HStack(spacing: 6) {
                            Text(status.caption)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(status.captionTint(colors: colors))
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(backend.url)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(backend.name.isEmpty ? "Backend" : backend.name), \(status.caption)")
            .accessibilityHint(isActive ? "Currently selected" : "Tap to switch to this backend")

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

    /// Live row state, derived from the user's `enabled` toggle + the
    /// session's actual `Reachability`. Pure mapping so it can be tested
    /// without standing up a full `BackendConnectionManager`. (GH G.)
    enum RowStatus: String, CaseIterable {
        case off            // bolt.slash — user disabled auto-connect
        case unknown        // enabled but no session yet (just paired)
        case connecting
        case connected
        case needsAuth
        case unreachable

        var caption: String {
            switch self {
            case .off:         return "Off"
            case .unknown:     return "Unknown"
            case .connecting:  return "Connecting…"
            case .connected:   return "Connected"
            case .needsAuth:   return "PIN required"
            case .unreachable: return "Unreachable"
            }
        }

        func dot(colors: QuipColors) -> Color {
            switch self {
            case .off:         return .secondary.opacity(0.25)
            case .unknown:     return .secondary.opacity(0.4)
            case .connecting:  return .yellow
            case .connected:   return colors.statusConnected
            case .needsAuth:   return .orange
            case .unreachable: return .red.opacity(0.7)
            }
        }

        func captionTint(colors: QuipColors) -> Color {
            switch self {
            case .off:         return .secondary
            case .unknown:     return .secondary
            case .connecting:  return .orange
            case .connected:   return colors.statusConnected
            case .needsAuth:   return .orange
            case .unreachable: return .red.opacity(0.85)
            }
        }
    }

    /// Pure classification helper. Static so the unit tests don't need
    /// to construct a `BackendPickerSheet` view.
    static func classification(enabled: Bool, reachability: BackendSession.Reachability?) -> RowStatus {
        guard enabled else { return .off }
        guard let r = reachability else { return .unknown }
        switch r {
        case .connecting:  return .connecting
        case .connected:   return .connected
        case .unreachable: return .unreachable
        case .needsAuth:   return .needsAuth
        }
    }
}
