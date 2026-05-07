import SwiftUI

/// Two-mode picker for the QA-mode pair. Driven by the long-press entry
/// point in `ContextMenuView` — the long-pressed window IS one half, and
/// the sheet picks the other half.
///
/// Filtering uses `WindowState.isTarget` / `WindowState.isTerminal` (see
/// `Models/WindowState+QAMode.swift`) — the same predicates anywhere in
/// the iOS app needs to classify windows for QA mode.
struct QAPairPickerSheet: View {
    enum Mode {
        case target    // pick a target — partner is a known terminal
        case terminal  // pick a terminal — partner is a known target
    }

    let mode: Mode
    let windows: [WindowState]
    let onSelect: (WindowState) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }

    private var filtered: [WindowState] {
        switch mode {
        case .target:
            return windows.filter(\.isTarget)
        case .terminal:
            return windows.filter(\.isTerminal)
        }
    }

    private var title: String {
        switch mode {
        case .target:   return "Pick Simulator"
        case .terminal: return "Pick terminal"
        }
    }

    private var emptyMessage: String {
        switch mode {
        case .target:   return "No Simulators detected.\nOpen Xcode → Run on a Simulator."
        case .terminal: return "No terminals detected.\nOpen iTerm2 or Terminal."
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(colors.textFaint)
                        Text(emptyMessage)
                            .font(.subheadline)
                            .foregroundStyle(colors.textFaint)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { w in
                        Button {
                            onSelect(w)
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color(hex: w.color))
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(w.folder?.isEmpty == false ? w.folder! : w.app)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(colors.textPrimary)
                                    Text(w.folder?.isEmpty == false ? w.app : w.name)
                                        .font(.caption2)
                                        .foregroundStyle(colors.textTertiary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
