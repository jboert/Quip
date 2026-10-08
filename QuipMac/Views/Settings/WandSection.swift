// WandSection.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

/// Settings for the sidebar's magic-wand button.
///
/// Its own struct so the four `@AppStorage` keys stay together and out of
/// `GeneralTab`, which already carries a dozen.
struct WandSection: View {
    @AppStorage("wandTargetKinds") private var targetKindsRaw: Int = WandTargetKinds.default.rawValue
    @AppStorage("wandSortModes") private var sortModesRaw: String = WandSortMode.stored(WandSortMode.allCases)
    @AppStorage("wandSortModeIndex") private var sortModeIndex: Int = 0
    @AppStorage("wandOnScreenOnly") private var onScreenOnly: Bool = false

    private var kinds: WandTargetKinds { WandTargetKinds.fromStored(targetKindsRaw) }
    private var rotation: [WandSortMode] { WandSortMode.rotation(fromStored: sortModesRaw) }

    var body: some View {
        Section("Sort button") {
            Text("The wand in the sidebar sorts your windows and switches them on. Each click moves to the next order below. Option-click switches them all off.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Switches on") {
                VStack(alignment: .leading, spacing: 2) {
                    kindToggle("iTerm2", .iterm2)
                    kindToggle("Terminal.app", .terminalApp)
                    kindToggle("Simulators", .simulator)
                    Toggle("Only windows on screen", isOn: $onScreenOnly)
                        .help("A window minimized to the Dock — or parked on another "
                              + "Mission Control Space — is switched off instead of on. "
                              + "macOS has no public way to tell those two apart, so both "
                              + "count as off screen. If nothing of a checked kind is on "
                              + "screen, the wand leaves your selection alone rather than "
                              + "switching everything off.")
                }
            }

            LabeledContent("Orders") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(WandSortMode.allCases) { mode in
                        Toggle(isOn: modeBinding(mode)) {
                            // The mode's own description, rather than a second
                            // caption line per row — the sidebar's tooltip shows
                            // the same text, so they stay in step.
                            Text("\(mode.label) — \(mode.help)")
                        }
                        .disabled(isLastCheckedMode(mode))
                        .help(isLastCheckedMode(mode)
                              ? "The wand has to sort somehow — check another order first." : "")
                    }
                }
            }
        }
    }

    /// The last checked box is DISABLED rather than merely un-storable.
    ///
    /// Unchecking it used to write a raw 0, which `WandTargetKinds.fromStored`
    /// maps back to `.default` — so the write landed, the read undid it, and all
    /// three boxes silently re-checked themselves with no explanation. Making
    /// the empty state unreachable is the honest version of the same rule: the
    /// wand always acts on something, and now you can see why the box will not
    /// turn off.
    private func kindToggle(_ title: String, _ kind: WandTargetKinds) -> some View {
        let isLastChecked = kinds == WandTargetKinds(rawValue: kind.rawValue)
        return Toggle(title, isOn: Binding(
            get: { kinds.contains(kind) },
            set: { on in
                var next = kinds
                if on { next.insert(kind) } else { next.remove(kind) }
                guard !next.isEmpty else { return }
                targetKindsRaw = next.rawValue
            }
        ))
        .disabled(isLastChecked)
        .help(isLastChecked ? "The wand has to switch something on — check another kind first." : "")
    }

    /// Same rule as `kindToggle`: the last checked order cannot be unchecked,
    /// and the row says so, rather than storing an empty rotation that
    /// `WandSortMode.rotation` quietly reads back as the full set.
    private func modeBinding(_ mode: WandSortMode) -> Binding<Bool> {
        Binding(
            get: { rotation.contains(mode) },
            set: { on in
                var next = rotation
                if on {
                    guard !next.contains(mode) else { return }
                    // Keep the canonical order so the rotation is predictable
                    // no matter which order the boxes were ticked in.
                    next = WandSortMode.allCases.filter { next.contains($0) || $0 == mode }
                } else {
                    next.removeAll { $0 == mode }
                }
                guard !next.isEmpty else { return }
                sortModesRaw = WandSortMode.stored(next)
                // The stored index can now point past the end of a shortened
                // rotation. Reset rather than relying on the read-side clamp, so
                // the sidebar caption matches what the next click will do.
                sortModeIndex = 0
            }
        )
    }

    private func isLastCheckedMode(_ mode: WandSortMode) -> Bool {
        rotation == [mode]
    }
}
