import AppKit
import CoreImage

/// The one QR renderer for the Settings pairing block and the main window's
/// connection popover. Callers run it off the main actor from `.task(id:)` —
/// it used to run inside the view builder, once per keystroke in the PIN field.
enum PairingQR {
    /// Render `content` via CIFilter (no third-party QR library).
    /// errorCorrection=M balances density vs. resilience to phone-camera blur.
    /// The image is one point per module; display it with
    /// `.interpolation(.none)` so the upscale keeps edges crisp. Nil for empty
    /// content — there is nothing to pair with.
    nonisolated static func image(for content: String) -> NSImage? {
        guard !content.isEmpty, let data = content.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: ciImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
