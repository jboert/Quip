import SwiftUI
import UIKit

/// Pick a color: the shared palette as swatches, a custom picker, and a
/// reset. Used for window colors (card long-press → "Color…") and keyboard
/// button colors (Quick Buttons editor).
///
/// A swatch applies and closes. The custom picker reports once the color stops
/// changing, so dragging across the wheel does not fire a choice per frame
/// (for windows, each choice is a `set_color` message to the Mac). A custom
/// color still waiting out that pause is reported when the sheet closes.
struct ColorChoiceSheet: View {
    let title: String
    /// The color in use now, `#RRGGBB`; nil when the item has none of its own.
    let current: String?
    let resetLabel: String
    /// The chosen color, or nil for reset.
    let onChoose: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var custom: Color
    @State private var pendingSend: Task<Void, Never>?
    /// The custom color waiting out the pause, sent at once if the sheet
    /// closes first.
    @State private var pendingHex: String?

    init(title: String, current: String?, resetLabel: String = "Reset to automatic",
         onChoose: @escaping (String?) -> Void) {
        self.title = title
        self.current = current.flatMap(WindowColor.normalized)
        self.resetLabel = resetLabel
        self.onChoose = onChoose
        _custom = State(initialValue: current.map { Color(hex: $0) } ?? .gray)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                    ForEach(WindowColor.palette, id: \.self) { hex in
                        Button {
                            choose(hex)
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 40, height: 40)
                                .overlay {
                                    if current == hex {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(KeyColors.prefersDarkText(on: hex) ? .black : .white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Color \(hex)")
                        .accessibilityAddTraits(current == hex ? .isSelected : [])
                    }
                }

                ColorPicker("Custom color", selection: $custom, supportsOpacity: false)
                    .onChange(of: custom) { _, color in
                        sendSoon(Self.hex(of: color))
                    }

                Button(resetLabel) {
                    choose(nil)
                }
                .font(.subheadline)
            }
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(320)])
        .onDisappear {
            pendingSend?.cancel()
            if let hex = pendingHex { onChoose(hex) }
        }
    }

    private func choose(_ hex: String?) {
        pendingSend?.cancel()
        pendingHex = nil
        onChoose(hex)
        dismiss()
    }

    private func sendSoon(_ hex: String) {
        guard hex != current else { return }
        pendingSend?.cancel()
        pendingHex = hex
        pendingSend = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            pendingHex = nil
            onChoose(hex)
        }
    }

    private static func hex(of color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return WindowColor.hex(red: Double(red), green: Double(green), blue: Double(blue))
    }
}

/// How a keyboard button draws the color the user gave it (see `KeyColors`):
/// the color as its fill, and black or white text, whichever reads better.
/// A button with no color keeps its normal look.
enum KeyTint {
    static func fill(_ hex: String?, default fallback: Color) -> Color {
        hex.map { Color(hex: $0) } ?? fallback
    }

    static func text(_ hex: String?, default fallback: Color) -> Color {
        guard let hex else { return fallback }
        return KeyColors.prefersDarkText(on: hex) ? .black : .white
    }
}
