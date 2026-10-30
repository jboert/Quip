import XCTest
@testable import Quip

/// Q-88 US-007: unsent text kept per window.
@MainActor
final class DraftStoreTests: XCTestCase {

    /// In-memory draft files, one blob per Mac.
    private final class Disk {
        var files: [String: Data] = [:]
        var writes = 0
        var failWrites = false
        lazy var backing = DraftFiles(
            read: { self.files[$0] },   // a cycle; fine for a test
            write: { data, backendId in
                if self.failWrites { throw CocoaError(.fileWriteNoPermission) }
                self.files[backendId] = data
                self.writes += 1
            })
    }

    private func book(_ disk: Disk, logs: UnsafeMutablePointer<[String]>? = nil) -> DraftBook {
        DraftBook(files: disk.backing, log: { logs?.pointee.append($0) })
    }

    private let everything: (String) -> Set<String> = { _ in ["W1", "W2", "W3"] }

    // MARK: Switching windows

    func test_switchSavesTheOldDraft_andLoadsTheNewOne() {
        let disk = Disk()
        let b = book(disk)
        XCTAssertEqual(b.swap(fieldText: "", toBackend: "mac", window: "W1", kept: everything), "")
        XCTAssertEqual(b.swap(fieldText: "hello", toBackend: "mac", window: "W2", kept: everything), "")
        XCTAssertEqual(b.swap(fieldText: "", toBackend: "mac", window: "W1", kept: everything), "hello")
    }

    func test_sameOwner_leavesTheFieldAlone() {
        let b = book(Disk())
        _ = b.swap(fieldText: "", toBackend: "mac", window: "W1", kept: everything)
        XCTAssertNil(b.swap(fieldText: "typing", toBackend: "mac", window: "W1", kept: everything))
    }

    func test_send_clearsOnlyThatWindowsDraft() {
        let b = book(Disk())
        _ = b.swap(fieldText: "", toBackend: "mac", window: "W1", kept: everything)
        _ = b.swap(fieldText: "one", toBackend: "mac", window: "W2", kept: everything)
        _ = b.swap(fieldText: "two", toBackend: "mac", window: "W1", kept: everything)
        // Sent from W1: the field is empty when the user moves on.
        XCTAssertEqual(b.swap(fieldText: "", toBackend: "mac", window: "W2", kept: everything), "two")
        XCTAssertEqual(b.swap(fieldText: "two", toBackend: "mac", window: "W1", kept: everything), "")
    }

    func test_draftsAreKeptPerMac() {
        let b = book(Disk())
        _ = b.swap(fieldText: "", toBackend: "mac-a", window: "W1", kept: everything)
        // Switching Macs: W1's text is filed under mac-a, not mac-b.
        XCTAssertEqual(b.swap(fieldText: "for a", toBackend: "mac-b", window: "W1", kept: everything), "")
        XCTAssertEqual(b.swap(fieldText: "", toBackend: "mac-a", window: "W1", kept: everything), "for a")
    }

    func test_survivesARelaunch_viaTheFile() {
        let disk = Disk()
        let first = book(disk)
        _ = first.swap(fieldText: "", toBackend: "mac", window: "W1", kept: everything)
        first.stash("half a thought", kept: everything)
        let second = book(disk)
        XCTAssertEqual(second.swap(fieldText: "", toBackend: "mac", window: "W1", kept: everything), "half a thought")
    }

    func test_unchangedDrafts_writeNothing() {
        let disk = Disk()
        let b = book(disk)
        _ = b.swap(fieldText: "", toBackend: "mac", window: "W1", kept: everything)
        b.stash("x", kept: everything)
        b.stash("x", kept: everything)
        XCTAssertEqual(disk.writes, 1)
    }

    // MARK: Limits

    func test_prune_dropsWindowsNoLongerInTheRecencyStack() {
        let disk = Disk()
        let b = book(disk)
        _ = b.swap(fieldText: "", toBackend: "mac", window: "W1", kept: everything)
        _ = b.swap(fieldText: "old", toBackend: "mac", window: "W2", kept: everything)
        // W1 has fallen off the stack; W2 (the field's owner) always stays.
        b.stash("still typing", kept: { _ in ["W3"] })
        // What the background save wrote is all a relaunch has.
        let relaunched = book(disk)
        XCTAssertEqual(relaunched.swap(fieldText: "", toBackend: "mac", window: "W1", kept: everything), "")
        XCTAssertEqual(relaunched.swap(fieldText: "", toBackend: "mac", window: "W2", kept: everything), "still typing")
    }

    func test_emptyText_removesTheEntry() {
        var store = DraftStore()
        store.set("x", for: "W1")
        store.set("", for: "W1")
        store.set("", for: "W2")
        XCTAssertTrue(store.entries.isEmpty, "an empty draft must not take one of the 50 places")
    }

    func test_fiftyDraftsPerMac_oldestDropped() {
        var store = DraftStore()
        for i in 0...DraftStore.maxDrafts { store.set("t\(i)", for: "W\(i)") }
        XCTAssertEqual(store.entries.count, DraftStore.maxDrafts)
        XCTAssertEqual(store.text(for: "W0"), "")
        XCTAssertEqual(store.text(for: "W\(DraftStore.maxDrafts)"), "t\(DraftStore.maxDrafts)")
    }

    func test_4KBCap_cutsBetweenCharacters_emojiSafe() {
        let text = String(repeating: "a", count: DraftStore.maxBytes - 2) + "👍🏽" + "tail"
        let capped = DraftStore.capped(text)
        XCTAssertLessThanOrEqual(capped.utf8.count, DraftStore.maxBytes)
        XCTAssertEqual(capped, String(repeating: "a", count: DraftStore.maxBytes - 2), "never half an emoji")
        XCTAssertEqual(DraftStore.capped("short"), "short")
    }

    // MARK: Failures are audible, text never is

    func test_corruptFile_dropsDrafts_withOneLineAndNoText() {
        let disk = Disk()
        disk.files["mac"] = Data("{ secret-token-123".utf8)
        var logs: [String] = []
        let b = book(disk, logs: &logs)
        XCTAssertEqual(b.swap(fieldText: "", toBackend: "mac", window: "W1", kept: everything), "")
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("drafts decode FAILED"))
        XCTAssertFalse(logs[0].contains("secret"))
    }

    func test_writeFailure_logsWithoutText() {
        let disk = Disk()
        disk.failWrites = true
        var logs: [String] = []
        let b = book(disk, logs: &logs)
        _ = b.swap(fieldText: "", toBackend: "mac", window: "W1", kept: everything)
        b.stash("my password is hunter2", kept: everything)
        XCTAssertEqual(logs, ["drafts write FAILED — unsent text not saved"])
    }

    func test_draftsAreNotInTheBackup() {
        let names = Mirror(reflecting: PreferencesSnapshot()).children.compactMap(\.label)
        XCTAssertFalse(names.contains { $0.localizedCaseInsensitiveContains("draft") })
    }

    // MARK: The real file

    func test_diskFile_isProtectedAndExcludedFromBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DraftStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = DraftFiles.disk(directory: dir)
        try files.write(Data("[]".utf8), "mac")
        let url = dir.appendingPathComponent(DraftFiles.fileName(forBackendId: "mac"))
        XCTAssertEqual(url.lastPathComponent, "drafts.v1.mac.json")
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(files.read("mac"), Data("[]".utf8))
        XCTAssertTrue(DraftFiles.writeOptions.contains(.completeFileProtection))
        #if !targetEnvironment(simulator)
        // The simulator has no data protection and reports none.
        let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
        XCTAssertEqual(protection, .complete)
        #endif
    }
}
