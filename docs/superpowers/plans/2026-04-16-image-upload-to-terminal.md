# Image Upload to Terminal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Quip iPhone app send an image (from the photo library or camera) to the paired Mac, which writes it to a temp path and pastes that path into the active terminal's input for Claude Code to consume.

**Architecture:** The iPhone recompresses the image to ≤10 MB, base64-encodes it, and sends an `ImageUploadMessage` over the existing WebSocket. The Mac decodes the bytes, writes them to `~/Library/Caches/Quip/uploads/<uuid>-<filename>`, and calls the existing `KeystrokeInjector.sendText(path, pressReturn: false, …)` to inject the absolute path into the terminal identified by `windowId`. The iPhone shows a tiny pending-image preview strip above the input row in both portrait and landscape via a single shared SwiftUI view.

**Tech Stack:** Swift 5 / SwiftUI (iOS + macOS), `URLSessionWebSocketTask` (iOS), Network.framework `NWConnection` (macOS), `PHPickerViewController`, `UIImagePickerController` (camera), `ImageIO` / `UIKit` for recompression, XCTest for logic tests.

**Source spec:** `tasks/prd-image-upload-to-terminal.md`

**Branch:** `eb-branch` (no push per user policy; commits stay local until the user requests a PR).

---

## File Structure

### Create

- `Shared/Tests/ImageUploadMessageTests.swift` — protocol encode/decode tests.
- `QuipiOS/Services/ImageRecompressor.swift` — pure function that downscales/recompresses to fit the 10 MB cap.
- `QuipiOS/Tests/ImageRecompressorTests.swift` — XCTest for the recompressor.
- `QuipiOS/Services/PendingImageState.swift` — observable holder for a single pending image (data, mimeType, filename, upload state).
- `QuipiOS/Views/PendingImagePreviewStrip.swift` — shared SwiftUI view used by both portrait and landscape.
- `QuipiOS/Views/ImagePickerPresenter.swift` — wrappers around `PHPickerViewController` and `UIImagePickerController` (camera) as `UIViewControllerRepresentable`.
- `QuipMac/Services/ImageUploadHandler.swift` — pure-ish helper that validates/decodes/writes an `ImageUploadMessage` and returns the saved URL or an error.
- `QuipMac/Tests/ImageUploadHandlerTests.swift` — XCTest that exercises disk writes in a tempdir.

### Modify

- `Shared/MessageProtocol.swift` — add `ImageUploadMessage`, `ImageUploadAckMessage`, `ImageUploadErrorMessage`.
- `QuipiOS/project.yml` — add `NSPhotoLibraryUsageDescription`, update `NSCameraUsageDescription` copy. **Note:** `QuipiOS/Info.plist` itself is gitignored and regenerated from `project.yml` by xcodegen, so all permission strings live in `project.yml`.
- `QuipiOS/Services/WebSocketClient.swift` — add a typed `sendImageUpload` convenience (optional) and route incoming `image_upload_ack` / `image_upload_error` to a delegate callback.
- `QuipiOS/QuipApp.swift` (portrait input row, lines ~920–1076) — add photo-icon button and host the preview strip.
- `QuipiOS/Views/TerminalContentOverlay.swift` (landscape input row, lines ~100–150) — same.
- `QuipMac/QuipMacApp.swift` (dispatch switch, lines ~463–522) — add `case "image_upload":` that calls `ImageUploadHandler` and then `KeystrokeInjector.sendText`.

### Do NOT touch

- `QuipMac/Services/KeystrokeInjector.swift` — reused as-is. The image path goes in as plain text.
- `QuipMac/Services/WebSocketServer.swift` — message routing is unchanged; new case lives in the app-level dispatch.
- Android / Linux targets — out of scope.

---

## Phase Overview

1. **Protocol** (Task 1) — add message types with tests. Isolated from everything else.
2. **Mac handler** (Tasks 2–3) — disk write + terminal injection, gated behind the new switch case.
3. **iOS foundation** (Tasks 4–6) — Info.plist, recompressor, sender.
4. **iOS UI** (Tasks 7–12) — shared state, preview strip, pickers, portrait button, landscape button, submit flow.
5. **End-to-end verification** (Task 13) — real device + paired Mac, happy path + error paths.

Each task is its own commit. Commit messages follow the project's "blue-collar boomer" voice per `CLAUDE.md`.

---

## Task 1: Add `ImageUploadMessage` to the shared protocol

**Files:**
- Modify: `Shared/MessageProtocol.swift`
- Create: `Shared/Tests/ImageUploadMessageTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Shared/Tests/ImageUploadMessageTests.swift`:

```swift
import XCTest
@testable import Shared // or whatever the existing tests import; match the pattern

final class ImageUploadMessageTests: XCTestCase {

    func test_imageUploadMessage_encodesAndDecodesRoundTrip() throws {
        let original = ImageUploadMessage(
            type: "image_upload",
            imageId: "550e8400-e29b-41d4-a716-446655440000",
            windowId: "window-abc-123",
            filename: "screenshot-2026-04-16.png",
            mimeType: "image/png",
            data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )

        let encoded = try MessageCoder.encode(original)
        let peeked = MessageCoder.messageType(from: encoded)
        XCTAssertEqual(peeked, "image_upload")

        let decoded = try MessageCoder.decode(ImageUploadMessage.self, from: encoded)
        XCTAssertEqual(decoded.imageId, original.imageId)
        XCTAssertEqual(decoded.windowId, original.windowId)
        XCTAssertEqual(decoded.filename, original.filename)
        XCTAssertEqual(decoded.mimeType, original.mimeType)
        XCTAssertEqual(decoded.data, original.data)
    }

    func test_imageUploadAckMessage_encodesAndDecodes() throws {
        let original = ImageUploadAckMessage(
            type: "image_upload_ack",
            imageId: "550e8400-e29b-41d4-a716-446655440000",
            savedPath: "/Users/alice/Library/Caches/Quip/uploads/550e8400-screenshot.png"
        )
        let encoded = try MessageCoder.encode(original)
        XCTAssertEqual(MessageCoder.messageType(from: encoded), "image_upload_ack")
        let decoded = try MessageCoder.decode(ImageUploadAckMessage.self, from: encoded)
        XCTAssertEqual(decoded.imageId, original.imageId)
        XCTAssertEqual(decoded.savedPath, original.savedPath)
    }

    func test_imageUploadErrorMessage_encodesAndDecodes() throws {
        let original = ImageUploadErrorMessage(
            type: "image_upload_error",
            imageId: "550e8400-e29b-41d4-a716-446655440000",
            reason: "unknown window"
        )
        let encoded = try MessageCoder.encode(original)
        XCTAssertEqual(MessageCoder.messageType(from: encoded), "image_upload_error")
        let decoded = try MessageCoder.decode(ImageUploadErrorMessage.self, from: encoded)
        XCTAssertEqual(decoded.reason, "unknown window")
    }
}
```

Match the import style of the existing tests in `Shared/Tests/` — open one of them (e.g. the protocol test) to see how they import and adapt if needed.

- [ ] **Step 2: Run the test to verify it fails**

Run from Xcode: open the Shared tests scheme, ⌘U. Or from CLI:

```bash
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:SharedTests/ImageUploadMessageTests
```

(Use whatever the existing Shared test target is actually named — check `Shared/Tests/` and the Xcode scheme list.)

Expected: **FAIL** — "Cannot find 'ImageUploadMessage' in scope."

- [ ] **Step 3: Add the three message structs in `Shared/MessageProtocol.swift`**

Add below the existing message structs (after `ErrorMessage` around line 286 — verify exact line):

```swift
// MARK: - Image Upload

/// Phone → Mac. Carries a single image to be attached to a terminal.
/// `data` is the image bytes base64-encoded as a string (standard base64, no URL-safe variant).
/// Post-encoding message size must be ≤ 10 MB (enforced on the sender side).
struct ImageUploadMessage: Codable {
    let type: String          // "image_upload"
    let imageId: String       // UUID string, generated by the phone
    let windowId: String      // target terminal window
    let filename: String      // suggested filename, e.g. "screenshot-2026-04-16-143022.png"
    let mimeType: String      // "image/png" or "image/jpeg"
    let data: String          // base64-encoded image bytes
}

/// Mac → Phone. Sent after the image was written to disk and the path was pasted.
struct ImageUploadAckMessage: Codable {
    let type: String          // "image_upload_ack"
    let imageId: String
    let savedPath: String     // absolute path the Mac wrote the image to
}

/// Mac → Phone. Sent on any failure (decode error, unknown window, disk write error, etc.).
struct ImageUploadErrorMessage: Codable {
    let type: String          // "image_upload_error"
    let imageId: String
    let reason: String        // human-readable, safe to surface to the user
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same `xcodebuild test` command. Expected: **PASS**.

- [ ] **Step 5: Commit**

```bash
git add Shared/MessageProtocol.swift Shared/Tests/ImageUploadMessageTests.swift
git commit -m "Added them new image-upload messages so the phone can holler at the Mac about a picture coming through"
```

---

## Task 2: `ImageUploadHandler` writes bytes to disk

**Files:**
- Create: `QuipMac/Services/ImageUploadHandler.swift`
- Create: `QuipMac/Tests/ImageUploadHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `QuipMac/Tests/ImageUploadHandlerTests.swift`:

```swift
import XCTest
@testable import QuipMac

final class ImageUploadHandlerTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageUploadHandlerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_save_writesFileAndReturnsAbsolutePath() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let handler = ImageUploadHandler(uploadsDirectory: root)

        // 1x1 transparent PNG
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let msg = ImageUploadMessage(
            type: "image_upload",
            imageId: "abc-123",
            windowId: "w1",
            filename: "tiny.png",
            mimeType: "image/png",
            data: pngBase64
        )

        let savedURL = try handler.save(message: msg)

        XCTAssertTrue(savedURL.path.hasPrefix(root.path))
        XCTAssertTrue(savedURL.lastPathComponent.contains("abc-123"))
        XCTAssertTrue(savedURL.lastPathComponent.hasSuffix("tiny.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        let bytes = try Data(contentsOf: savedURL)
        XCTAssertEqual(bytes, Data(base64Encoded: pngBase64))
    }

    func test_save_throwsOnInvalidBase64() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let handler = ImageUploadHandler(uploadsDirectory: root)
        let msg = ImageUploadMessage(
            type: "image_upload",
            imageId: "bad",
            windowId: "w1",
            filename: "broken.png",
            mimeType: "image/png",
            data: "!!!not valid base64!!!"
        )

        XCTAssertThrowsError(try handler.save(message: msg))
    }

    func test_save_sanitizesFilenameToPreventPathTraversal() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let handler = ImageUploadHandler(uploadsDirectory: root)
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let msg = ImageUploadMessage(
            type: "image_upload",
            imageId: "x",
            windowId: "w1",
            filename: "../../evil.png",
            mimeType: "image/png",
            data: pngBase64
        )

        let savedURL = try handler.save(message: msg)
        XCTAssertTrue(savedURL.path.hasPrefix(root.path), "Saved path escaped the uploads root: \(savedURL.path)")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS' -only-testing:QuipMacTests/ImageUploadHandlerTests
```

(Verify the QuipMac test scheme name; if the test target doesn't exist yet, add one through Xcode: File → New → Target → macOS Unit Testing Bundle.)

Expected: **FAIL** — `ImageUploadHandler` not found.

- [ ] **Step 3: Implement `ImageUploadHandler`**

Create `QuipMac/Services/ImageUploadHandler.swift`:

```swift
import Foundation

enum ImageUploadHandlerError: Error {
    case invalidBase64
    case writeFailed(underlying: Error)
}

/// Decodes an ImageUploadMessage and writes it to disk in a sandboxed uploads directory.
/// Filename is sanitized so a malicious phone can't write outside the uploads directory.
struct ImageUploadHandler {

    /// Directory into which uploaded images are written. In production this is
    /// ~/Library/Caches/Quip/uploads/; tests pass a tempdir.
    let uploadsDirectory: URL

    /// Default production initializer.
    static func defaultProduction() -> ImageUploadHandler {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Quip/uploads", isDirectory: true)
        return ImageUploadHandler(uploadsDirectory: dir)
    }

    /// Decode the base64 payload, write it to disk, and return the absolute URL.
    /// Filename in the returned URL has the form `<imageId>-<sanitizedFilename>`.
    func save(message: ImageUploadMessage) throws -> URL {
        guard let bytes = Data(base64Encoded: message.data) else {
            throw ImageUploadHandlerError.invalidBase64
        }

        try FileManager.default.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)

        let safeName = sanitize(filename: message.filename)
        let target = uploadsDirectory.appendingPathComponent("\(message.imageId)-\(safeName)")

        do {
            try bytes.write(to: target, options: .atomic)
        } catch {
            throw ImageUploadHandlerError.writeFailed(underlying: error)
        }
        return target
    }

    /// Strip path separators and parent-directory tokens. Keep it simple and strict.
    private func sanitize(filename: String) -> String {
        let lastComponent = (filename as NSString).lastPathComponent
        let filtered = lastComponent.replacingOccurrences(of: "/", with: "_")
                                    .replacingOccurrences(of: "\\", with: "_")
                                    .replacingOccurrences(of: "..", with: "_")
        // Fall back if sanitization empties the name.
        return filtered.isEmpty ? "image" : filtered
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same `xcodebuild test` command. Expected: **PASS** (all 3 tests).

- [ ] **Step 5: Commit**

```bash
git add QuipMac/Services/ImageUploadHandler.swift QuipMac/Tests/ImageUploadHandlerTests.swift
git commit -m "The Mac's got a spot now to tuck pictures away when the phone slides one over"
```

---

## Task 3: Wire `image_upload` into the Mac dispatch switch

**Files:**
- Modify: `QuipMac/QuipMacApp.swift` (the dispatch switch at lines ~463–522)

- [ ] **Step 1: Read the existing `send_text` case**

Open `QuipMac/QuipMacApp.swift` and find the `switch type { ... }` block (around line 463). Study the `case "send_text":` branch — that's the template we're copying. Note how it:
1. Decodes the message via `MessageCoder.decode(...)`.
2. Finds the window in `windowManager.windows`.
3. Resolves `terminalApp` via `terminalAppForWindow(window)`.
4. Calls `windowManager.focusWindow(...)`.
5. Calls `keystrokeInjector.sendText(..., pressReturn: ..., terminalApp: ..., cgWindowNumber: window.windowNumber, iterm2SessionId: window.iterm2SessionId)`.

- [ ] **Step 2: Add a stored `ImageUploadHandler` on the app type**

Near the other service declarations at the top of `QuipMacApp` (where `keystrokeInjector`, `windowManager`, etc. are declared — read the file to find the exact spot), add:

```swift
private let imageUploadHandler = ImageUploadHandler.defaultProduction()
```

- [ ] **Step 3: Add the `image_upload` case to the dispatch switch**

Inside the `switch type { ... }` block, add a new case (place it just before `default:`):

```swift
case "image_upload":
    guard let msg = MessageCoder.decode(ImageUploadMessage.self, from: data) else {
        NSLog("[QuipMacApp] Failed to decode image_upload message")
        return
    }

    // Resolve target window first — fail fast, don't write the file if it's gone.
    guard let window = windowManager.windows.first(where: { $0.id == msg.windowId }) else {
        let err = ImageUploadErrorMessage(
            type: "image_upload_error",
            imageId: msg.imageId,
            reason: "unknown window"
        )
        if let errData = try? MessageCoder.encode(err) {
            connection.send(string: String(data: errData, encoding: .utf8) ?? "")
        }
        return
    }

    // Write to disk.
    let savedURL: URL
    do {
        savedURL = try imageUploadHandler.save(message: msg)
    } catch {
        let err = ImageUploadErrorMessage(
            type: "image_upload_error",
            imageId: msg.imageId,
            reason: "write failed: \(error.localizedDescription)"
        )
        if let errData = try? MessageCoder.encode(err) {
            connection.send(string: String(data: errData, encoding: .utf8) ?? "")
        }
        return
    }

    // Paste the absolute path into the terminal, with a trailing space but no Return.
    let termApp = terminalAppForWindow(window)
    windowManager.focusWindow(msg.windowId)
    _ = keystrokeInjector.sendText(
        savedURL.path + " ",
        to: msg.windowId,
        pressReturn: false,
        terminalApp: termApp,
        windowName: window.name,
        cgWindowNumber: window.windowNumber,
        iterm2SessionId: window.iterm2SessionId
    )

    // Ack back to phone.
    let ack = ImageUploadAckMessage(
        type: "image_upload_ack",
        imageId: msg.imageId,
        savedPath: savedURL.path
    )
    if let ackData = try? MessageCoder.encode(ack) {
        connection.send(string: String(data: ackData, encoding: .utf8) ?? "")
    }
```

**Important:** The exact variable names for sending back to the phone (`connection.send(string:)`) and the exact method signatures of the other cases may differ — **match the style of the existing `send_text` case line-for-line**. Read before copy-pasting. If a helper like `sendToClient(...)` is used elsewhere, use that instead of re-implementing inline.

- [ ] **Step 4: Verify it builds**

Build the Mac target:

```bash
xcodebuild build -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS'
```

Expected: **BUILD SUCCEEDED**. No runtime test here — full verification happens in Task 13.

- [ ] **Step 5: Commit**

```bash
git add QuipMac/QuipMacApp.swift
git commit -m "Mac listens for the picture now and drops the file path right into whatever terminal the phone was pointin' at"
```

---

## Task 4: Add photo-library permission, update camera description (via `project.yml`)

**Files:**
- Modify: `QuipiOS/project.yml` (lines ~47–55, the `info:` → `properties:` section)

> **Critical:** `QuipiOS/Info.plist` is gitignored and regenerated from `QuipiOS/project.yml` by xcodegen on every build. Editing `Info.plist` directly would be clobbered. All permission strings must live in `project.yml`.

- [ ] **Step 1: Read the existing `project.yml` privacy section**

Open `QuipiOS/project.yml`. Find the `info: properties:` block (around lines 47–55). Existing entries include:
- `NSSpeechRecognitionUsageDescription`
- `NSCameraUsageDescription` — "Quip uses the camera to scan QR codes for connecting to your Mac."
- `NSMicrophoneUsageDescription`
- `NSBluetoothAlwaysUsageDescription`
- `NSBluetoothPeripheralUsageDescription`
- `NSLocalNetworkUsageDescription`

Confirm `NSPhotoLibraryUsageDescription` is absent.

- [ ] **Step 2: Add `NSPhotoLibraryUsageDescription` and update camera copy**

Make two edits in `QuipiOS/project.yml`:

1. Replace the existing `NSCameraUsageDescription` line with:

```yaml
        NSCameraUsageDescription: Quip uses the camera to scan QR codes for connecting to your Mac, and to capture photos you attach to the active Claude Code terminal.
```

2. Add a new line alongside the other privacy keys (e.g. just below `NSCameraUsageDescription`):

```yaml
        NSPhotoLibraryUsageDescription: Quip attaches images you pick from your library to the active Claude Code terminal on your Mac.
```

Match the surrounding indentation exactly — it's 8 spaces in the existing block.

- [ ] **Step 3: Regenerate `Info.plist` and verify it's valid**

Run whatever the project uses to regenerate (typically `xcodegen generate` from `QuipiOS/`). Check `README.md` for the canonical command if unsure:

```bash
cd QuipiOS && xcodegen generate && cd ..
plutil -lint QuipiOS/Info.plist
```

Expected: `QuipiOS/Info.plist: OK`, and the generated plist should contain both keys.

- [ ] **Step 4: Verify the generated plist has the new keys**

```bash
plutil -extract NSPhotoLibraryUsageDescription raw QuipiOS/Info.plist
plutil -extract NSCameraUsageDescription raw QuipiOS/Info.plist
```

Expected: both commands print the new strings.

- [ ] **Step 5: Commit**

Only `project.yml` is tracked by git (`Info.plist` is ignored per `.gitignore`).

```bash
git add QuipiOS/project.yml
git commit -m "Told the phone it needs to ask permission before poking around in photos, and updated the camera blurb too"
```

---

## Task 5: `ImageRecompressor` enforces the 10 MB cap

**Files:**
- Create: `QuipiOS/Services/ImageRecompressor.swift`
- Create: `QuipiOS/Tests/ImageRecompressorTests.swift`

The recompressor takes raw image bytes + a declared mime type, returns `(Data, mimeType)` where the data is ≤ `maxBytes` after base64 inflation. Strategy: if within cap as-is, return unchanged; otherwise JPEG-recompress at quality 0.85, and if still over, progressively downscale the longest edge by 25% until under cap or a minimum dimension (512px) is hit.

- [ ] **Step 1: Write the failing test**

Create `QuipiOS/Tests/ImageRecompressorTests.swift`:

```swift
import XCTest
import UIKit
@testable import QuipiOS

final class ImageRecompressorTests: XCTestCase {

    /// ~300 KB PNG — well under cap; must be returned unchanged.
    func test_smallImage_returnedUnchanged() throws {
        let image = UIImage.solidColor(.red, size: CGSize(width: 200, height: 200))
        let png = image.pngData()!
        XCTAssertLessThan(png.count, 1_000_000)

        let recompressor = ImageRecompressor(maxPayloadBytes: 10_000_000)
        let result = try recompressor.recompress(rawData: png, declaredMime: "image/png")

        XCTAssertEqual(result.data, png)
        XCTAssertEqual(result.mimeType, "image/png")
    }

    /// Large-ish image: force recompress path and verify it ends up under cap.
    func test_largeImage_recompressedUnderCap() throws {
        let image = UIImage.solidColor(.blue, size: CGSize(width: 4000, height: 4000))
        let raw = image.pngData()!

        // Set a tight cap so we force the JPEG path even on a solid-color image.
        let recompressor = ImageRecompressor(maxPayloadBytes: 200_000)
        let result = try recompressor.recompress(rawData: raw, declaredMime: "image/png")

        XCTAssertLessThanOrEqual(result.data.count, 200_000)
        XCTAssertEqual(result.mimeType, "image/jpeg")
    }

    /// Extremely tight cap smaller than the minimum-dimension output: must throw.
    func test_impossibleCap_throws() {
        let image = UIImage.solidColor(.green, size: CGSize(width: 4000, height: 4000))
        let raw = image.pngData()!

        let recompressor = ImageRecompressor(maxPayloadBytes: 100) // way too small
        XCTAssertThrowsError(try recompressor.recompress(rawData: raw, declaredMime: "image/png"))
    }
}

private extension UIImage {
    static func solidColor(_ color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:QuipiOSTests/ImageRecompressorTests
```

Expected: **FAIL** — `ImageRecompressor` not found.

- [ ] **Step 3: Implement `ImageRecompressor`**

Create `QuipiOS/Services/ImageRecompressor.swift`:

```swift
import Foundation
import UIKit

enum ImageRecompressorError: Error {
    case decodeFailed
    case cannotFitUnderCap
}

/// Ensures an image's byte count fits under a configurable cap.
/// Called before base64 encoding; the caller reserves headroom for base64's ~33% inflation.
struct ImageRecompressor {

    /// Post-recompression byte budget. Callers should pass `cap / 1.37` to reserve base64 headroom
    /// (base64 turns 3 bytes into 4 characters → ~1.33x inflation; 1.37 adds a safety cushion).
    let maxPayloadBytes: Int

    /// Minimum longest-edge pixel dimension. Images are never downscaled below this.
    let minLongestEdge: CGFloat = 512

    /// Downscale factor applied at each step: 0.75 shrinks longest edge by 25% per iteration.
    let downscaleStep: CGFloat = 0.75

    /// JPEG quality for recompress path.
    let jpegQuality: CGFloat = 0.85

    /// Returns bytes to send + the mime type that matches them (may change from png → jpeg).
    func recompress(rawData: Data, declaredMime: String) throws -> (data: Data, mimeType: String) {
        if rawData.count <= maxPayloadBytes {
            return (rawData, declaredMime)
        }

        guard var image = UIImage(data: rawData) else {
            throw ImageRecompressorError.decodeFailed
        }

        // First try: re-encode at jpegQuality without resizing.
        if let jpeg = image.jpegData(compressionQuality: jpegQuality), jpeg.count <= maxPayloadBytes {
            return (jpeg, "image/jpeg")
        }

        // Then: progressively downscale until it fits or we hit the floor.
        var longest = max(image.size.width, image.size.height)
        while longest > minLongestEdge {
            longest *= downscaleStep
            let scale = longest / max(image.size.width, image.size.height)
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            image = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
            if let jpeg = image.jpegData(compressionQuality: jpegQuality), jpeg.count <= maxPayloadBytes {
                return (jpeg, "image/jpeg")
            }
        }

        throw ImageRecompressorError.cannotFitUnderCap
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same `xcodebuild test` command. Expected: **PASS** (3 tests).

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/Services/ImageRecompressor.swift QuipiOS/Tests/ImageRecompressorTests.swift
git commit -m "Shrink real big photos down before shipping 'em over the wire so the thing don't choke"
```

---

## Task 6: `PendingImageState` — the single source of truth for the pending image

**Files:**
- Create: `QuipiOS/Services/PendingImageState.swift`

No tests — this is a thin `@MainActor` `ObservableObject` with simple mutators. We'll verify it through UI integration in later tasks.

- [ ] **Step 1: Create the state holder**

Create `QuipiOS/Services/PendingImageState.swift`:

```swift
import Foundation
import UIKit

/// Observable holder for a single pending image. Shared between portrait and landscape
/// input rows — both views read and mutate the same instance via `@EnvironmentObject` or
/// an injected binding, so the preview strip shows up in whichever view is active.
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
```

- [ ] **Step 2: Verify it builds**

```bash
xcodebuild build -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Commit**

```bash
git add QuipiOS/Services/PendingImageState.swift
git commit -m "Little notebook that keeps track of which picture's queued up to send, so both the regular and sideways view can see it"
```

---

## Task 7: Shared `PendingImagePreviewStrip` SwiftUI view

**Files:**
- Create: `QuipiOS/Views/PendingImagePreviewStrip.swift`

- [ ] **Step 1: Implement the view**

Create `QuipiOS/Views/PendingImagePreviewStrip.swift`:

```swift
import SwiftUI

/// Thin horizontal strip that appears above the terminal input row when a pending
/// image is attached. Shows a thumbnail, a remove (✕) control, and an upload state
/// overlay (spinner / error). Renders nothing when no image is pending.
struct PendingImagePreviewStrip: View {

    @ObservedObject var state: PendingImageState

    var body: some View {
        if let image = state.image {
            HStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            if state.uploadState == .uploading {
                                Color.black.opacity(0.45)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                ProgressView()
                                    .tint(.white)
                            }
                        }

                    if case .idle = state.uploadState {
                        Button {
                            state.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white, .black.opacity(0.7))
                                .offset(x: 6, y: -6)
                        }
                        .accessibilityLabel("Remove pending image")
                    }
                }

                if case .error(let reason) = state.uploadState {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

Build the iOS target. Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Commit**

```bash
git add QuipiOS/Views/PendingImagePreviewStrip.swift
git commit -m "Little picture thumbnail shows up above the input when you've got one queued — tap the X to toss it"
```

---

## Task 8: Image pickers (library + camera) as SwiftUI-friendly wrappers

**Files:**
- Create: `QuipiOS/Views/ImagePickerPresenter.swift`

- [ ] **Step 1: Implement both picker wrappers**

Create `QuipiOS/Views/ImagePickerPresenter.swift`:

```swift
import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Wraps PHPickerViewController. Single-select, images only.
struct LibraryImagePicker: UIViewControllerRepresentable {

    let onPicked: (UIImage, _ mimeType: String, _ filename: String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: LibraryImagePicker

        init(parent: LibraryImagePicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                parent.onCancel()
                return
            }
            let provider = result.itemProvider
            let suggestedName = provider.suggestedName ?? "image"

            // Prefer PNG for anything that advertises it (screenshots often do).
            if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    guard let data, let image = UIImage(data: data) else { return }
                    DispatchQueue.main.async {
                        self.parent.onPicked(image, "image/png", suggestedName + ".png")
                    }
                }
                return
            }

            // Otherwise ask the provider for a generic image; fall back to JPEG.
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    guard let image = object as? UIImage else { return }
                    DispatchQueue.main.async {
                        self.parent.onPicked(image, "image/jpeg", suggestedName + ".jpg")
                    }
                }
            } else {
                DispatchQueue.main.async { self.parent.onCancel() }
            }
        }
    }
}

/// Wraps UIImagePickerController in camera mode.
struct CameraImagePicker: UIViewControllerRepresentable {

    let onPicked: (UIImage, _ mimeType: String, _ filename: String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraImagePicker

        init(parent: CameraImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.originalImage] as? UIImage) ?? (info[.editedImage] as? UIImage)
            picker.dismiss(animated: true)
            if let image {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                let name = "photo-\(formatter.string(from: Date())).jpg"
                parent.onPicked(image, "image/jpeg", name)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            parent.onCancel()
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

Build the iOS target. Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Commit**

```bash
git add QuipiOS/Views/ImagePickerPresenter.swift
git commit -m "Hooked up the photo library and the camera so you can grab an image from either one"
```

---

## Task 9: Extend `WebSocketClient` to receive image upload acks/errors

**Files:**
- Modify: `QuipiOS/Services/WebSocketClient.swift`

- [ ] **Step 1: Read the existing receive path**

Open `QuipiOS/Services/WebSocketClient.swift`. Find where incoming messages are handled — look for a receive loop, a switch on message type, or a delegate-style callback to the app. The existing pattern handles messages like acknowledgements already; we're adding two new types to the same pattern.

- [ ] **Step 2: Add two published callback hooks**

Near the other published properties or callback declarations (match the style you see in the file), add:

```swift
/// Fired when the Mac acks an image upload. String is the Mac-side absolute path.
var onImageUploadAck: ((String) -> Void)?

/// Fired when the Mac rejects an image upload. String is a human-readable reason.
var onImageUploadError: ((String) -> Void)?
```

- [ ] **Step 3: Dispatch `image_upload_ack` / `image_upload_error` in the receive loop**

In the incoming-message handler, after the existing type-peek, add branches that decode the new types and call the corresponding closure on the main thread. The exact shape depends on the existing receive code — match it. For example, if the file currently has:

```swift
if let type = MessageCoder.messageType(from: data) {
    switch type {
    case "some_existing_type":
        ...
    }
}
```

Add:

```swift
case "image_upload_ack":
    if let msg = MessageCoder.decode(ImageUploadAckMessage.self, from: data) {
        DispatchQueue.main.async { self.onImageUploadAck?(msg.savedPath) }
    }

case "image_upload_error":
    if let msg = MessageCoder.decode(ImageUploadErrorMessage.self, from: data) {
        DispatchQueue.main.async { self.onImageUploadError?(msg.reason) }
    }
```

- [ ] **Step 4: Verify it builds**

Build the iOS target. Expected: **BUILD SUCCEEDED**.

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/Services/WebSocketClient.swift
git commit -m "Phone listens for the Mac's yep-got-it or nope-didn't after sending a picture"
```

---

## Task 10: Photo button + preview strip in the portrait input row

**Files:**
- Modify: `QuipiOS/QuipApp.swift` (portrait input row ~lines 920–1076)

Per the PRD and the compact-UI rule: one photo icon button tucked in next to the existing mic/keyboard controls, and the preview strip slotted directly above the input row (renders nothing when idle, so no permanent vertical growth).

- [ ] **Step 1: Locate the portrait input row**

Open `QuipiOS/QuipApp.swift`. Find the main HStack around line 926–1057 that contains the chevron/plus/rectangle buttons, the mic button (~lines 1003–1020), the keyboard toggle (~lines 1030–1042), and the return button (~lines 1045–1057).

- [ ] **Step 2: Add shared state**

At the containing view's property declarations, add:

```swift
@StateObject private var pendingImage = PendingImageState()

@State private var showingImageSourceSheet = false
@State private var showingLibraryPicker = false
@State private var showingCameraPicker = false
```

If `PendingImageState` is meant to be shared with the landscape view too (it should be), declare it once in the parent view that hosts both orientations and pass it down via `.environmentObject(pendingImage)` — read the file to find that parent.

- [ ] **Step 3: Insert the photo button between the keyboard toggle and return button**

Between the keyboard toggle button (~line 1042) and the return button (~line 1045), add:

```swift
Button {
    showingImageSourceSheet = true
} label: {
    Image(systemName: "photo")
        .font(.system(size: 18, weight: .medium))
        .frame(width: 36, height: 36)
}
.accessibilityLabel("Attach image")
```

Match the visual styling (font size, frame, tint) of the adjacent mic/keyboard/return buttons by reading what they already use — don't guess.

- [ ] **Step 4: Wire up the action sheet and picker sheets**

Immediately after the outer input row's view body (on the same container), attach:

```swift
.confirmationDialog("Attach image", isPresented: $showingImageSourceSheet, titleVisibility: .hidden) {
    if UIImagePickerController.isSourceTypeAvailable(.camera) {
        Button("Take Photo") { showingCameraPicker = true }
    }
    Button("Choose from Library") { showingLibraryPicker = true }
    Button("Cancel", role: .cancel) {}
}
.sheet(isPresented: $showingLibraryPicker) {
    LibraryImagePicker(
        onPicked: { image, mime, name in
            pendingImage.setPending(image: image, mimeType: mime, filename: name)
            showingLibraryPicker = false
        },
        onCancel: { showingLibraryPicker = false }
    )
}
.fullScreenCover(isPresented: $showingCameraPicker) {
    CameraImagePicker(
        onPicked: { image, mime, name in
            pendingImage.setPending(image: image, mimeType: mime, filename: name)
            showingCameraPicker = false
        },
        onCancel: { showingCameraPicker = false }
    )
}
```

- [ ] **Step 5: Insert the preview strip above the input row**

Immediately above the HStack that hosts the input row, add:

```swift
PendingImagePreviewStrip(state: pendingImage)
```

Because the strip renders nothing when `state.image == nil`, this adds zero visual height in the idle case — preserving the compact-UI rule.

- [ ] **Step 6: Verify on simulator**

Build and run on the iPhone simulator. Manual checklist:
- Tap the photo icon → action sheet appears with "Take Photo" (only on real devices) and "Choose from Library".
- Cancel the sheet → no change to the input row.
- Choose a library image → thumbnail appears above the input, input row doesn't shift in height when idle.
- Tap the ✕ on the thumbnail → thumbnail disappears.
- No crashes when triggering the library picker the first time (permission prompt shows and is accepted).

- [ ] **Step 7: Commit**

```bash
git add QuipiOS/QuipApp.swift
git commit -m "Put a little photo button in the bottom row so you can tack a picture onto what you're typing"
```

---

## Task 11: Photo button + preview strip in the landscape input row

**Files:**
- Modify: `QuipiOS/Views/TerminalContentOverlay.swift` (landscape input row ~lines 100–150)

- [ ] **Step 1: Ensure the landscape view can see `pendingImage`**

If Task 10 made `pendingImage` an `@EnvironmentObject` at the parent, the landscape view just declares `@EnvironmentObject var pendingImage: PendingImageState`. If Task 10 kept it private to the portrait container, hoist it up to the common parent first (small refactor — also move the sheet bindings up so both views open the same pickers).

- [ ] **Step 2: Add the photo button**

In the HStack around lines 130–150, place the photo button directly next to the keyboard toggle, styled to match the landscape's slightly larger button treatment:

```swift
Button {
    showingImageSourceSheet = true
} label: {
    Image(systemName: "photo")
        .font(.system(size: 20, weight: .medium))
        .frame(width: 40, height: 40)
}
.accessibilityLabel("Attach image")
```

- [ ] **Step 3: Insert the preview strip above the landscape input bar**

Above the text-input bar (line ~103) or the keys HStack (whichever is topmost for the landscape input region), add:

```swift
PendingImagePreviewStrip(state: pendingImage)
```

- [ ] **Step 4: Verify on device in landscape**

Build + run. Rotate phone to landscape, tap the photo button, confirm the same action sheet → picker → thumbnail flow works. Confirm there's no permanent height increase in idle state.

- [ ] **Step 5: Commit**

```bash
git add QuipiOS/Views/TerminalContentOverlay.swift
git commit -m "Sideways view gets the same photo button so you don't have to flip the phone to send a picture"
```

---

## Task 12: Submit flow — encode, send, handle ack/error

**Files:**
- Modify: wherever the portrait/landscape submit (Return button / mic-send / text-input Return key) lands text today. This is typically a single method on the parent view or a shared service. **Read the code to find it** — don't guess. Good search keywords: `sendText`, `SendTextMessage`, `pressReturn`, `onSubmit`, the bound action of the Return button (~line 1045 in `QuipApp.swift`).

- [ ] **Step 1: Find the single text-submit pathway**

Locate the method that today does the equivalent of:

```swift
let msg = SendTextMessage(type: "send_text", windowId: activeWindowId, text: text, pressReturn: ...)
webSocketClient.send(msg)
```

All image submission needs to ride through the same path, just *before* the existing text send.

- [ ] **Step 2: Add an image-send helper**

In the same file/class, add:

```swift
private let imageRecompressor = ImageRecompressor(maxPayloadBytes: 7_300_000) // ~10 MB post-base64

private func sendPendingImageIfNeeded(windowId: String) {
    guard let image = pendingImage.image,
          let filename = pendingImage.filename,
          let mime = pendingImage.mimeType else { return }

    pendingImage.markUploading()

    // Encode on a background queue to avoid main-thread jank.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self else { return }

        // Convert to raw bytes based on declared mime. PNG for PNGs; JPEG otherwise.
        let rawData: Data
        if mime == "image/png" {
            guard let d = image.pngData() else {
                DispatchQueue.main.async { self.pendingImage.markError("couldn't encode PNG") }
                return
            }
            rawData = d
        } else {
            guard let d = image.jpegData(compressionQuality: 0.95) else {
                DispatchQueue.main.async { self.pendingImage.markError("couldn't encode JPEG") }
                return
            }
            rawData = d
        }

        do {
            let (data, finalMime) = try self.imageRecompressor.recompress(rawData: rawData, declaredMime: mime)
            let base64 = data.base64EncodedString()
            let msg = ImageUploadMessage(
                type: "image_upload",
                imageId: UUID().uuidString,
                windowId: windowId,
                filename: filename,
                mimeType: finalMime,
                data: base64
            )
            DispatchQueue.main.async {
                self.webSocketClient.send(msg)
            }
        } catch {
            DispatchQueue.main.async { self.pendingImage.markError("image too large to send") }
        }
    }
}
```

- [ ] **Step 3: Wire ack/error callbacks once, at init**

In the same view/service's initializer (or `onAppear`), wire up:

```swift
webSocketClient.onImageUploadAck = { [weak self] _ in
    self?.pendingImage.clear()
}
webSocketClient.onImageUploadError = { [weak self] reason in
    self?.pendingImage.markError(reason)
}
```

- [ ] **Step 4: Call `sendPendingImageIfNeeded` from the submit method**

In the existing submit method, before (or around) the existing `send_text` send, add:

```swift
sendPendingImageIfNeeded(windowId: activeWindowId)
```

The image send is fire-and-forget from the submit method's perspective; the ack callback clears the preview asynchronously.

- [ ] **Step 5: Verify on device with paired Mac**

Full manual test (this is the real end-to-end preview; Task 13 is the formal pass):

1. Start Mac app, confirm a terminal is registered.
2. Pair phone, select that terminal.
3. Tap photo button → Choose from Library → pick a screenshot.
4. Thumbnail appears above input.
5. Tap Return (or the existing send control).
6. Thumbnail shows spinner → disappears.
7. The file path appears in the Mac terminal's input area (without pressing Return on the terminal itself).
8. Open the path in Finder or run `cat` on it to confirm the image was actually written.

- [ ] **Step 6: Commit**

```bash
git add QuipiOS/QuipApp.swift QuipiOS/Views/TerminalContentOverlay.swift
git commit -m "When you hit send, the picture gets packed up, shipped over, and the Mac drops the file path right where you were typing"
```

---

## Task 13: End-to-end verification + cleanup

**Files:** none modified; this task is manual QA + small cleanup commits if needed.

- [ ] **Step 1: Happy-path regression**

With phone paired to Mac (real device, not simulator, since the camera path is real-device only):

- Library image (PNG screenshot, small): sends, path pastes, file on disk matches bytes.
- Library image (large JPEG, e.g. 8 MB original): sends (recompressed), path pastes, file ≤ 10 MB on disk.
- Camera capture: sends, path pastes, file on disk is a valid JPEG.
- Remove (✕) before send: preview clears, nothing sent.
- Both portrait and landscape: same behavior in each.
- Switch active terminal window between picker and submit: path pastes into the window that was active at submit time.

- [ ] **Step 2: Error paths**

- Disconnect Mac mid-send: phone surfaces an error on the preview strip and keeps the image so the user can retry.
- Close target terminal window before sending: Mac returns "unknown window"; phone's preview strip shows the error.
- Deny photo library permission: library picker returns no image, no crash.
- Simulator (no camera): "Take Photo" option is hidden.

- [ ] **Step 3: Visual / compact-UI regression**

Confirm the input row's **idle** height is pixel-identical before and after this feature (strip renders nothing when empty). Compare against `git stash` of pre-feature build if needed.

- [ ] **Step 4: Final commit (if any fix-up was needed)**

```bash
git add -A
git commit -m "Small cleanups after kickin' the tires on the picture upload"
```

If no fix-ups were needed, skip this commit.

- [ ] **Step 5: Summary to user**

Report to the user:
- What was built (one sentence per commit).
- Any deviations from the PRD.
- Any open items from the PRD's "Open Questions" section that are still open.
- Remind the user that nothing has been pushed (per the eb-branch policy) — they can push when they're ready.

---

## Execution Order & Dependencies

```
Task 1 (protocol) ──────────────────┐
                                    ├─► Task 3 (Mac dispatch)
Task 2 (Mac handler) ───────────────┘
                                    │
Task 4 (Info.plist) ────────┐       │
Task 5 (recompressor) ──────┼───────┼─► Task 12 (submit flow)
Task 6 (pending state) ─────┤       │
Task 7 (preview strip) ─────┤       │
Task 8 (pickers) ───────────┤       │
Task 9 (WS receive) ────────┘       │
                                    │
Task 10 (portrait UI) ──────┐       │
Task 11 (landscape UI) ─────┴───────┘

                      ↓
                  Task 13 (E2E verification)
```

Tasks 1, 2, 4, 5, 6, 7, 8, 9 can each run independently and in any order. Tasks 3, 10, 11 depend on their prerequisites. Task 12 depends on everything before it. Task 13 is final.

---

## Notes for the Executing Engineer

- **Match existing style.** Every new file imports and formats the same way as its sibling files. If the existing code uses `NSLog` for diagnostics, use `NSLog`. If it uses SwiftUI `@ObservedObject`, do the same.
- **Don't touch `KeystrokeInjector.swift`.** The image-path injection uses it as-is.
- **Don't push.** `eb-branch` policy: commits stay local until the repo owner says otherwise.
- **Commit voice.** Every commit message follows the "blue-collar boomer" voice from `CLAUDE.md`. Short, punchy, no jargon.
- **Do UI verification on a real device** for the camera path. Simulator lacks a camera, so "Take Photo" won't exercise there.
- **Don't add scope.** No multi-image, no cropping, no clipboard paste — those are explicitly non-goals in the PRD.
