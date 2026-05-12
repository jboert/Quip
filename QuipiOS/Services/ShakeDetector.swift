import SwiftUI
import UIKit

/// Adds shake-gesture detection to a SwiftUI view hierarchy. SwiftUI
/// doesn't expose `motionEnded` directly so we host a transparent
/// UIViewController that owns the responder chain entry point. Embed
/// inside a root view via `.background(ShakeDetector { … }.frame(width:
/// 0, height: 0))`. Fires `onShake` once per shake gesture; iOS auto-
/// dedupes rapid-repeat motion events. (§26.)
struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let vc = Controller()
        vc.onShake = onShake
        return vc
    }

    func updateUIViewController(_ vc: Controller, context: Context) {
        vc.onShake = onShake
    }

    final class Controller: UIViewController {
        var onShake: () -> Void = {}

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Lazy first-responder claim so we don't compete with text
            // fields that are actively focused. iOS hands shake events
            // up the responder chain, so even a lower-priority claim
            // here still receives them when nothing else cares.
            becomeFirstResponder()
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake { onShake() }
        }
    }
}
