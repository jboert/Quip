import XCTest
@testable import Quip

/// Locks the `quip://pair?url=<base64-no-pad>&pin=<digits>` wire format so the
/// shared pairing-link contract (Shared/PairingPayload.swift) cannot silently
/// regress. The Mac renders `encodedURL()` into a QR / share link; the phone
/// runs `decode(...)` on tap-to-pair and on the in-app scanner, falling back to
/// treating the raw string as a plain ws(s):// URL when `decode` returns nil.
final class PairingPayloadTests: XCTestCase {

    // MARK: Round-trip

    func testRoundTripPreservesURLAndPIN() {
        let original = PairingPayload(url: "wss://abc-def.trycloudflare.com/ws", pin: "482913")
        guard let encoded = original.encodedURL() else {
            return XCTFail("encodedURL() returned nil for a normal wss URL")
        }
        let decoded = PairingPayload.decode(encoded)
        XCTAssertEqual(decoded?.url, original.url)
        XCTAssertEqual(decoded?.pin, original.pin)
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripPlainLANURL() {
        let original = PairingPayload(url: "ws://192.168.1.42:8765", pin: "000000")
        let decoded = original.encodedURL().flatMap(PairingPayload.decode)
        XCTAssertEqual(decoded, original)
    }

    // MARK: Encoded shape + base64 re-padding

    func testEncodedURLHasQuipPairShapeAndStrippedPadding() {
        let encoded = PairingPayload(url: "wss://example.ts.net/ws", pin: "123456").encodedURL()
        guard let encoded, let comps = URLComponents(string: encoded) else {
            return XCTFail("encodedURL() did not produce a parseable URL")
        }
        XCTAssertEqual(comps.scheme, "quip")
        XCTAssertEqual(comps.host, "pair")
        let urlValue = comps.queryItems?.first(where: { $0.name == "url" })?.value
        XCTAssertNotNil(urlValue)
        // Padding is stripped to keep the QR small.
        XCTAssertFalse(urlValue?.contains("=") ?? true, "base64 padding should be stripped")
    }

    func testHandCraftedUnpaddedBase64DecodesWithRepadding() {
        // "ws://a" base64-encodes to "d3M6Ly9h" (no padding needed here), but pick
        // a body whose length forces padding so we exercise the re-pad branch.
        let url = "wss://host.local:8765/ws"  // length not a multiple of 3 -> base64 needs padding
        let b64NoPad = Data(url.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertFalse(b64NoPad.contains("="), "precondition: test fixture is unpadded")
        let raw = "quip://pair?url=\(b64NoPad)&pin=778899"
        let decoded = PairingPayload.decode(raw)
        XCTAssertEqual(decoded?.url, url)
        XCTAssertEqual(decoded?.pin, "778899")
    }

    // MARK: Malformed input -> nil

    func testWrongSchemeReturnsNil() {
        let b64 = Data("wss://x/ws".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertNil(PairingPayload.decode("https://pair?url=\(b64)&pin=123456"))
    }

    func testWrongHostReturnsNil() {
        let b64 = Data("wss://x/ws".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertNil(PairingPayload.decode("quip://window?url=\(b64)&pin=123456"))
    }

    func testMissingURLReturnsNil() {
        XCTAssertNil(PairingPayload.decode("quip://pair?pin=123456"))
    }

    func testMissingPINReturnsNil() {
        let b64 = Data("wss://x/ws".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertNil(PairingPayload.decode("quip://pair?url=\(b64)"))
    }

    func testEmptyPINReturnsNil() {
        let b64 = Data("wss://x/ws".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertNil(PairingPayload.decode("quip://pair?url=\(b64)&pin="))
    }

    func testNonBase64URLReturnsNil() {
        // "!!!!" is outside the base64 alphabet, so Data(base64Encoded:) fails.
        XCTAssertNil(PairingPayload.decode("quip://pair?url=!!!!&pin=123456"))
    }

    // MARK: Plain ws(s):// non-quip strings -> nil (caller falls back to raw URL)

    func testPlainWSURLDecodesToNil() {
        XCTAssertNil(PairingPayload.decode("ws://192.168.1.42:8765"))
    }

    func testPlainWSSURLDecodesToNil() {
        XCTAssertNil(PairingPayload.decode("wss://abc.trycloudflare.com/ws"))
    }

    func testGarbageStringDecodesToNil() {
        XCTAssertNil(PairingPayload.decode("not a url at all"))
    }
}
