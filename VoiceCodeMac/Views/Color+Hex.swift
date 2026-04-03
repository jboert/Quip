// Color+Hex.swift
// VoiceCodeMac — Hex color parsing for NSColor and SwiftUI Color

import AppKit
import SwiftUI

// MARK: - NSColor Hex Extension

extension NSColor {
    /// Create an NSColor from a hex string (e.g. "#F5A623" or "F5A623")
    convenience init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&rgb)

        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0

        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - SwiftUI Color Hex Extension

extension Color {
    /// Create a Color from a hex string (e.g. "#F5A623" or "F5A623")
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }
}
