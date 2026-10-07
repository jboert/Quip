import Foundation

/// Window identification colors: the palette both peers offer, and the one hex
/// form the wire carries.
///
/// The Mac hands each new window the next palette color. The user can replace
/// it from the phone (`set_color`); the Mac keeps that choice per window id, so
/// the Mac sidebar and every connected phone draw the same color.
enum WindowColor {
    /// The colors new windows are given in turn, and the swatches the phone
    /// offers first.
    static let palette: [String] = [
        "#F5A623", "#4A90D9", "#7ED321", "#D0021B", "#9013FE",
        "#50E3C2", "#BD10E0", "#B8E986", "#F8E71C", "#FF6B6B"
    ]

    /// `raw` as `#RRGGBB` in upper case, or nil when it is not a 6-digit hex
    /// color. The leading `#` is optional on input; surrounding whitespace is
    /// ignored.
    static func normalized(_ raw: String) -> String? {
        var digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6,
              digits.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) })
        else { return nil }
        return "#" + digits.uppercased()
    }

    /// `#RRGGBB` for color components in 0...1. Out-of-range components (wide
    /// gamut colors from a color picker) are clamped.
    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int {
            guard value.isFinite else { return 0 }
            return Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

/// Phone → Mac: set or clear the color a window is drawn in.
///
/// The Mac owns window colors, as it owns pins, so every peer agrees. `color`
/// is `#RRGGBB`; nil clears the user's choice and gives the window a palette
/// color again. The Mac answers with a fresh `layout_update`.
struct SetColorMessage: Codable, Sendable {
    let type: String
    let windowId: String
    let color: String?

    init(windowId: String, color: String?) {
        self.type = "set_color"
        self.windowId = windowId
        self.color = color
    }
}
