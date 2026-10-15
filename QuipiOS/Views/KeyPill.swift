import SwiftUI
import UIKit

/// The face of one keyboard-row pill (Q-50, US-203), shared by the row, the
/// Quick Buttons editor and the custom-button form so all three draw a
/// button the same way. What it shows comes from `KeyPillSpec`; the caller
/// keeps the Button, its action and its accessibility.
struct KeyPill: View {
    let spec: KeyPillSpec
    var enabled: Bool = true
    /// The editor's rows give icon and text pills a fixed height.
    var minHeight: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme
    private var colors: QuipColors { QuipColors(scheme: colorScheme) }

    var body: some View {
        label
            .foregroundStyle(textColor)
            .background(fillColor)
            .clipShape(RoundedRectangle(cornerRadius: spec.isPrompt ? 6 : 5))
    }

    @ViewBuilder
    private var label: some View {
        switch spec.content {
        case .icon(let symbol):
            // The stable id per symbol is what keeps the icon from
            // intermittently disappearing (see `quickActionButton`).
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
                .id("key-icon-\(symbol)")
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .frame(minWidth: 20, minHeight: minHeight)
        case .text(let text):
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .frame(minWidth: 20, minHeight: minHeight)
        case .iconAndLabel(let symbol, let text) where spec.isPrompt:
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .id("key-icon-\(symbol)")
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        case .iconAndLabel(let symbol, let text):
            // The label keeps the row's 9 pt type: larger key labels read
            // as "too zoomed in" on the phone (Q-62).
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .id("key-icon-\(symbol)")
                Text(text)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .frame(minWidth: 20, minHeight: minHeight)
        }
    }

    private var fillColor: Color {
        if spec.isPrompt && !enabled { return Color.gray.opacity(0.25) }
        switch spec.fill {
        case .user(let hex): return Color(hex: hex).opacity(enabled ? 1 : 0.4)
        case .hue(let hue): return KeyTint.defaultFill(hue, scheme: colorScheme).opacity(enabled ? 1 : 0.4)
        case .neutral: return colors.chipFill
        case .prompt: return KeyTint.promptFill
        }
    }

    private var textColor: Color {
        if spec.isPrompt { return enabled ? KeyTint.text(userHex, default: .white) : .white }
        let base: Color = switch spec.fill {
        case .user(let hex): KeyTint.text(hex, default: .white)
        case .hue, .prompt: .white
        case .neutral: colors.chipText
        }
        return base.opacity(enabled ? 1 : 0.4)
    }

    private var userHex: String? {
        if case .user(let hex) = spec.fill { return hex }
        return nil
    }
}

enum KeySymbol {
    /// Whether iOS draws an SF Symbol of this name. A misspelled name drew
    /// an empty pill before Q-50.
    static func exists(_ name: String) -> Bool {
        UIImage(systemName: name) != nil
    }
}

extension KeyHue {
    /// The hue as an icon color on a list row (Add Button). The system colors
    /// adapt to the appearance; the pill fills are too dark for a dark row.
    var iconColor: Color {
        switch self {
        case .green: return .green
        case .red: return .red
        case .orange: return .orange
        case .blue: return .blue
        case .teal: return .teal
        case .indigo: return .indigo
        case .pink: return .pink
        case .gray: return .gray
        case .purple: return .purple
        }
    }
}
