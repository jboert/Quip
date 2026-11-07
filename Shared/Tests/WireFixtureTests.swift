import XCTest
@testable import Quip

/// Q-91 spec 10.2: the phase-1 wire fixtures in `Fixtures/wire/` are the shape
/// every host must speak. Each file decodes with its Swift type, and encoding
/// that value again gives back the same keys, value kinds and values — so a
/// Rust host held to the same files cannot drift from what the Mac sends and
/// the phone reads. `Fixtures/wire/index.json` names each file's Swift type.
final class WireFixtureTests: XCTestCase {

    private struct Index: Decodable {
        struct Entry: Decodable {
            let file: String
            let type: String
            let swiftType: String
        }
        let fixtures: [Entry]
    }

    /// The phase-1 messages (spec 3.1-3.3) that must each have a fixture.
    private let phaseOneTypes: Set<String> = [
        "auth", "auth_result", "device_identity", "layout_update", "state_change",
        "frontmost_changed", "heartbeat", "heartbeat_ack", "select_window", "send_text",
        "send_text_ack", "quick_action", "arrange_windows", "minimize_window", "close_window",
        "phone_log", "error", "preferences_request", "preferences_snapshot", "preferences_restore",
    ]

    private func roundTrip<T: Codable>(_ type: T.Type) -> (Data) throws -> Data {
        { data in
            let value = try MessageCoder.decoder.decode(T.self, from: data)
            return try MessageCoder.encoder.encode(value)
        }
    }

    private var coders: [String: (Data) throws -> Data] {
        [
            "AuthMessage": roundTrip(AuthMessage.self),
            "AuthResultMessage": roundTrip(AuthResultMessage.self),
            "DeviceIdentityMessage": roundTrip(DeviceIdentityMessage.self),
            "LayoutUpdate": roundTrip(LayoutUpdate.self),
            "StateChangeMessage": roundTrip(StateChangeMessage.self),
            "FrontmostChangedMessage": roundTrip(FrontmostChangedMessage.self),
            "HeartbeatMessage": roundTrip(HeartbeatMessage.self),
            "HeartbeatAckMessage": roundTrip(HeartbeatAckMessage.self),
            "SelectWindowMessage": roundTrip(SelectWindowMessage.self),
            "SendTextMessage": roundTrip(SendTextMessage.self),
            "SendTextAckMessage": roundTrip(SendTextAckMessage.self),
            "QuickActionMessage": roundTrip(QuickActionMessage.self),
            "ArrangeWindowsMessage": roundTrip(ArrangeWindowsMessage.self),
            "MinimizeWindowMessage": roundTrip(MinimizeWindowMessage.self),
            "CloseWindowMessage": roundTrip(CloseWindowMessage.self),
            "PhoneLogMessage": roundTrip(PhoneLogMessage.self),
            "ErrorMessage": roundTrip(ErrorMessage.self),
            "PreferenceRequestMessage": roundTrip(PreferenceRequestMessage.self),
            "PreferenceSnapshotMessage": roundTrip(PreferenceSnapshotMessage.self),
            "PreferenceRestoreMessage": roundTrip(PreferenceRestoreMessage.self),
        ]
    }

    /// The `type` each Swift type's own init writes. Checked against the index,
    /// so a fixture cannot be filed under a type whose init sends another name.
    private var initTypes: [String: String] {
        let id = UUID()
        let frame = WindowFrame(x: 0, y: 0, width: 1, height: 1)
        return [
            "AuthMessage": AuthMessage(pin: "1").type,
            "AuthResultMessage": AuthResultMessage(success: true).type,
            "DeviceIdentityMessage": DeviceIdentityMessage(deviceID: "d", deviceKind: "windows", displayName: "n").type,
            "LayoutUpdate": LayoutUpdate(monitor: "m", windows: [
                WindowState(id: "w", name: "n", app: "a", enabled: true, frame: frame, state: "neutral", color: "#FFFFFF"),
            ]).type,
            "StateChangeMessage": StateChangeMessage(windowId: "w", state: "neutral").type,
            "FrontmostChangedMessage": FrontmostChangedMessage(windowId: nil).type,
            "HeartbeatMessage": HeartbeatMessage(seq: 1, ts: 0).type,
            "HeartbeatAckMessage": HeartbeatAckMessage(seq: 1).type,
            "SelectWindowMessage": SelectWindowMessage(windowId: "w").type,
            "SendTextMessage": SendTextMessage(windowId: "w", text: "t").type,
            "SendTextAckMessage": SendTextAckMessage(messageId: id, injectMs: 0, totalMs: 0, path: "sendText").type,
            "QuickActionMessage": QuickActionMessage(windowId: "w", action: "press_return").type,
            "ArrangeWindowsMessage": ArrangeWindowsMessage(layout: .horizontal).type,
            "MinimizeWindowMessage": MinimizeWindowMessage(windowId: "w").type,
            "CloseWindowMessage": CloseWindowMessage(windowId: "w").type,
            "PhoneLogMessage": PhoneLogMessage(lines: []).type,
            "ErrorMessage": ErrorMessage(reason: "r").type,
            "PreferenceRequestMessage": PreferenceRequestMessage(deviceID: "d").type,
            "PreferenceSnapshotMessage": PreferenceSnapshotMessage(deviceID: "d", preferences: PreferencesSnapshot()).type,
            "PreferenceRestoreMessage": PreferenceRestoreMessage(preferences: PreferencesSnapshot()).type,
        ]
    }

    private var wireDirectory: URL { VectorFixture.url("wire") }

    private func index() throws -> Index {
        try JSONDecoder().decode(Index.self,
                                 from: Data(contentsOf: wireDirectory.appendingPathComponent("index.json")))
    }

    func testEveryFixtureDecodesAndReencodesToTheSameShape() throws {
        let entries = try index().fixtures
        XCTAssertGreaterThanOrEqual(entries.count, phaseOneTypes.count, "the index went missing or was emptied")
        let coders = self.coders
        for entry in entries {
            guard let coder = coders[entry.swiftType] else {
                XCTFail("\(entry.file): no coder for \(entry.swiftType)")
                continue
            }
            let data = try Data(contentsOf: wireDirectory.appendingPathComponent(entry.file))
            let original = try JSONSerialization.jsonObject(with: data)
            XCTAssertEqual((original as? [String: Any])?["type"] as? String, entry.type,
                           "\(entry.file): the type field must match the index")
            let reencoded: Data
            do {
                reencoded = try coder(data)
            } catch {
                XCTFail("\(entry.file) does not decode as \(entry.swiftType): \(error)")
                continue
            }
            let again = try JSONSerialization.jsonObject(with: reencoded)
            if let difference = JSONCompare.difference(Self.droppingNulls(original), again,
                                                       path: entry.file, tolerance: 0) {
                XCTFail("\(entry.file) does not survive a Swift round trip: \(difference)")
            }
        }
    }

    func testEachIndexTypeIsWhatItsSwiftInitSends() throws {
        let initTypes = self.initTypes
        XCTAssertEqual(Set(initTypes.keys), Set(coders.keys), "every coded type needs a sample")
        for entry in try index().fixtures {
            XCTAssertEqual(initTypes[entry.swiftType], entry.type,
                           "\(entry.file): \(entry.swiftType)'s init sends another type")
        }
    }

    func testEveryPhaseOneMessageHasAFixture() throws {
        let covered = Set(try index().fixtures.map(\.type))
        XCTAssertEqual(covered.intersection(phaseOneTypes), phaseOneTypes,
                       "missing: \(phaseOneTypes.subtracting(covered).sorted())")
    }

    func testIndexListsEveryFileInTheFolder() throws {
        let onDisk = Set(try FileManager.default.contentsOfDirectory(atPath: wireDirectory.path)
            .filter { $0.hasSuffix(".json") && $0 != "index.json" })
        let listed = Set(try index().fixtures.map(\.file))
        XCTAssertEqual(onDisk, listed, "a fixture file and the index disagree")
    }

    /// Optional fields with a null value may be omitted on re-encode: Swift's
    /// synthesized encoder skips nil rather than writing null.
    private static func droppingNulls(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { !($0.value is NSNull) }.mapValues(droppingNulls)
        }
        if let array = value as? [Any] { return array.map(droppingNulls) }
        return value
    }
}
