import SwiftUI
import UIKit

/// Swatches for the card menu's Color strip: a filled circle rendered as an
/// original-mode image, because a menu draws SF Symbols in its own text color
/// and would show ten identical grey dots. Names double as the VoiceOver
/// labels; a hex string read aloud helps nobody.
enum WindowColorSwatch {
    static let names: [String: String] = [
        "#F5A623": "Orange", "#4A90D9": "Blue", "#7ED321": "Green", "#D0021B": "Red",
        "#9013FE": "Purple", "#50E3C2": "Teal", "#BD10E0": "Magenta", "#B8E986": "Lime",
        "#F8E71C": "Yellow", "#FF6B6B": "Coral",
    ]

    static func name(for hex: String) -> String {
        names[WindowColor.normalized(hex) ?? hex] ?? hex
    }

    /// A 22 pt circle in `hex`; `selected` adds a check mark in a contrasting
    /// color so the current choice is visible in the strip.
    static func image(hex: String, selected: Bool) -> UIImage {
        let size = CGSize(width: 22, height: 22)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(Color(hex: hex)).setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
            if selected {
                let check = UIImage(systemName: "checkmark",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))?
                    .withTintColor(KeyColors.prefersDarkText(on: hex) ? .black : .white, renderingMode: .alwaysOriginal)
                if let check {
                    let rect = CGRect(x: (size.width - check.size.width) / 2, y: (size.height - check.size.height) / 2,
                                      width: check.size.width, height: check.size.height)
                    check.draw(in: rect)
                }
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
