import XCTest
import AppKit
@testable import Quip

/// Locks what `KeystrokeInjector.writeImagePayload` offers a paste target.
///
/// Everything runs against a PRIVATE pasteboard — a test that clobbered
/// `NSPasteboard.general` would eat whatever the person running it had copied.
final class ImagePasteboardPayloadTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private var fileURL: URL!

    override func setUpWithError() throws {
        pasteboard = NSPasteboard(name: .init("com.quip.tests.imagePayload"))
        pasteboard.clearContents()
        fileURL = URL(fileURLWithPath: "/tmp/quip-test-image.png")
    }

    override func tearDownWithError() throws {
        pasteboard.clearContents()
        pasteboard = nil
        fileURL = nil
    }

    /// A 2×2 bitmap — enough to have a real TIFF/PNG representation.
    private func makeImage() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(rep)
        return image
    }

    /// The regression: `writeObjects([NSImage])` offered only `public.tiff`, so
    /// a target that reads PNG found nothing and the paste did nothing.
    func test_offersPNGAlongsideTIFF() {
        KeystrokeInjector.writeImagePayload(makeImage(), fileURL: fileURL, to: pasteboard)
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(.tiff), "TIFF must stay — the proven Codex paste consumes it")
        XCTAssertTrue(types.contains(.png), "PNG must be offered for targets that ask for it")
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    /// Targets that attach "a pasted file" rather than raw bytes need the URL.
    func test_offersFileURL() {
        KeystrokeInjector.writeImagePayload(makeImage(), fileURL: fileURL, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), fileURL.absoluteString)
    }

    /// One item, several types. Several items reads as a multi-file paste.
    func test_writesASingleItem() {
        KeystrokeInjector.writeImagePayload(makeImage(), fileURL: fileURL, to: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    /// A second paste must not leave the first one's bytes behind.
    func test_replacesPreviousContents() {
        pasteboard.clearContents()
        pasteboard.setString("something the user copied", forType: .string)
        KeystrokeInjector.writeImagePayload(makeImage(), fileURL: fileURL, to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    /// An image with no bitmap still has to leave something pasteable behind,
    /// not a lone URL.
    func test_imageWithoutBitmap_stillWritesSomething() {
        KeystrokeInjector.writeImagePayload(NSImage(size: .zero), fileURL: fileURL, to: pasteboard)
        XCTAssertFalse((pasteboard.types ?? []).isEmpty)
    }
}
