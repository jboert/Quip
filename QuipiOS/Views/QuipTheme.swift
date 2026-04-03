import SwiftUI

/// Adaptive color palette that follows the system dark/light appearance.
struct QuipColors {
    let scheme: ColorScheme

    // MARK: - Backgrounds

    var background: Color {
        scheme == .dark
            ? Color(red: 0.07, green: 0.07, blue: 0.09)
            : Color(red: 0.96, green: 0.96, blue: 0.97)
    }

    var backgroundGradient: [Color] {
        scheme == .dark
            ? [Color(red: 0.06, green: 0.06, blue: 0.08),
               Color(red: 0.10, green: 0.10, blue: 0.12),
               Color(red: 0.07, green: 0.07, blue: 0.09)]
            : [Color(red: 0.95, green: 0.95, blue: 0.96),
               Color(red: 0.97, green: 0.97, blue: 0.98),
               Color(red: 0.96, green: 0.96, blue: 0.97)]
    }

    /// Slightly raised surface (cards, input fields)
    var surface: Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.04)
    }

    /// Elevated container (overlays, panels)
    var surfaceElevated: Color {
        scheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.1)
            : .white
    }

    /// Faint container outline
    var surfaceBorder: Color {
        scheme == .dark
            ? Color.white.opacity(0.03)
            : Color.black.opacity(0.06)
    }

    /// Area header / footer tint
    var surfaceHeader: Color {
        scheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    // MARK: - Text

    var textPrimary: Color {
        scheme == .dark ? .white : Color(red: 0.1, green: 0.1, blue: 0.12)
    }

    var textSecondary: Color {
        scheme == .dark
            ? Color.white.opacity(0.6)
            : Color.black.opacity(0.55)
    }

    var textTertiary: Color {
        scheme == .dark
            ? Color.white.opacity(0.35)
            : Color.black.opacity(0.35)
    }

    var textFaint: Color {
        scheme == .dark
            ? Color.white.opacity(0.15)
            : Color.black.opacity(0.2)
    }

    // MARK: - Interactive

    var buttonPrimary: Color { .blue }

    var buttonDisabled: Color {
        scheme == .dark
            ? Color.white.opacity(0.2)
            : Color.black.opacity(0.15)
    }

    var pressedHighlight: Color {
        scheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    // MARK: - Borders & Dividers

    var divider: Color {
        scheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    // MARK: - Status

    var statusConnected: Color { .green }
    var statusDisconnected: Color { .red }
    var statusConnecting: Color { .yellow }
    var recording: Color { Color(red: 0.9, green: 0.65, blue: 0.15) }
    var destructive: Color { Color.red.opacity(0.8) }

    // MARK: - Terminal overlay (always dark — it shows terminal output)

    var overlayBackground: Color { Color.black.opacity(0.85) }
    var overlayContainer: Color { Color(red: 0.08, green: 0.08, blue: 0.1) }
    var overlayText: Color { Color.white.opacity(0.85) }

    // MARK: - Discovered hosts (green tint)

    var discoveredBackground: Color { Color.green.opacity(0.06) }
    var discoveredDot: Color { Color.green.opacity(0.7) }
    var discoveredLabel: Color { Color.green.opacity(0.5) }
}

// MARK: - Environment Integration

private struct QuipColorsKey: EnvironmentKey {
    static let defaultValue = QuipColors(scheme: .dark)
}

extension EnvironmentValues {
    var quipColors: QuipColors {
        get { self[QuipColorsKey.self] }
        set { self[QuipColorsKey.self] = newValue }
    }
}
