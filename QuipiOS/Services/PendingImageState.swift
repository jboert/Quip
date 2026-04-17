import Foundation
import UIKit

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
