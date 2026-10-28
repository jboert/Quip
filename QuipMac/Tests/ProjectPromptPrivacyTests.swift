import XCTest
import Network
@testable import Quip

/// VibeCut's private project store through the Mac reader, and the guards that
/// keep local-only prompts off the Cloudflare tunnel. Project names are invented.
@MainActor
final class ProjectPromptPrivacyTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("quip-projprompt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        PromptLibrary.directoryOverrideForTests = tmp.appendingPathComponent("prompts", isDirectory: true)
    }

    override func tearDown() {
        PromptLibrary.directoryOverrideForTests = nil
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - Reader + private store

    private func makeReader(store: String?) throws -> VibeCutPromptReader {
        let root = tmp.appendingPathComponent("vibecut", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try """
        {"version":"3.0","prompts":[
          {"id":"14-commit","name":"Commit","category":"git","prompt":"Write a commit.","mode":"paste","type":"text"},
          {"id":"15-other","name":"Other","category":"git","prompt":"Something.","mode":"paste","type":"text"}
        ]}
        """.write(to: shared.appendingPathComponent("prompts.json"), atomically: true, encoding: .utf8)
        let storeURL = tmp.appendingPathComponent("private/projects.json")
        if let store {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try store.write(to: storeURL, atomically: true, encoding: .utf8)
        }
        return VibeCutPromptReader(root: root,
                                   packsDirectory: tmp.appendingPathComponent("packs"),
                                   actionsDirectory: tmp.appendingPathComponent("actions"),
                                   privateStoreURL: storeURL)
    }

    private let goodStore = """
    {"version":1,"prompts":[{"id":"proj-1a2b3c4d","name":"Update email draft","prompt":"Update the draft.",
      "mode":"send","emoji":"x","projects":["demo-proj"],"createdAt":"2026-10-27T12:00:00Z"}],
     "assignments":{"14-commit":["demo-proj"]}}
    """

    func testStorePromptsAreAppendedAndAssignmentsApplied() throws {
        let result = try makeReader(store: goodStore).read()
        let entries = VibeCutPromptMapper.map(catalog: result.catalog).entries
        let mine = try XCTUnwrap(entries.first { $0.label == "Update email draft" })
        XCTAssertEqual(mine.id, "vibecut__proj-1a2b3c4d")
        XCTAssertTrue((mine.tags ?? []).contains("project:demo-proj"))
        XCTAssertTrue((mine.tags ?? []).contains("local-only"))
        XCTAssertTrue((mine.tags ?? []).contains("project"), "category project")

        let commit = try XCTUnwrap(entries.first { $0.label == "Commit" })
        XCTAssertTrue((commit.tags ?? []).contains("project:demo-proj"))
        XCTAssertTrue((commit.tags ?? []).contains("local-only"))

        let other = try XCTUnwrap(entries.first { $0.label == "Other" })
        XCTAssertFalse((other.tags ?? []).contains("local-only"), "an unassigned prompt stays public")
        XCTAssertFalse((other.tags ?? []).contains { $0.hasPrefix("project:") })
    }

    func testMissingStoreIsNormal() throws {
        let result = try makeReader(store: nil).read()
        XCTAssertEqual(result.catalog.prompts.count, 2)
    }

    func testCorruptStoreIsIgnoredAndTheRestStillSyncs() throws {
        let result = try makeReader(store: "{ not json").read()
        XCTAssertEqual(result.catalog.prompts.count, 2)
        XCTAssertFalse(result.catalog.prompts.contains { $0.fromPrivateStore })
    }

    func testNewerStoreVersionIsIgnored() throws {
        let future = goodStore.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        let result = try makeReader(store: future).read()
        XCTAssertEqual(result.catalog.prompts.count, 2)
        XCTAssertTrue(result.catalog.prompts.allSatisfy { ($0.projects ?? []).isEmpty })
    }

    func testFingerprintIncludesThePrivateStore() throws {
        let reader = try makeReader(store: goodStore)
        let before = try XCTUnwrap(reader.sourceFingerprint())
        try goodStore.replacingOccurrences(of: "Update the draft.", with: "Changed body.")
            .write(to: reader.privateStoreURL, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(reader.sourceFingerprint(), before)
        try FileManager.default.removeItem(at: reader.privateStoreURL)
        XCTAssertNotEqual(reader.sourceFingerprint(), before, "removing the store is a change too")
    }

    // MARK: - Resync: VibeCut-supplied project tags win

    func testVibeCutProjectTagsReplaceHandAddedOnesOnResync() {
        let lib = PromptLibrary()
        try! lib.replaceVibeCutSet([PromptEntry(id: "vibecut__a", label: "A", body: "1", tags: ["vibecut"])])
        _ = lib.put(id: "vibecut__a", label: "A", body: "1", tags: ["vibecut", "project:hand-added"])
        try! lib.replaceVibeCutSet([PromptEntry(id: "vibecut__a", label: "A", body: "1",
                                                tags: ["vibecut", "project:demo-proj", "local-only"])])
        let tags = lib.entries.first { $0.id == "vibecut__a" }?.tags ?? []
        XCTAssertTrue(tags.contains("project:demo-proj"))
        XCTAssertFalse(tags.contains("project:hand-added"))
    }

    func testHandAddedProjectTagsSurviveWhenVibeCutSuppliesNone() {
        let lib = PromptLibrary()
        try! lib.replaceVibeCutSet([PromptEntry(id: "vibecut__a", label: "A", body: "1", tags: ["vibecut"])])
        _ = lib.put(id: "vibecut__a", label: "A", body: "1", tags: ["vibecut", "project:hand-added"])
        try! lib.replaceVibeCutSet([PromptEntry(id: "vibecut__a", label: "A", body: "1", tags: ["vibecut"])])
        XCTAssertTrue((lib.entries.first { $0.id == "vibecut__a" }?.tags ?? []).contains("project:hand-added"))
    }

    // MARK: - Tunnel

    func testCloudflareHeadersAreRecognisedCaseInsensitively() {
        XCTAssertTrue(WebSocketServer.hasCloudflareHeaders([(name: "cf-ray", value: "x")]))
        XCTAssertTrue(WebSocketServer.hasCloudflareHeaders([(name: "CF-Connecting-IP", value: "1.2.3.4")]))
        XCTAssertFalse(WebSocketServer.hasCloudflareHeaders([(name: "Host", value: "x"), (name: "Accept", value: "*/*")]))
    }

    func testLoopbackHosts() {
        for h in ["127.0.0.1", "127.1.2.3", "::1", "::ffff:127.0.0.1", "::1%lo0", "[::1]"] {
            XCTAssertTrue(WebSocketServer.isLoopbackHost(h), h)
        }
        for h in ["192.168.1.20", "100.101.102.103", "10.0.0.5", "fe80::1", "1.2.3.4"] {
            XCTAssertFalse(WebSocketServer.isLoopbackHost(h), h)
        }
    }

    func testOnlyLoopbackIsReclassifiedOnceCloudflareHeadersWereSeen() {
        XCTAssertTrue(WebSocketServer.classifyAsTunnel(remoteHost: "127.0.0.1", cloudflareHeadersSeen: true))
        XCTAssertFalse(WebSocketServer.classifyAsTunnel(remoteHost: "127.0.0.1", cloudflareHeadersSeen: false))
        XCTAssertFalse(WebSocketServer.classifyAsTunnel(remoteHost: "192.168.1.20", cloudflareHeadersSeen: true))
        XCTAssertFalse(WebSocketServer.classifyAsTunnel(remoteHost: "100.101.102.103", cloudflareHeadersSeen: true))
    }

    func testTunnelPromptActionsOnLocalOnlyIdsAreRefused() {
        let local: Set<String> = ["vibecut__proj-1a2b3c4d"]
        func body(_ type: String, _ id: String) -> Data {
            Data(#"{"type":"\#(type)","id":"\#(id)","windowId":"w"}"#.utf8)
        }
        XCTAssertEqual(WebSocketServer.refusedTunnelPromptID(in: body("paste_prompt", "vibecut__proj-1a2b3c4d"), localOnly: local),
                       "vibecut__proj-1a2b3c4d")
        XCTAssertEqual(WebSocketServer.refusedTunnelPromptID(in: body("put_prompt", "vibecut__proj-1a2b3c4d"), localOnly: local),
                       "vibecut__proj-1a2b3c4d")
        XCTAssertEqual(WebSocketServer.refusedTunnelPromptID(in: body("delete_prompt", "vibecut__proj-1a2b3c4d"), localOnly: local),
                       "vibecut__proj-1a2b3c4d")
        XCTAssertNil(WebSocketServer.refusedTunnelPromptID(in: body("paste_prompt", "vibecut__commit"), localOnly: local))
        XCTAssertNil(WebSocketServer.refusedTunnelPromptID(in: body("send_text", "vibecut__proj-1a2b3c4d"), localOnly: local))
        XCTAssertNil(WebSocketServer.refusedTunnelPromptID(in: Data("garbage".utf8), localOnly: local))
    }

    func testReceiveFromTunnelDropsLocalOnlyPasteAndForwardsTheRest() {
        let server = WebSocketServer()
        server.localOnlyPromptIDs = { ["vibecut__proj-1a2b3c4d"] }
        var forwarded: [String] = []
        server.onMessageReceived = { forwarded.append(String(data: $0, encoding: .utf8) ?? "") }
        server.receiveFromTunnel(Data(#"{"type":"paste_prompt","id":"vibecut__proj-1a2b3c4d","windowId":"w"}"#.utf8))
        XCTAssertTrue(forwarded.isEmpty)
        server.receiveFromTunnel(Data(#"{"type":"paste_prompt","id":"vibecut__commit","windowId":"w"}"#.utf8))
        XCTAssertEqual(forwarded.count, 1)
    }

    func testPromptLibraryBroadcastStripsLocalOnlyForTunnelClientsOnly() throws {
        let server = WebSocketServer()
        let conn = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)   // never started
        let got = expectation(description: "tunnel got the library")
        var payload = Data()
        server.registerTunnelClient(conn) { data in payload = data; got.fulfill() }

        let publicEntry = PromptEntry(id: "vibecut__commit", label: "Commit", body: "Write a commit.", tags: ["vibecut"])
        let privateEntry = PromptEntry(id: "vibecut__proj-1a2b3c4d", label: "Update email draft",
                                       body: "SECRET BODY", tags: ["vibecut", "project:demo-proj", "local-only"])
        server.broadcastPromptLibrary([publicEntry, privateEntry])
        wait(for: [got], timeout: 5)

        let message = try JSONDecoder().decode(PromptLibraryMessage.self, from: payload)
        XCTAssertEqual(message.prompts.map(\.id), ["vibecut__commit"])
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(text.contains("SECRET BODY"))
        XCTAssertFalse(text.contains("demo-proj"))
        server.unregisterTunnelClient(conn)
    }

    func testPromptLibraryBroadcastWithNothingPrivateIsUnchangedForTunnelClients() throws {
        let server = WebSocketServer()
        let conn = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let got = expectation(description: "tunnel got the library")
        var payload = Data()
        server.registerTunnelClient(conn) { data in payload = data; got.fulfill() }
        server.broadcastPromptLibrary([PromptEntry(id: "vibecut__commit", label: "Commit", body: "b", tags: ["vibecut"])])
        wait(for: [got], timeout: 5)
        XCTAssertEqual(try JSONDecoder().decode(PromptLibraryMessage.self, from: payload).prompts.count, 1)
        server.unregisterTunnelClient(conn)
    }

    // MARK: - WindowState.project from the Mac

    func testToWindowStateCarriesTheGitRootProject() throws {
        let root = tmp.appendingPathComponent("demo-proj", isDirectory: true)
        let sub = root.appendingPathComponent("src/mail", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let window = ManagedWindow(
            id: "w1", name: "n", app: "iTerm2", subtitle: "mail", cwdPath: sub.path,
            bundleId: "com.googlecode.iterm2", icon: nil, isEnabled: true,
            assignedColor: "#F5A623", pid: 1, windowNumber: 0,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            iterm2SessionId: nil, isOnVisibleScreen: true)
        let state = window.toWindowState(screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(state.folder, "mail")
        XCTAssertEqual(state.project, "demo-proj")
    }

    // MARK: - Wiring (no socket needed)
    //
    // The tunnel and iCloud guards above are pure functions. These pin the
    // one-line hookups that make the app actually call them, so a refactor
    // that bypasses a guard fails here instead of leaking project prompts.

    private func source(_ rel: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    func testTunnelMessagesGoThroughTheRefusal() throws {
        let tunnel = try source("QuipMac/Services/CloudflareTunnel.swift")
        XCTAssertTrue(tunnel.contains("server.receiveFromTunnel(data)"))
        XCTAssertFalse(tunnel.contains("onMessageReceived?("),
                       "tunnel traffic must not skip receiveFromTunnel")
    }

    func testEveryPromptLibrarySendIsFiltered() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let mac = root.appendingPathComponent("QuipMac")
        var hits: [String] = []
        for case let url as URL in fm.enumerator(at: mac, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" && !url.path.contains("/Tests/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("PromptLibraryMessage(") { hits.append(url.lastPathComponent) }
        }
        XCTAssertEqual(hits, ["WebSocketServer.swift"],
                       "build PromptLibraryMessage only in broadcastPromptLibrary")
        let server = try source("QuipMac/Services/WebSocketServer.swift")
        let body = server.components(separatedBy: "func broadcastPromptLibrary").last ?? ""
        XCTAssertTrue(body.contains("PromptPrivacy.strippingLocalOnly(entries)"))
        XCTAssertTrue(server.contains("clients[i].isTunnel ? (restricted ?? data) : data"))
        XCTAssertTrue(server.contains("broadcaster.sender(restricted ?? data)"))
        XCTAssertTrue(server.contains("client.isTunnel = tunnel"))
        XCTAssertTrue(server.contains("if self.clients[clientIndex].isTunnel,"))
    }

    func testPhoneScrubsTheICloudCopyAndUsesTheProject() throws {
        let prefs = try source("QuipiOS/Services/PreferencesSyncService.swift")
        XCTAssertEqual(prefs.components(separatedBy: "NSUbiquitousKeyValueStore.default.set(").count, 2,
                       "one iCloud write, so one place to scrub")
        XCTAssertTrue(prefs.contains("Self.scrubbed(snapshot, localOnly: rememberedLocalOnlyIDs())"))
        XCTAssertTrue(prefs.contains("known.union(localOnlyPromptIDs())"))
        let app = try source("QuipiOS/QuipApp.swift")
        XCTAssertTrue(app.contains("for name in [window?.project, window?.folder]"))
        XCTAssertTrue(app.contains("PromptPrivacy.localOnlyIDs(manager.active.client.promptLibrary)"))
    }
}
