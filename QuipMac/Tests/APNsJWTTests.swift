import XCTest
import CryptoKit
@testable import Quip

/// Verifies APNsClient.makeJWT produces a syntactically-correct ES256 JWT
/// whose signature verifies against the public key derived from the
/// private key we signed with.
///
/// We can't use a real Apple-provisioned .p8 in tests (secret-by-nature),
/// so we generate a fresh P256 keypair and inject its PEM straight into
/// APNsClient via `keyPEM:`. The suite must NEVER touch APNsKeyStore /
/// the real Keychain: SecItemCopyMatching under XCTest raises a GUI
/// authorization prompt that hung the whole Mac suite ~57 min
/// (wishlist 2026-07-13).
@MainActor
final class APNsJWTTests: XCTestCase {

    private var testPrivateKey: P256.Signing.PrivateKey!

    private var testPEM: Data {
        testPrivateKey.pemRepresentation.data(using: .utf8)!
    }

    override func setUpWithError() throws {
        testPrivateKey = P256.Signing.PrivateKey()
    }

    override func tearDownWithError() throws {
        testPrivateKey = nil
    }

    func test_makeJWT_producesThreeSegmentToken() async throws {
        let client = try APNsClient(keyId: "ABC123", teamId: "TEAM789", bundleId: "com.example", keyPEM: testPEM)
        let jwt = try await client.makeJWT()
        let parts = jwt.components(separatedBy: ".")
        XCTAssertEqual(parts.count, 3, "JWT must be header.payload.signature")
    }

    func test_makeJWT_headerContainsExpectedFields() async throws {
        let client = try APNsClient(keyId: "ABC123", teamId: "TEAM789", bundleId: "com.example", keyPEM: testPEM)
        let jwt = try await client.makeJWT()
        let headerB64 = jwt.components(separatedBy: ".")[0]
        let headerData = try decodeB64URL(headerB64)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: headerData) as? [String: Any])
        XCTAssertEqual(dict["alg"] as? String, "ES256")
        XCTAssertEqual(dict["kid"] as? String, "ABC123")
    }

    func test_makeJWT_payloadContainsIssAndRecentIat() async throws {
        let client = try APNsClient(keyId: "ABC123", teamId: "TEAM789", bundleId: "com.example", keyPEM: testPEM)
        let before = Int(Date().timeIntervalSince1970)
        let jwt = try await client.makeJWT()
        let after = Int(Date().timeIntervalSince1970)
        let payloadB64 = jwt.components(separatedBy: ".")[1]
        let payloadData = try decodeB64URL(payloadB64)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        XCTAssertEqual(dict["iss"] as? String, "TEAM789")
        let iat = try XCTUnwrap(dict["iat"] as? Int)
        XCTAssertGreaterThanOrEqual(iat, before)
        XCTAssertLessThanOrEqual(iat, after)
    }

    func test_makeJWT_signatureVerifiesAgainstPublicKey() async throws {
        let client = try APNsClient(keyId: "ABC123", teamId: "TEAM789", bundleId: "com.example", keyPEM: testPEM)
        let jwt = try await client.makeJWT()
        let parts = jwt.components(separatedBy: ".")
        let signingInput = "\(parts[0]).\(parts[1])".data(using: .utf8)!
        let sigData = try decodeB64URL(parts[2])
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: sigData)
        let publicKey = testPrivateKey.publicKey
        XCTAssertTrue(publicKey.isValidSignature(signature, for: signingInput),
                      "Signature must verify against the private key we signed with")
    }

    func test_makeJWT_rotatesAfterStaleness() async throws {
        let client = try APNsClient(keyId: "K", teamId: "T", bundleId: "b", keyPEM: testPEM)
        // Sign "now - 55 minutes" — older than the 50-min rotation threshold
        let stale = try await client.makeJWT(now: Date().addingTimeInterval(-55 * 60))
        let fresh = try await client.makeJWT(now: Date())
        XCTAssertNotEqual(stale, fresh, "New timestamp must produce a different JWT")
    }

    func test_init_throwsMissingKey_whenNoKeyAvailable() {
        XCTAssertThrowsError(try APNsClient(keyId: "K", teamId: "T", bundleId: "b", keyPEM: nil)) { error in
            XCTAssertEqual(error as? APNsError, .missingKey)
        }
    }

    func test_base64URLEncode_stripsPaddingAndReplacesChars() {
        // base64 of "hello?" is "aGVsbG8/" (trailing padding + /)
        let data = "hello?".data(using: .utf8)!
        let out = APNsClient.base64URLEncode(data)
        XCTAssertEqual(out, "aGVsbG8_")
    }

    // MARK: - helpers

    private func decodeB64URL(_ s: String) throws -> Data {
        var str = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad out to a multiple of 4
        while str.count % 4 != 0 { str += "=" }
        return try XCTUnwrap(Data(base64Encoded: str))
    }
}

/// Covers `APNsMetadataStore.keyId(fromFilename:)`, the parse that keeps the
/// JWT `kid` in sync with the imported .p8 so a (key, kid) mismatch can't
/// reach APNs and fail with `InvalidProviderToken`.
final class APNsMetadataKeyIdFromFilenameTests: XCTestCase {

    func test_extractsKeyId_fromCanonicalAppleFilename() {
        XCTAssertEqual(APNsMetadataStore.keyId(fromFilename: "AuthKey_JF568RHU89.p8"), "JF568RHU89")
        XCTAssertEqual(APNsMetadataStore.keyId(fromFilename: "AuthKey_M4XGA5PPAN.p8"), "M4XGA5PPAN")
    }

    func test_extractsKeyId_withoutExtension() {
        XCTAssertEqual(APNsMetadataStore.keyId(fromFilename: "AuthKey_ABCDE12345"), "ABCDE12345")
    }

    func test_acceptsUppercaseP8Extension() {
        XCTAssertEqual(APNsMetadataStore.keyId(fromFilename: "AuthKey_ABCDE12345.P8"), "ABCDE12345")
    }

    func test_returnsNil_forRenamedFile() {
        XCTAssertNil(APNsMetadataStore.keyId(fromFilename: "my-key.p8"))
        XCTAssertNil(APNsMetadataStore.keyId(fromFilename: "JF568RHU89.p8"))
    }

    func test_returnsNil_forWrongKeyIdLength() {
        XCTAssertNil(APNsMetadataStore.keyId(fromFilename: "AuthKey_TOOSHORT.p8"))      // 8 chars
        XCTAssertNil(APNsMetadataStore.keyId(fromFilename: "AuthKey_ELEVENCHARS1.p8"))  // 11 chars
    }

    func test_returnsNil_forLowercaseOrInvalidChars() {
        // Apple Key IDs are uppercase alphanumerics; a lowercase or symbol char
        // means it isn't a real key filename → leave the field untouched.
        XCTAssertNil(APNsMetadataStore.keyId(fromFilename: "AuthKey_jf568rhu89.p8"))
        XCTAssertNil(APNsMetadataStore.keyId(fromFilename: "AuthKey_JF568-HU89.p8"))
    }
}
