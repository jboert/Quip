import Foundation
import UIKit

/// Categorization of an image_upload failure into actionable buckets so
/// the preview strip can render a useful chip + recovery affordance
/// instead of a freeform red string. Mapped from the raw `reason` text
/// (Mac-side error broadcast, iOS-side encoding/timeout failure, or
/// the watchdog's "no response (last stage: …)" message). Pure
/// classifier — testable without the full SwiftUI stack. (§L.)
enum ImageUploadFailure: String, Equatable {
    /// Watchdog tripped — Mac never sent ack/error within 10s. Common
    /// when the WebSocket dropped one-sided or the Mac app predates the
    /// image_upload handler.
    case timeout
    /// Mac broadcast `unknown window` — the targeted iTerm session
    /// closed between phone select and Mac receive.
    case unknownWindow
    /// Mac broadcast `invalid image data` / `invalid filename` — the
    /// b64 payload didn't decode or the filename was rejected.
    case invalidData
    /// Mac broadcast `could not save image` — disk write failed
    /// (Caches dir missing, permissions issue, full disk).
    case macDiskWrite
    /// Local recompression failed or the Mac dropped an oversized frame.
    case tooLarge
    /// Anything else — render the raw reason. Catch-all so we never
    /// silently swallow a new error string.
    case other

    /// Short, user-facing label for the chip. Always under 32 chars.
    var label: String {
        switch self {
        case .timeout:        return "Mac didn't acknowledge"
        case .unknownWindow:  return "Window closed before delivery"
        case .invalidData:    return "Image data invalid"
        case .macDiskWrite:   return "Mac couldn't save image"
        case .tooLarge:       return "Image too large"
        case .other:          return "Upload failed"
        }
    }

    /// Action affordance label rendered next to the chip — describes
    /// what the user can do about it. Empty string = no action button
    /// (catch-all path falls through to the raw reason without a CTA).
    var actionLabel: String {
        switch self {
        case .timeout:        return "Reset"
        case .unknownWindow:  return "Pick window"
        case .invalidData:    return "Try another"
        case .macDiskWrite:   return "Retry"
        case .tooLarge:       return "Try smaller"
        case .other:          return ""
        }
    }

    /// Map a raw reason string into a category. Static + nonisolated
    /// so it can be tested independently. Case-insensitive substring
    /// match — defensive against minor wording drift over time.
    static func classify(reason: String) -> ImageUploadFailure {
        let lower = reason.lowercased()
        if lower.contains("no response") || lower.contains("timed out") || lower.contains("timeout") {
            return .timeout
        }
        if lower.contains("unknown window") || lower.contains("window no longer") {
            return .unknownWindow
        }
        if lower.contains("invalid image") || lower.contains("invalid base64") || lower.contains("invalid filename") {
            return .invalidData
        }
        if lower.contains("could not save") || lower.contains("write failed") || lower.contains("disk") {
            return .macDiskWrite
        }
        if lower.contains("too large") || lower.contains("oversized") || lower.contains("too big") {
            return .tooLarge
        }
        return .other
    }
}

/// Observable holder for a single pending image attached to the terminal input.
/// One instance is shared between the portrait and landscape input rows so the
/// preview strip shows up wherever the user currently is.
@MainActor
final class PendingImageState: ObservableObject {

    enum UploadState: Equatable {
        case idle
        case uploading
        case justSent
        case error(String)
    }

    @Published private(set) var image: UIImage?
    @Published private(set) var mimeType: String?
    @Published private(set) var filename: String?
    @Published private(set) var uploadState: UploadState = .idle
    /// Last reached stage in the send pipeline — surfaced in the timeout
    /// error so we can see where the flow died without needing iOS logs.
    @Published private(set) var debugStage: String = ""

    func setDebugStage(_ stage: String) {
        debugStage = stage
    }

    /// Called by pickers after a successful selection.
    func setPending(image: UIImage, mimeType: String, filename: String) {
        self.image = image
        self.mimeType = mimeType
        self.filename = filename
        self.uploadState = .idle
    }

    /// Called by the ✕ button on the preview strip.
    func clear() {
        image = nil
        mimeType = nil
        filename = nil
        uploadState = .idle
    }

    /// Called by the submit flow before the WebSocket send. Starts a 10s
    /// watchdog — if no ack or error arrives in that window, we flip to
    /// `.error` so the user isn't stuck watching a perpetual spinner.
    func markUploading() {
        uploadState = .uploading
        debugStage = "markUploading"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.uploadState == .uploading else { return }
            self.markError("no response (last stage: \(self.debugStage))")
        }
    }

    /// Called on error ack. Leaves the image in place so the user can retry.
    func markError(_ reason: String) {
        uploadState = .error(reason)
    }

    /// Show a checkmark flash, then clear. Called when the Mac's ack arrives.
    /// The delay gives the user visual confirmation that the path was typed
    /// into the terminal before the thumbnail disappears.
    func markSentAndClear() {
        uploadState = .justSent
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.clear()
        }
    }

    var hasPendingImage: Bool { image != nil }
}
