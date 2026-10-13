import SwiftUI

/// "Send to…" from a keyboard button's hold menu (Q-51): pick a terminal and
/// the button's action goes there; the selected window stays selected.
struct SendToWindowSheet: View {
    let title: String
    let action: QuickSend
    let targets: [SendToTargets.Target]
    let onSend: (_ windowID: String, _ action: QuickSend) -> Void
    @Environment(\.dismiss) private var dismiss
    /// On by default: the window is out of sight, so typed-only text would
    /// sit there unsent.
    @State private var pressReturn = true

    var body: some View {
        NavigationStack {
            List {
                if action.offersReturnChoice {
                    Section {
                        Toggle("Press Return", isOn: $pressReturn)
                    } footer: {
                        Text(pressReturn ? "Sends it, then presses Return." : "Types it there; you press Return later.")
                    }
                }
                Section {
                    if targets.isEmpty {
                        Text("No terminal windows").foregroundStyle(.secondary)
                    }
                    ForEach(targets) { target in
                        Button {
                            onSend(target.id, action.pressingReturn(pressReturn))
                            dismiss()
                        } label: {
                            row(target)
                        }
                        // Plain, so the row reads as text, not a blue link.
                        .buttonStyle(.plain)
                        .accessibilityLabel(target.isCurrent ? "\(target.title), current window" : target.title)
                    }
                }
            }
            .navigationTitle("Send \(title) to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ target: SendToTargets.Target) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: target.color))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(target.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if target.isCurrent {
                Text("Current")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .contentShape(Rectangle())
    }
}
