// SettingsChrome.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

// MARK: - Sidebar icon tile
//
// SF Symbol in white on a small tinted rounded square — the System Settings
// sidebar idiom. Deliberately restrained (one flat tint, no gradient, no
// shadow) so it reads as native macOS rather than decorative AI filler.
struct SettingsIconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - Copy button with acknowledgment
//
// A copy control that confirms itself. Tap copies the value, then the glyph
// flips to a green checkmark (and the tooltip to "Copied") for ~1.4s before
// reverting. The standard Apple "did that click land?" affordance — no toast,
// no modal, just a quiet self-clearing acknowledgment. Reused everywhere
// Settings offers a one-click copy (connection URLs, PIN) so they all confirm
// the same way.
struct CopyButton: View {
    let value: String
    var help: String = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation(.snappy(duration: 0.2)) { copied = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.easeIn(duration: 0.25)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : help)
        .accessibilityLabel(copied ? "Copied" : help)
    }
}

// MARK: - Sidebar identity header
//
// Anchors the window: this is *Quip*, not a generic preferences shell. The
// app icon + wordmark give the sidebar a focal point, and the version/build
// line relocates the "did my reinstall land" diagnostic out of a buried
// General → About row into the chrome where it's always visible.
struct SettingsIdentityHeader: View {
    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                // App-Store-style lift — the icon reads as a physical tile
                // sitting above the sidebar, not a flat sticker.
                .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Quip")
                    .font(.title3.weight(.semibold))

                // Version, commit and build time from the stamp read once per
                // launch — the "did my reinstall land" diagnostic, without a
                // stat of the binary on every render.
                Text(BuildInfo.display(BuildInfo.current))
                    .foregroundStyle(.secondary)
                    .font(.caption2)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

// MARK: - Shared status vocabulary
//
// One consistent way to render "is it on / granted / set?" across every
// tab. Before this, the same idea showed up three different ways: a Circle
// dot (Connection), a bare SF checkmark (Permissions), or plain colored
// text (Notifications). StatusDot unifies them into a single tinted glyph +
// label so the whole window speaks one language.
struct StatusDot: View {
    enum Kind { case ok, bad, warn, neutral, busy }

    let kind: Kind
    let text: String
    var mono: Bool = false

    private var glyph: String {
        switch kind {
        case .ok:      return "checkmark.circle.fill"
        case .bad:     return "xmark.circle.fill"
        case .warn:    return "exclamationmark.triangle.fill"
        case .neutral: return "circle.fill"
        case .busy:    return "hourglass"
        }
    }

    private var tint: Color {
        switch kind {
        case .ok:      return .green
        case .bad:     return .red
        case .warn:    return .orange
        case .neutral: return .secondary
        case .busy:    return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .foregroundStyle(tint)
                .imageScale(.medium)
            Text(text)
                .font(mono ? .body.monospaced() : .body)
        }
    }
}
