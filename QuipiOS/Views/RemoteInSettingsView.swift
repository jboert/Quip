import SwiftUI

/// Q-88 US-010: Settings → Remote in, for one Mac. Picks the app (a preset or
/// a custom link), the host and the name; shows the link it will open.
struct RemoteInSettingsView: View {
    let backend: PairedBackend
    @State private var draft: RemoteInSettings
    @Environment(\.dismiss) private var dismiss

    init(backend: PairedBackend) {
        self.backend = backend
        _draft = State(initialValue: RemoteInStore.settings(for: backend.id))
    }

    private var berriscopeInstalled: Bool {
        URL(string: "berriscope://").map { UIApplication.shared.canOpenURL($0) } ?? false
    }
    private var defaultHost: String? { RemoteInURLBuilder.defaultHost(urls: backend.urlsInOrder) }
    private var host: String { draft.host ?? defaultHost ?? "" }
    private var name: String { draft.name ?? backend.name }
    private var used: [String] { RemoteInURLBuilder.placeholders(in: draft.template) }
    /// Faults of the template itself block Save; a missing host does not
    /// (Remote in then opens this screen, US-011).
    private var templateError: RemoteInURLBuilder.Failure? { RemoteInURLBuilder.check(draft.template) }

    var body: some View {
        Form {
            Section {
                Picker("App", selection: $draft.preset) {
                    ForEach(RemoteInPreset.choices(berriscopeInstalled: berriscopeInstalled, current: draft.preset)) {
                        Text($0.title).tag($0)
                    }
                }
                if draft.preset == .custom {
                    TextField("myapp://connect?host={host}", text: $draft.customTemplate)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
                if used.contains("host") {
                    LabeledContent("Host") {
                        TextField(defaultHost ?? "Add this Mac's Tailscale name", text: optional($draft.host))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
                if used.contains("name") {
                    LabeledContent("Mac name") {
                        TextField(backend.name, text: optional($draft.name))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                }
            } footer: {
                if let help = draft.preset.help { Text(help) }
            }

            Section {
                preview
            } header: {
                Text("Opens")
            } footer: {
                if draft.preset == .custom {
                    Text("Use {host} and {name} in the link.")
                }
            }
        }
        .navigationTitle("Remote in · \(backend.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    RemoteInStore.save(draft, for: backend.id)
                    dismiss()
                }
                .disabled(templateError != nil)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        switch RemoteInURLBuilder.build(draft.template, host: host, name: name) {
        case .success(let url):
            Text(url.absoluteString)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("remoteInPreview")
        case .failure(let failure):
            Label(Self.message(failure, preset: draft.preset), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(failure == .noHost ? Color.secondary : Color.red)
                .accessibilityIdentifier("remoteInPreview")
        }
    }

    static func message(_ failure: RemoteInURLBuilder.Failure, preset: RemoteInPreset) -> String {
        switch failure {
        case .noHost:
            return preset == .berriscope ? "Add this Mac's name in Berriscope" : "Add this Mac's Tailscale name"
        case .unknownPlaceholder(let p): return "Unknown {\(p)}. Use {host} or {name}."
        case .badURL: return "Not a link. Start with an app's scheme, like vnc://"
        }
    }

    /// Empty text means "use the default", stored as nil.
    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" },
                set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
