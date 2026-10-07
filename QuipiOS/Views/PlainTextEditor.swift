import SwiftUI
import UIKit

/// A multi-line editor that saves exactly the characters typed: no smart
/// quotes or dashes, no smart insert/delete, no autocorrection, no
/// auto-capitalization, no spell-check marks.
///
/// SwiftUI's `TextEditor` exposes none of the smart-punctuation traits, so a
/// prompt body like `echo 'x'` was saved as `echo ‘x’` and broke when pasted
/// into a terminal. `UITextView.appearance()` would change every text view in
/// the app, so the prompt body editor wraps its own `UITextView` instead.
struct PlainTextEditor: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var accessibilityLabel: String = "Prompt body"

    /// The traits that make the view save what was typed. Separate from
    /// `makeUIView` so a test can check them on a plain `UITextView`.
    static func configure(_ view: UITextView, font: UIFont) {
        view.font = font
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        Self.configure(view, font: font)
        view.accessibilityLabel = accessibilityLabel
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Only an external change replaces the text; replacing it on every
        // keystroke would move the caret to the end.
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
