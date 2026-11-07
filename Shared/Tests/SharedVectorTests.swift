import XCTest
@testable import Quip

/// Q-91 spec 10.2: the Shared rules' cross-language vectors. Each test runs
/// every case of a `Fixtures/vectors/*.json` file through the real Swift code,
/// so the Swift side proves the vectors the Rust host is held to are true.
/// See `VectorFixture` for the file shape and how `expect` is (re)generated.

private func frameJSON(_ f: WindowFrame) -> [String: Any] {
    VectorFixture.rect(f.x, f.y, f.width, f.height)
}

private func displayRect(_ r: VectorRect) -> DisplayRect {
    DisplayRect(x: r.x, y: r.y, width: r.width, height: r.height)
}

final class DisplayGeometryVectorTests: XCTestCase {

    private let file = "vectors/display_geometry.json"

    private struct NormalizeInput: Decodable { let window: VectorRect; let display: VectorRect }
    private struct SpanInput: Decodable { let displays: [VectorRect] }
    private struct SceneInput: Decodable {
        struct Display: Decodable { let id: String; let isPrimary: Bool; let rect: VectorRect }
        let displays: [Display]
        let windows: [VectorRect]
    }

    func testNormalize() throws {
        try VectorFixture.run(file, section: "normalize", input: NormalizeInput.self, minimumCases: 5) {
            frameJSON(DisplayGeometry.normalize(window: displayRect($0.window), on: displayRect($0.display)))
        }
    }

    func testSpan() throws {
        try VectorFixture.run(file, section: "span", input: SpanInput.self, minimumCases: 4) {
            let s = DisplayGeometry.span(of: $0.displays.map(displayRect))
            return VectorFixture.rect(s.x, s.y, s.width, s.height)
        }
    }

    func testScenes() throws {
        try VectorFixture.run(file, section: "scenes", input: SceneInput.self, minimumCases: 10) {
            Self.scene($0)
        }
    }

    /// The Mac's broadcast composition, from Shared parts: span, each display's
    /// slot in it, each window's display, frame and merged-canvas frame.
    /// `QuipMacApp.buildDisplayGeometry` calls the same `aspect` / `spanAspect`.
    private static func scene(_ input: SceneInput) -> [String: Any] {
        let rects = input.displays.map { displayRect($0.rect) }
        let span = DisplayGeometry.span(of: rects)
        let slots = rects.map { DisplayGeometry.spanFrame(of: $0, in: span) }
        let tuples = input.displays.enumerated().map {
            (id: $0.element.id, isPrimary: $0.element.isPrimary, rect: rects[$0.offset])
        }
        let displays: [[String: Any]] = input.displays.enumerated().map { index, display in
            let rect = rects[index]
            return ["id": display.id,
                    "aspect": DisplayGeometry.aspect(of: rect),
                    "spanFrame": frameJSON(slots[index])]
        }
        let windows: [[String: Any]] = input.windows.map { raw in
            let window = displayRect(raw)
            guard let id = DisplayGeometry.displayID(forWindow: window, displays: tuples),
                  let index = input.displays.firstIndex(where: { $0.id == id }) else {
                return ["displayID": NSNull(), "frame": NSNull(), "spanFrame": NSNull()]
            }
            let frame = DisplayGeometry.normalize(window: window, on: rects[index])
            return ["displayID": id,
                    "frame": frameJSON(frame),
                    "spanFrame": frameJSON(DisplayGeometry.spanFrame(ofWindow: frame, onDisplay: slots[index]))]
        }
        return ["span": VectorFixture.rect(span.x, span.y, span.width, span.height),
                "spanAspect": VectorFixture.orNull(DisplayGeometry.spanAspect(of: span)),
                "displays": displays,
                "windows": windows]
    }
}

final class PairingVectorTests: XCTestCase {

    private let file = "vectors/pairing.json"

    private struct EncodeInput: Decodable { let url: String; let pin: String }
    private struct DecodeInput: Decodable { let raw: String }

    private static func json(_ p: PairingPayload?) -> Any {
        guard let p else { return NSNull() }
        return ["url": p.url, "pin": p.pin]
    }

    func testEncode() throws {
        try VectorFixture.run(file, section: "encode", input: EncodeInput.self, minimumCases: 5) {
            let encoded = PairingPayload(url: $0.url, pin: $0.pin).encodedURL()
            return ["encoded": VectorFixture.orNull(encoded),
                    "decodedBack": Self.json(encoded.flatMap(PairingPayload.decode))] as [String: Any]
        }
    }

    func testDecode() throws {
        try VectorFixture.run(file, section: "decode", input: DecodeInput.self, minimumCases: 15) {
            Self.json(PairingPayload.decode($0.raw))
        }
    }
}

/// A number, or "nan" / "inf" / "-inf" (JSON has no non-finite numbers).
struct VectorDouble: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d; return }
        switch try c.decode(String.self) {
        case "nan": value = .nan
        case "inf": value = .infinity
        case "-inf": value = -.infinity
        case let other:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a number: \(other)")
        }
    }
}

final class WindowColorVectorTests: XCTestCase {

    private let file = "vectors/window_color.json"

    private struct Empty: Decodable {}
    private struct NormalizedInput: Decodable { let raw: String }
    private struct HexInput: Decodable { let red: VectorDouble; let green: VectorDouble; let blue: VectorDouble }

    func testPalette() throws {
        try VectorFixture.run(file, section: "palette", input: Empty.self) { _ in WindowColor.palette }
    }

    func testNormalized() throws {
        try VectorFixture.run(file, section: "normalized", input: NormalizedInput.self, minimumCases: 8) {
            VectorFixture.orNull(WindowColor.normalized($0.raw))
        }
    }

    func testHex() throws {
        try VectorFixture.run(file, section: "hex", input: HexInput.self, minimumCases: 4) {
            WindowColor.hex(red: $0.red.value, green: $0.green.value, blue: $0.blue.value)
        }
    }
}
