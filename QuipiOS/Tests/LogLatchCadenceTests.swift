import XCTest
import Security
@testable import Quip

/// The swallowed-error sweep made silent failures audible — but it put several
/// of those `print`s on paths that REPEAT (SwiftUI `body`, every TLS handshake,
/// every reconnect, every Watch message) with causes that PERSIST. Those logs
/// would arrive hundreds of lines per second and bury the signal, which is the
/// same disease the sweep was meant to cure.
///
/// The existing loud-drop tests only pinned "a failure logs" for a SINGLE call,
/// so they passed while the flood existed. These pin the CADENCE:
///
///   * the same cause, hit over and over, logs exactly ONCE;
///   * a CHANGED cause logs again (latching is not muting);
///   * a success re-arms, so a failure that returns is reported again.
final class LogLatchCadenceTests: XCTestCase {

    // MARK: - LogLatch primitive

    func testSameCauseLogsOnceThenStaysQuiet() {
        let latch = LogLatch()
        XCTAssertTrue(latch.verdict(for: "boom").shouldLog, "First sighting must report")
        for _ in 0..<500 {
            XCTAssertFalse(latch.verdict(for: "boom").shouldLog,
                           "A persistent cause must not re-log")
        }
        XCTAssertEqual(latch.suppressedCount, 500)
    }

    func testChangedCauseLogsAgainAndCarriesSuppressedCount() {
        let latch = LogLatch()
        XCTAssertTrue(latch.verdict(for: "a").shouldLog)
        for _ in 0..<9 { _ = latch.verdict(for: "a") }

        let v = latch.verdict(for: "b")
        XCTAssertTrue(v.shouldLog, "A new cause deserves a fresh verdict")
        XCTAssertEqual(v.suppressedRepeats, 9, "The line must own up to the flood it replaced")
        XCTAssertTrue(v.suffix.contains("9 identical repeat(s)"), "Got: \(v.suffix)")
    }

    func testSuffixIsEmptyWhenNothingWasSuppressed() {
        XCTAssertEqual(LogLatch().verdict(for: "a").suffix, "")
    }

    func testSuccessReArmsTheLatch() {
        let latch = LogLatch()
        XCTAssertTrue(latch.verdict(for: "boom").shouldLog)
        XCTAssertFalse(latch.verdict(for: "boom").shouldLog)
        latch.noteSuccess()
        XCTAssertTrue(latch.verdict(for: "boom").shouldLog,
                      "A failure that RETURNS after a good run must be reported, not hidden")
    }

    // MARK: - Error fingerprints (the trap that defeats a latch silently)

    private struct Manifest: Decodable { let spkiHashes: [String] }

    /// One fault, one identity — whatever a `LogLatch` keys on has to survive
    /// being computed 50 times for the same failure, or the latch it feeds
    /// degrades into no latch at all and the path it protects floods. Corrupt
    /// JSON is precisely the fault that bare interpolation cannot key (see the
    /// counterexample below), so it is the one the fingerprint must pin.
    func testFingerprintIsStableAcrossIdenticalDecodeFailures() {
        let bad = Data("not json at all".utf8)
        var fingerprints = Set<String>()
        for _ in 0..<50 {
            do {
                _ = try JSONDecoder().decode(Manifest.self, from: bad)
                XCTFail("Expected a decode failure")
            } catch {
                fingerprints.insert(LogLatch.fingerprint(of: error))
            }
        }
        XCTAssertEqual(fingerprints.count, 1,
                       "One fault must have ONE identity, or nothing downstream can latch on it")
    }

    func testFingerprintDistinguishesDifferentFaults() {
        var seen: [String] = []
        for blob in ["not json at all", #"{"spkiHashes": 7}"#, "{}"] {
            do {
                _ = try JSONDecoder().decode(Manifest.self, from: Data(blob.utf8))
                XCTFail("Expected a decode failure for \(blob)")
            } catch {
                seen.append(LogLatch.fingerprint(of: error))
            }
        }
        XCTAssertEqual(Set(seen).count, 3,
                       "Corrupt JSON, a type mismatch and a missing key are three DIFFERENT faults "
                       + "and each deserves its own report. Got: \(seen)")
    }

    /// The rule, pinned by measurement, because "a DecodingError interpolates
    /// stably" is a half-truth that sends maintainers to the wrong fix.
    ///
    /// `typeMismatch` / `keyNotFound` / `valueNotFound` are Swift's own and DO
    /// render stably. `dataCorrupted` — what JSONDecoder returns for a malformed
    /// frame — carries the JSONSerialization NSError in its context and renders
    /// it, inheriting the unstable userInfo key order. So the nondeterminism is
    /// always an NSError's, and it reaches errors that are not one. No call site
    /// should have to know which case it will be handed: key on the shape.
    func testInterpolationIsUnstableForCorruptJSON_butTheFingerprintIsNot() {
        let bad = Data("not json at all".utf8)
        var rendered = Set<String>()
        var fingerprints = Set<String>()
        for _ in 0..<200 {
            do {
                _ = try JSONDecoder().decode(Manifest.self, from: bad)
                XCTFail("Expected a decode failure")
            } catch {
                rendered.insert("\(error)")
                fingerprints.insert(LogLatch.fingerprint(of: error))
            }
        }
        XCTAssertGreaterThan(rendered.count, 1,
                             "if this ever holds at 1, the platform changed — but a latch must not "
                             + "depend on that: dataCorrupted renders an NSError's userInfo")
        XCTAssertEqual(fingerprints.count, 1,
                       "the fingerprint is what a latch may key on, in every DecodingError case")
    }

    /// The stable half of the same rule, kept explicit so nobody "fixes" a
    /// schema-drift gate that is already correct.
    func testInterpolationIsStableForSwiftsOwnDecodingErrorCases() {
        var rendered = Set<String>()
        for _ in 0..<50 {
            do {
                _ = try JSONDecoder().decode(Manifest.self, from: Data(#"{"spkiHashes": 7}"#.utf8))
                XCTFail("Expected a type mismatch")
            } catch {
                rendered.insert("\(error)")
            }
        }
        XCTAssertEqual(rendered.count, 1, "typeMismatch has no NSError under it")
    }

    func testFingerprintFallsBackToDomainAndCodeForNonDecodingErrors() {
        let a = NSError(domain: "quip.test", code: 42, userInfo: ["a": 1, "b": 2, "c": 3])
        let b = NSError(domain: "quip.test", code: 42, userInfo: ["z": 9])
        XCTAssertEqual(LogLatch.fingerprint(of: a), LogLatch.fingerprint(of: b),
                       "userInfo must not leak into the key — its print order is unstable")
        XCTAssertNotEqual(LogLatch.fingerprint(of: a),
                          LogLatch.fingerprint(of: NSError(domain: "quip.test", code: 43)))
    }

    // MARK: - KeyedLogLatch

    func testKeyedLatchIsIndependentPerSubject() {
        let latch = KeyedLogLatch()
        XCTAssertTrue(latch.verdict(for: "backendA", cause: "OSStatus=-25308").shouldLog)
        XCTAssertFalse(latch.verdict(for: "backendA", cause: "OSStatus=-25308").shouldLog)
        XCTAssertTrue(latch.verdict(for: "backendB", cause: "OSStatus=-25308").shouldLog,
                      "A broken backend A must not mask backend B's first failure")
        XCTAssertTrue(latch.verdict(for: "backendA", cause: "OSStatus=-34018").shouldLog,
                      "A changed status on the same backend is a new cause")
    }

    func testKeyedLatchSuccessReArmsOnlyThatSubject() {
        let latch = KeyedLogLatch()
        _ = latch.verdict(for: "a", cause: "x")
        _ = latch.verdict(for: "b", cause: "x")
        latch.noteSuccess(for: "a")
        XCTAssertTrue(latch.verdict(for: "a", cause: "x").shouldLog)
        XCTAssertFalse(latch.verdict(for: "b", cause: "x").shouldLog,
                       "b never recovered — stay latched")
    }

    // MARK: - Store decoders (the render-cadence case)

    /// `effectiveQuickSlots` / `customButtonDefs` are COMPUTED PROPERTIES read
    /// from `body`, and `MainiOSView` re-renders on every output_delta. With a
    /// corrupt blob that is 3+ decodes per render, hundreds per second while
    /// terminal output streams. One line, no matter how many renders.
    func testQuickSlotDecodeOfSameCorruptBlobLogsOnceAcrossManyRenders() {
        let latch = LogLatch()
        var logs: [String] = []
        let corrupt = "{ this is not json"

        for _ in 0..<300 {
            let out = QuickSlotStore.decode(corrupt, log: { logs.append($0) }, latch: latch)
            XCTAssertTrue(out.isEmpty, "Fallback semantics must be unchanged on every call")
        }

        XCTAssertEqual(logs.count, 1, "300 renders of one corrupt blob must not mean 300 lines")
        XCTAssertTrue(logs[0].contains("quickSlots decode FAILED"))
    }

    func testQuickSlotDecodeOfChangedCorruptBlobLogsAgain() {
        let latch = LogLatch()
        var logs: [String] = []
        for _ in 0..<5 { _ = QuickSlotStore.decode("{ bad one", log: { logs.append($0) }, latch: latch) }
        for _ in 0..<5 { _ = QuickSlotStore.decode("{ bad two", log: { logs.append($0) }, latch: latch) }

        XCTAssertEqual(logs.count, 2, "A DIFFERENT corrupt blob is a different cause and must report")
        XCTAssertTrue(logs[1].contains("4 identical repeat(s)"),
                      "The second line must disclose the repeats it suppressed. Got: \(logs[1])")
    }

    /// The user fixes their row (or the Mac restores a good snapshot) and it
    /// later goes bad again — that recurrence must be visible.
    func testQuickSlotDecodeSuccessReArmsSoARecurrenceIsReported() {
        let latch = LogLatch()
        var logs: [String] = []
        let corrupt = "{ this is not json"
        let good = QuickSlotStore.encode(QuickSlotStore.defaultSlots(demoCustomID: UUID()))

        _ = QuickSlotStore.decode(corrupt, log: { logs.append($0) }, latch: latch)
        _ = QuickSlotStore.decode(corrupt, log: { logs.append($0) }, latch: latch)
        XCTAssertEqual(logs.count, 1)

        let ok = QuickSlotStore.decode(good, log: { logs.append($0) }, latch: latch)
        XCTAssertFalse(ok.isEmpty, "Valid blob still decodes")
        XCTAssertEqual(logs.count, 1, "A good decode must not log")

        _ = QuickSlotStore.decode(corrupt, log: { logs.append($0) }, latch: latch)
        XCTAssertEqual(logs.count, 2, "Corruption that RETURNS must be reported again")
    }

    func testCustomButtonDecodeOfSameCorruptBlobLogsOnceAcrossManyRenders() {
        let latch = LogLatch()
        var logs: [String] = []
        let corrupt = #"[{"label":"oops"}]"#

        for _ in 0..<300 {
            XCTAssertTrue(CustomButtonStore.decode(corrupt, log: { logs.append($0) }, latch: latch).isEmpty)
        }

        XCTAssertEqual(logs.count, 1, "Custom-button defs decode 2+ times per render — still one line")
        XCTAssertTrue(logs[0].contains("customButtons decode FAILED"))
    }

    func testCustomButtonDecodeOfChangedCorruptBlobLogsAgain() {
        let latch = LogLatch()
        var logs: [String] = []
        _ = CustomButtonStore.decode(#"[{"label":"a"}]"#, log: { logs.append($0) }, latch: latch)
        _ = CustomButtonStore.decode(#"[{"label":"b"}]"#, log: { logs.append($0) }, latch: latch)
        XCTAssertEqual(logs.count, 2)
    }

    // MARK: - Cert-pin loader (per-TLS-handshake cadence)

    func testDocumentsPinOverrideUnusableLogsOncePerCause() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quip-cert-pins-\(UUID().uuidString).json")
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let latch = LogLatch()
        var logs: [String] = []
        // Stands in for many handshakes, each of which used to read the pin set
        // once per certificate in the chain.
        for _ in 0..<50 {
            let pins = CloudflareCertificatePinningDelegate.loadFromDocuments(
                url: url, latch: latch, log: { logs.append($0) })
            XCTAssertNil(pins, "Fallback semantics unchanged: an unusable override yields nil")
        }

        XCTAssertEqual(logs.count, 1, "A reconnect storm must not become a log storm")
        XCTAssertTrue(logs[0].contains("UNUSABLE"))
    }

    func testDocumentsPinOverrideValidLoadsAndAnnouncesItselfOnce() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quip-cert-pins-\(UUID().uuidString).json")
        try #"{"spkiHashes":["aaa=","bbb="]}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let latch = LogLatch()
        var logs: [String] = []
        for _ in 0..<20 {
            let pins = CloudflareCertificatePinningDelegate.loadFromDocuments(
                url: url, latch: latch, log: { logs.append($0) })
            XCTAssertEqual(pins, ["aaa=", "bbb="], "Pin set must be returned unchanged every time")
        }
        XCTAssertEqual(logs.count, 1, "Even the success line is per-handshake — announce once")
    }

    func testMissingDocumentsOverrideStaysSilent() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("quip-absent-\(UUID().uuidString).json")
        var logs: [String] = []
        let pins = CloudflareCertificatePinningDelegate.loadFromDocuments(
            url: missing, latch: LogLatch(), log: { logs.append($0) })
        XCTAssertNil(pins)
        XCTAssertTrue(logs.isEmpty, "No override file is the NORMAL case — not an error")
    }

    func testMissingBundledPinsLogsOnce() {
        let latch = LogLatch()
        var logs: [String] = []
        for _ in 0..<50 {
            let pins = CloudflareCertificatePinningDelegate.loadFromBundle(
                url: nil, latch: latch, log: { logs.append($0) })
            XCTAssertNil(pins, "Falls back to the hardcoded set, as before")
        }
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("missing from bundle"))
    }

    func testUnusableBundledPinsLogsOnce() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quip-bundle-pins-\(UUID().uuidString).json")
        try "{".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let latch = LogLatch()
        var logs: [String] = []
        for _ in 0..<50 {
            XCTAssertNil(CloudflareCertificatePinningDelegate.loadFromBundle(
                url: url, latch: latch, log: { logs.append($0) }))
        }
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("UNUSABLE"))
    }

    /// The hardcoded fallback must still be reachable — latching the log must
    /// not have changed what the pin check actually pins against.
    func testPinnedHashesAlwaysResolveToANonEmptySet() {
        XCTAssertFalse(CloudflareCertificatePinningDelegate.pinnedSPKIHashes.isEmpty)
    }

    // MARK: - Keychain (per-reconnect cadence)

    func testBackendPINLockedKeychainLogsOncePerBackendNotPerReconnect() {
        let latch = KeyedLogLatch()
        // errSecInteractionNotAllowed: the documented case — auto-connect at
        // launch, before the first unlock. It persists across every retry.
        let locked: OSStatus = -25308

        var lines: [String] = []
        for _ in 0..<20 {
            for backend in ["backend-1", "backend-2"] {
                if let l = KeychainBackendPINs.failureLine(status: locked, backendID: backend, latch: latch) {
                    lines.append(l)
                }
            }
        }
        XCTAssertEqual(lines.count, 2, "One line per backend, not one per reconnect × backend")
        XCTAssertTrue(lines.allSatisfy { $0.contains("PIN read FAILED") })
    }

    func testBackendPINChangedStatusIsReportedAgain() {
        let latch = KeyedLogLatch()
        XCTAssertNotNil(KeychainBackendPINs.failureLine(status: -25308, backendID: "b", latch: latch))
        XCTAssertNil(KeychainBackendPINs.failureLine(status: -25308, backendID: "b", latch: latch))
        XCTAssertNotNil(KeychainBackendPINs.failureLine(status: -34018, backendID: "b", latch: latch),
                        "errSecMissingEntitlement is a different fault than a locked keychain")
    }

    func testBackendPINOrdinaryStatusesNeverLogAndReArm() {
        let latch = KeyedLogLatch()
        XCTAssertNil(KeychainBackendPINs.failureLine(status: errSecSuccess, backendID: "b", latch: latch))
        XCTAssertNil(KeychainBackendPINs.failureLine(status: errSecItemNotFound, backendID: "b", latch: latch),
                     "No PIN saved for this backend is ORDINARY — never an error")

        XCTAssertNotNil(KeychainBackendPINs.failureLine(status: -25308, backendID: "b", latch: latch))
        XCTAssertNil(KeychainBackendPINs.failureLine(status: -25308, backendID: "b", latch: latch))
        // Keychain unlocks, then re-locks (device locked again while backgrounded).
        XCTAssertNil(KeychainBackendPINs.failureLine(status: errSecSuccess, backendID: "b", latch: latch))
        XCTAssertNotNil(KeychainBackendPINs.failureLine(status: -25308, backendID: "b", latch: latch),
                        "A fault that returns after a good read must be reported again")
    }

    func testDeviceIDLockedKeychainLogsOncePerCause() {
        let latch = LogLatch()
        var lines: [String] = []
        // sendSelfIdentity() runs after EVERY reconnect.
        for _ in 0..<30 {
            if let l = KeychainDeviceID.failureLine(status: -25308, latch: latch) { lines.append(l) }
        }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("deviceID read FAILED"))

        XCTAssertNotNil(KeychainDeviceID.failureLine(status: -34018, latch: latch),
                        "A different status is a different cause")
        XCTAssertNil(KeychainDeviceID.failureLine(status: errSecItemNotFound, latch: latch),
                     "First launch has no stored ID — ordinary, never logs")
    }
}
