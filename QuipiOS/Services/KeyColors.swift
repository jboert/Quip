import Foundation

/// Colors the user gave keyboard buttons (the quick-button row), keyed by
/// `QuickSlot.id`: `b:<button>` for a built-in, `c:<uuid>` for a custom
/// button, `p:<prompt id>` for a prompt, `pp` for the Prompts picker.
///
/// Stored on the phone in `@AppStorage("quickSlotColorsJSON")` as a JSON
/// object of `#RRGGBB` strings, and backed up to the Mac with the rest of the
/// phone's preferences. A button with no entry keeps its normal look. Keyed
/// by slot id, so a reordered button keeps its color, and a custom button
/// that is deleted and made again starts plain (it gets a new id).
enum KeyColors {
    static let storageKey = "quickSlotColorsJSON"

    /// The stored map. Anything unreadable, and any value that is not a hex
    /// color, is dropped rather than failing the whole row.
    static func decode(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return raw.compactMapValues(WindowColor.normalized)
    }

    static func encode(_ colors: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(colors),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// `colors` with `slotID` set to `hex`, or cleared when `hex` is nil. A
    /// value that is not a hex color leaves the map unchanged.
    static func setting(_ hex: String?, for slotID: String, in colors: [String: String]) -> [String: String] {
        var result = colors
        if let hex {
            guard let color = WindowColor.normalized(hex) else { return colors }
            result[slotID] = color
        } else {
            result.removeValue(forKey: slotID)
        }
        return result
    }

    /// Whether a label on `hex` reads better in black than in white: the
    /// choice with the higher WCAG contrast ratio. Yellow and pale green get
    /// black text; blue, red and purple get white.
    static func prefersDarkText(on hex: String) -> Bool {
        guard let color = WindowColor.normalized(hex),
              let value = Int(color.dropFirst(), radix: 16) else { return false }
        func linear(_ byte: Int) -> Double {
            let c = Double(byte) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((value >> 16) & 0xFF)
            + 0.7152 * linear((value >> 8) & 0xFF)
            + 0.0722 * linear(value & 0xFF)
        let againstBlack = (luminance + 0.05) / 0.05
        let againstWhite = 1.05 / (luminance + 0.05)
        return againstBlack > againstWhite
    }
}
