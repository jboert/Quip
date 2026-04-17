import Foundation
import CryptoKit

/// Errors surfaced from `APNsClient.send(...)`. The distinct cases let
/// the Settings UI and the auto-remove path respond differently: an
/// `unregistered` token → drop from the device store, a `throttled` →
/// retry once, `badKey` → surface an inline error in the Settings pane.
enum APNsError: Error, Equatable {
    case missingKey
    case invalidKey(String)
    case badRequest(String)
    case unregistered      // 410 / BadDeviceToken / Unregistered — drop the device
    case throttled         // 429 / 503 — retry later
    case serverError(Int)  // 5xx other than 503
    case unknown(Int, String)
}

/// Token signed with the APNs auth key. APNs rejects JWTs older than 60
/// minutes, so we cache and rotate at 50min to leave headroom.
private struct CachedJWT {
    let token: String
    let issuedAt: Date
    var isExpired: Bool {
        Date().timeIntervalSince(issuedAt) > 50 * 60
    }
}

/// Signs ES256 JWTs with the .p8 key and POSTs them + the alert payload
/// to Apple's HTTP/2 APNs endpoint. URLSession on macOS 14+ auto-upgrades
/// to HTTP/2 when the server supports it, so we don't need a separate
/// HTTP/2 client library.
///
/// Usage (from QuipMacApp):
/// ```
/// let client = APNsClient(keyId: ..., teamId: ..., bundleId: ...)
/// try await client.send(payload: [...], toDevice: device)
/// ```
///
/// Actor so the cached JWT + send pipeline can be reached from
/// background tasks safely. Construction throws because we parse the
/// .p8 key up-front — constructing many short-lived clients is fine
/// (one ES256 init is cheap; the JWT sign is the only expensive op).
actor APNsClient {
    let keyId: String
    let teamId: String
    let bundleId: String
    private let session: URLSession
    private var cachedJWT: CachedJWT?
    /// Stored once at init so we don't re-read Keychain on every send.
    private let privateKey: P256.Signing.PrivateKey?

    /// Throws APNsError.invalidKey if the stored .p8 can't be parsed.
    /// Throws APNsError.missingKey if no key is stored yet.
    init(keyId: String, teamId: String, bundleId: String, session: URLSession = .shared) throws {
        self.keyId = keyId
        self.teamId = teamId
        self.bundleId = bundleId
        self.session = session

        guard let pemData = APNsKeyStore.get() else {
            self.privateKey = nil
            throw APNsError.missingKey
        }
        guard let pem = String(data: pemData, encoding: .utf8) else {
            self.privateKey = nil
            throw APNsError.invalidKey("key bytes are not valid UTF-8")
        }
        do {
            self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            self.privateKey = nil
            throw APNsError.invalidKey("CryptoKit couldn't parse PEM: \(error.localizedDescription)")
        }
    }

    /// Build a fresh JWT. Exposed as `internal` so tests can verify the
    /// signature shape against the public key. Callers should prefer
    /// `send(...)` which handles caching.
    func makeJWT(now: Date = Date()) throws -> String {
        guard let privateKey else { throw APNsError.missingKey }

        // Header: {"alg":"ES256","kid":"<keyId>"}
        let header: [String: String] = ["alg": "ES256", "kid": keyId]
        // Payload: {"iss":"<teamId>","iat":<seconds-since-epoch>}
        let payload: [String: Any] = ["iss": teamId, "iat": Int(now.timeIntervalSince1970)]

        guard let headerData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            throw APNsError.invalidKey("could not serialize JWT header/payload")
        }

        let headerB64 = Self.base64URLEncode(headerData)
        let payloadB64 = Self.base64URLEncode(payloadData)
        let signingInput = "\(headerB64).\(payloadB64)"
        guard let signingInputData = signingInput.data(using: .utf8) else {
            throw APNsError.invalidKey("ASCII encode failed")
        }
        let signature = try privateKey.signature(for: signingInputData)
        // ECDSA signature is 64 bytes raw (r || s); that's the JWS/JWT
        // expected form. CryptoKit's `.rawRepresentation` gives exactly that.
        let sigB64 = Self.base64URLEncode(signature.rawRepresentation)
        return "\(signingInput).\(sigB64)"
    }

    /// Base64url per RFC 7515: standard base64, minus trailing padding,
    /// with `+`→`-` and `/`→`_`.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func currentJWT() throws -> String {
        if let cached = cachedJWT, !cached.isExpired {
            return cached.token
        }
        let fresh = try makeJWT()
        cachedJWT = CachedJWT(token: fresh, issuedAt: Date())
        return fresh
    }

    /// Send a pre-encoded JSON alert payload to a single device. On
    /// APNs 410 / Unregistered / BadDeviceToken, throws `.unregistered`
    /// so the caller can drop the device from storage. On 429/503,
    /// retries ONCE with a 2s backoff before surfacing `.throttled`.
    ///
    /// Payload is passed as Data (not [String: Any]) so it crosses
    /// concurrency domains cleanly — [String: Any] isn't Sendable in
    /// Swift 6 strict mode.
    func send(payloadData body: Data, toDevice device: RegisteredPushDevice) async throws {
        let host = device.environment == "production"
            ? "api.push.apple.com"
            : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(device.token)") else {
            throw APNsError.badRequest("invalid device token format")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue(bundleId, forHTTPHeaderField: "apns-topic")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue("bearer \(try currentJWT())", forHTTPHeaderField: "authorization")

        do {
            try await performSend(request: request, isRetry: false)
        } catch APNsError.throttled {
            // One retry with a small backoff. If the second attempt
            // also gets throttled, surface the error — caller decides
            // whether to show it in the UI or silently drop.
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try await performSend(request: request, isRetry: true)
        }
    }

    private func performSend(request: URLRequest, isRetry: Bool) async throws {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APNsError.unknown(-1, "non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            return
        case 400:
            let reason = Self.extractReason(from: data)
            if reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic" || reason == "Unregistered" {
                throw APNsError.unregistered
            }
            throw APNsError.badRequest(reason)
        case 403:
            // Usually InvalidProviderToken (bad JWT). Surface so the
            // Settings UI can prompt the user to re-upload the .p8.
            let reason = Self.extractReason(from: data)
            throw APNsError.invalidKey(reason)
        case 410:
            throw APNsError.unregistered
        case 429, 503:
            if isRetry { throw APNsError.throttled }
            throw APNsError.throttled
        case 500...599:
            throw APNsError.serverError(http.statusCode)
        default:
            let reason = Self.extractReason(from: data)
            throw APNsError.unknown(http.statusCode, reason)
        }
    }

    /// APNs error bodies are `{"reason":"<string>"}`. Extract it or
    /// return an empty string so the error message isn't just garbage.
    private static func extractReason(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = obj["reason"] as? String else { return "" }
        return reason
    }
}
