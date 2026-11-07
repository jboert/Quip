import XCTest
import CoreGraphics
@testable import Quip

/// Q-91 spec 10.2: the Mac-only rules' cross-language vectors. Each test runs
/// every case of a `Shared/Tests/Fixtures/vectors/*.json` file through the real
/// Mac code, so the vectors the Rust Windows host is held to are proven true
/// on the Mac. See `VectorFixture` (Shared/Tests) for the file shape and how
/// `expect` is (re)generated.

final class MultiLineVectorTests: XCTestCase {

    private struct Input: Decodable {
        let text: String
        let cliKind: CLIKind
        let terminalApp: TerminalApp
        let pressReturn: Bool
    }

    func testEveryVector() throws {
        try VectorFixture.run("vectors/multiline.json", section: "cases", input: Input.self, minimumCases: 50) { v in
            let normalized = MultiLineSendPolicy.normalizedText(v.text)
            let decision = MultiLineSendPolicy.decide(text: v.text, cliKind: v.cliKind,
                                                      terminalApp: v.terminalApp, pressReturn: v.pressReturn)
            return [
                "normalizedText": normalized,
                "isMultiLine": MultiLineSendPolicy.isMultiLine(normalized),
                "lineCount": MultiLineSendPolicy.lineCount(normalized),
                "route": decision.route.rawValue,
                "pressReturn": decision.pressReturn,
                "latencySuffix": MultiLineSendPolicy.latencySuffix(requestedReturn: v.pressReturn,
                                                                   decidedReturn: decision.pressReturn,
                                                                   text: v.text),
            ] as [String: Any]
        }
    }
}

private struct VectorError: Error, CustomStringConvertible {
    let description: String
}

/// `kind` in the vectors → a bundle id with that classification. A kind the
/// vectors do not define is an error, not "other".
private func bundleId(forKind kind: String) throws -> String {
    switch kind {
    case "terminal": return TerminalApp.iterm2.bundleIdentifier
    case "simulator": return "com.apple.iphonesimulator"
    case "other": return "com.example.other-app"
    default: throw VectorError(description: "unknown window kind \(kind)")
    }
}

private func managedWindow(id: String, bundleId: String, enabled: Bool, onVisibleScreen: Bool = true,
                           bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> ManagedWindow {
    ManagedWindow(id: id, name: id, app: bundleId, subtitle: "", bundleId: bundleId, icon: nil,
                  isEnabled: enabled, assignedColor: "#F5A623", pid: 1, windowNumber: 0,
                  bounds: bounds, iterm2SessionId: nil, isOnVisibleScreen: onVisibleScreen)
}

@MainActor
final class BroadcastFilterVectorTests: XCTestCase {

    private struct Input: Decodable {
        struct Window: Decodable { let id: String; let kind: String; let enabled: Bool; let onVisibleScreen: Bool }
        let windows: [Window]
        let mirrorDesktop: Bool
        let mirrorAllApps: Bool
        let qaPair: [String]?
    }

    func testEveryVector() throws {
        try VectorFixture.run("vectors/broadcast_filter.json", section: "cases", input: Input.self,
                              minimumCases: 10) { v in
            let all = try v.windows.map {
                managedWindow(id: $0.id, bundleId: try bundleId(forKind: $0.kind), enabled: $0.enabled,
                              onVisibleScreen: $0.onVisibleScreen)
            }
            for (window, raw) in zip(all, v.windows) {
                // The vector's kind must mean what the Mac derives from the bundle id.
                XCTAssertEqual(window.isTerminal, raw.kind == "terminal", raw.id)
                XCTAssertEqual(window.isTarget, raw.kind == "simulator", raw.id)
            }
            if let ids = v.qaPair, ids.count != 2 {
                throw VectorError(description: "qaPair must hold exactly 2 ids, got \(ids)")
            }
            let pair = v.qaPair.map { ($0[0], $0[1]) }
            return WindowManager.windowsForBroadcast(all, mirrorDesktop: v.mirrorDesktop,
                                                     mirrorAllApps: v.mirrorAllApps, qaPair: pair).map(\.id)
        }
    }
}

final class ArrangeVectorTests: XCTestCase {

    private struct Input: Decodable {
        let layout: ArrangeLayout
        let windowCount: Int
        let targetRect: VectorRect
    }

    func testEveryVector() throws {
        try VectorFixture.run("vectors/arrange.json", section: "cases", input: Input.self, minimumCases: 28) { v in
            let mode = LayoutMode.from(arrangeLayout: v.layout)
            let area = CGRect(x: v.targetRect.x, y: v.targetRect.y, width: v.targetRect.width, height: v.targetRect.height)
            let frames = LayoutCalculator.calculate(mode: mode, windowCount: v.windowCount)
            return [
                "mode": mode.rawValue,
                "normalized": frames.map { VectorFixture.rect($0.x, $0.y, $0.width, $0.height) },
                "rects": frames.map {
                    let r = $0.toCGRect(in: area)
                    return VectorFixture.rect(r.origin.x, r.origin.y, r.width, r.height)
                },
            ] as [String: Any]
        }
    }
}

final class InjectionLogVectorTests: XCTestCase {

    private struct Input: Decodable {
        let op: String
        let window: String
        let app: TerminalApp?
        let kind: String?
        let message: String
        let detail: String
        let redact: Bool
    }

    private static func injectionError(_ kind: String?, message: String) throws -> KeystrokeInjector.InjectionError? {
        switch kind {
        case nil: return nil
        case "sessionNotFound"?: return .sessionNotFound
        case "tccDenied"?: return .tccDenied
        case "windowClosed"?: return .windowClosed
        case "unknown"?: return .unknown(message)
        case let other?: throw VectorError(description: "unknown injection kind \(other)")
        }
    }

    func testEveryVector() throws {
        try VectorFixture.run("vectors/injection_log.json", section: "cases", input: Input.self,
                              minimumCases: 15) { v in
            // `redact` mirrors what `logInjectionFailure` does before it builds the line.
            let message = v.redact ? SecretRedactor.redact(v.message) : v.message
            let detail = v.redact && !v.detail.isEmpty ? SecretRedactor.redact(v.detail) : v.detail
            return KeystrokeInjector.injectionLogLine(op: v.op, windowId: v.window, terminalApp: v.app,
                                                      kind: try Self.injectionError(v.kind, message: v.message),
                                                      message: message, detail: detail)
        }
    }
}

final class WindowColorMacVectorTests: XCTestCase {

    private let file = "vectors/window_color.json"

    private struct FirstUnusedInput: Decodable { let avoiding: [String] }
    private struct AvoidInput: Decodable { let all: [String]; let shown: [String] }

    func testFirstUnused() throws {
        try VectorFixture.run(file, section: "first_unused", input: FirstUnusedInput.self, minimumCases: 4) {
            VectorFixture.orNull(WindowManager.firstUnusedPaletteColor(avoiding: Set($0.avoiding)))
        }
    }

    func testColorsToAvoid() throws {
        try VectorFixture.run(file, section: "colors_to_avoid", input: AvoidInput.self, minimumCases: 2) {
            WindowManager.colorsToAvoid(all: Set($0.all), shown: Set($0.shown)).sorted()
        }
    }
}

/// The geometry vectors' window `frame` is what the Mac really broadcasts: the
/// broadcast path normalizes with `ManagedWindow.toWindowState(screenBounds:)`,
/// not with `DisplayGeometry.normalize`, so hold that path to the same numbers.
final class DisplayGeometryBroadcastPathTests: XCTestCase {

    private struct SceneInput: Decodable {
        struct Display: Decodable { let id: String; let isPrimary: Bool; let rect: VectorRect }
        let displays: [Display]
        let windows: [VectorRect]
    }

    func testToWindowStateMatchesTheVectorFrames() throws {
        guard !VectorFixture.writeMode else { return }
        let url = VectorFixture.url("vectors/display_geometry.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let scenes = try XCTUnwrap(root["scenes"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(scenes.count, 10)
        var compared = 0, zeroSizeDisplay = 0, noDisplay = 0
        for scene in scenes {
            let name = scene["name"] as? String ?? "?"
            let input = try JSONDecoder().decode(SceneInput.self,
                                                 from: JSONSerialization.data(withJSONObject: scene["input"]!))
            let expect = try XCTUnwrap(scene["expect"] as? [String: Any], name)
            let windows = try XCTUnwrap(expect["windows"] as? [[String: Any]], name)
            XCTAssertEqual(input.windows.count, windows.count, "\(name): one expect per window")
            for (raw, expected) in zip(input.windows, windows) {
                guard let id = expected["displayID"] as? String else {
                    // No displays at all: the vector has no frame; the Mac
                    // falls back to NSScreen.main, which a test cannot pin.
                    XCTAssertTrue(expected["frame"] is NSNull, "\(name): no display means no frame")
                    noDisplay += 1
                    continue
                }
                let display = try XCTUnwrap(input.displays.first(where: { $0.id == id }), name)
                let screen = CGRect(x: display.rect.x, y: display.rect.y,
                                    width: display.rect.width, height: display.rect.height)
                let bounds = CGRect(x: raw.x, y: raw.y, width: raw.width, height: raw.height)
                let window = managedWindow(id: "w", bundleId: TerminalApp.iterm2.bundleIdentifier, enabled: true,
                                           bounds: bounds)
                let f = window.toWindowState(screenBounds: screen).frame
                let actual = VectorFixture.rect(f.x, f.y, f.width, f.height)
                if screen.width <= 0 || screen.height <= 0 {
                    // Known Mac quirk, NOT part of the contract: against a
                    // zero-size display the broadcast path sends the raw pixel
                    // bounds, where the vector (DisplayGeometry.normalize) says
                    // a zero frame. Pin both so a change to either is seen.
                    XCTAssertNil(JSONCompare.difference(expected["frame"]!, VectorFixture.rect(0, 0, 0, 0),
                                                        path: "frame", tolerance: 0), name)
                    XCTAssertNil(JSONCompare.difference(VectorFixture.rect(raw.x, raw.y, raw.width, raw.height),
                                                        actual, path: "frame", tolerance: 0), name)
                    zeroSizeDisplay += 1
                    continue
                }
                if let d = JSONCompare.difference(expected["frame"]!, actual, path: "frame", tolerance: 1e-9) {
                    XCTFail("\(name): \(d)")
                }
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 0, "no frame was compared")
        XCTAssertGreaterThan(zeroSizeDisplay, 0, "the zero-size display scene went missing")
        XCTAssertGreaterThan(noDisplay, 0, "the empty display list scene went missing")
    }
}
