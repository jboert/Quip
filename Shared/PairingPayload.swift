// PairingPayload.swift
// Shared encode/decode for the QR-code pairing flow (wishlist §50).
// Mac renders the encoded URL into a QR; iPhone scans it, decodes, and
// pre-stages the PIN in Keychain so the user never has to type either.
//
// Wire format: `quip://pair?url=<base64-url-no-pad>&pin=<6digits>`
// Both fields are URL-query-encoded after base64. The url is base64'd
// so its `wss://...trycloudflare.com/...` body doesn't collide with
// the outer URL's parsing rules.

import Foundation

public struct PairingPayload: Sendable, Equatable {
    public let url: String
    public let pin: String

    public init(url: String, pin: String) {
        self.url = url
        self.pin = pin
    }

    /// Render to the `quip://pair?url=...&pin=...` form. Returns nil if
    /// the URL can't be UTF-8 encoded (shouldn't happen for normal
    /// http(s)/ws(s) URLs).
    public func encodedURL() -> String? {
        guard let urlData = url.data(using: .utf8) else { return nil }
        let urlB64 = urlData.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")  // strip padding for shorter QR
        var components = URLComponents()
        components.scheme = "quip"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "url", value: urlB64),
            URLQueryItem(name: "pin", value: pin),
        ]
        return components.url?.absoluteString
    }

    /// Parse a candidate URL string. Returns nil if it's not a `quip://pair?...`
    /// shape, doesn't carry both fields, or the base64 doesn't decode.
    /// Callers should fall back to treating the input as a plain `wss://`
    /// URL if this returns nil.
    public static func decode(_ raw: String) -> PairingPayload? {
        guard let comps = URLComponents(string: raw),
              comps.scheme == "quip",
              comps.host == "pair" else { return nil }
        guard let items = comps.queryItems else { return nil }
        guard let urlB64 = items.first(where: { $0.name == "url" })?.value,
              let pin = items.first(where: { $0.name == "pin" })?.value,
              !pin.isEmpty else { return nil }
        // Re-pad base64 if needed.
        let padded = urlB64 + String(repeating: "=", count: (4 - urlB64.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let url = String(data: data, encoding: .utf8) else { return nil }
        return PairingPayload(url: url, pin: pin)
    }
}
