import SwiftUI
import UIKit

/// Pick the color a window is drawn in, from the window card's long-press menu.
///
/// The Mac owns window colors, so a choice is sent as `set_color` and shows up
/// when the Mac re-broadcasts the layout: the Mac sidebar and every connected
/// phone change together. A swatch applies and closes; the custom picker sends
/// once the color stops changing, so dragging across the wheel does not flood
/// the socket.
struct WindowColorSheet: View {
    let window: WindowState
    let onChoose: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var custom: Color
    @State private var pendingSend: Task<Void, Never>?
    /// The custom color waiting out the pause, sent at once if the sheet
    /// closes first.
    @State private var pendingHex: String?

    init(window: WindowState, onChoose: @escaping (String?) -> Void) {
        self.window = window
        self.onChoose = onChoose
        _custom = State(initialValue: Color(hex: window.color))
    }

    private var current: String? { WindowColor.normalized(window.color) }

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
                                            .foregroundStyle(.white)
                                            .shadow(radius: 1)
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

                Button("Reset to automatic") {
                    choose(nil)
                }
                .font(.subheadline)
            }
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle(window.folder?.isEmpty == false ? window.folder! : window.name)
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
