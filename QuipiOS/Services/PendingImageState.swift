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
        case error(String)
    }

    @Published private(set) var image: UIImage?
    @Published private(set) var mimeType: String?
    @Published private(set) var filename: String?
    @Published private(set) var uploadState: UploadState = .idle

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

    /// Called by the submit flow before the WebSocket send.
    func markUploading() {
        uploadState = .uploading
    }

    /// Called on error ack. Leaves the image in place so the user can retry.
    func markError(_ reason: String) {
        uploadState = .error(reason)
    }

    var hasPendingImage: Bool { image != nil }
}
