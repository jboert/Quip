import XCTest
@testable import Quip

final class ClaudeHookInstallerTests: XCTestCase {
    private let hook = "/Applications/Quip.app/Contents/MacOS/quip-claude-hook"

    /// Shaped like the owner's real file: several groups under both events,
    /// keys out of alphabetical order, other top-level keys, a URL with `/`.
    private let ownerFile = """
    {
      "permissions": {
        "allow": [
          "Bash(plutil:*)"
        ]
      },
      "model": "opus[1m]",
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "/Users/x/.claude/hooks/rtk-rewrite.sh"
              }
            ]
          }
        ],
        "PostToolUse": [
          {
            "matcher": "*",
            "hooks": [
              {
                "type": "command",
                "command": "curl -s 'https://example.com/a/b' > /dev/null",
                "timeout": 5
              }
            ]
          }
        ]
      },
      "alwaysThinkingEnabled": true
    }

    """

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func test_ownerFileRoundTripsByteForByte() throws {
        let parsed = try OrderedJSON.parse(data(ownerFile))
        XCTAssertEqual(parsed.serialized() + "\n", ownerFile)
    }

    func test_installIntoOwnerFileAddsOnlyOneGroup() throws {
        let out = try ClaudeHookInstaller.install(into: data(ownerFile), hookPath: hook)
        let root = try OrderedJSON.parse(out)
        let post = try XCTUnwrap(root["hooks"]?["PostToolUse"]?.arrayValue)
        XCTAssertEqual(post.count, 2)
        XCTAssertEqual(post[1]["matcher"]?.stringValue, "Bash")
        XCTAssertEqual(post[1]["hooks"]?.arrayValue?.first?["command"]?.stringValue,
                       ClaudeHookInstaller.command(hookPath: hook))
        // Everything else is unchanged and in its original order.
        guard case let .object(pairs) = root else { return XCTFail() }
        XCTAssertEqual(pairs.map(\.key), ["permissions", "model", "hooks", "alwaysThinkingEnabled"])
        let original = try OrderedJSON.parse(data(ownerFile))
        XCTAssertEqual(root["permissions"], original["permissions"])
        XCTAssertEqual(root["hooks"]?["PreToolUse"], original["hooks"]?["PreToolUse"])
        XCTAssertEqual(post[0], original["hooks"]?["PostToolUse"]?.arrayValue?[0])
        XCTAssertEqual(ClaudeHookInstaller.status(settings: out, hookPath: hook), .on)
    }

    func test_uninstallRestoresTheOwnerFileExactly() throws {
        let installed = try ClaudeHookInstaller.install(into: data(ownerFile), hookPath: hook)
        let removed = try XCTUnwrap(ClaudeHookInstaller.uninstall(from: installed))
        XCTAssertEqual(String(decoding: removed, as: UTF8.self), ownerFile)
    }

    func test_installTwiceIsANoOp() throws {
        let once = try ClaudeHookInstaller.install(into: data(ownerFile), hookPath: hook)
        let twice = try ClaudeHookInstaller.install(into: once, hookPath: hook)
        XCTAssertEqual(once, twice)
    }

    func test_installIntoMissingOrEmptyFile() throws {
        for input in [nil, data(""), data("{}")] as [Data?] {
            let out = try ClaudeHookInstaller.install(into: input, hookPath: hook)
            XCTAssertEqual(ClaudeHookInstaller.status(settings: out, hookPath: hook), .on)
            // A new file ends in a newline; an existing one keeps its own ending.
            XCTAssertEqual(out.last == UInt8(ascii: "\n"), input != data("{}"))
        }
    }

    func test_uninstallKeepsAGroupThatStillHasOtherHooks() throws {
        let mixed = """
        {"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[
          {"type":"command","command":"/mine.sh"},
          {"type":"command","command":"'/old/quip-claude-hook' # quip-previews"}]}]}}
        """
        let out = try XCTUnwrap(ClaudeHookInstaller.uninstall(from: data(mixed)))
        let inner = try XCTUnwrap(OrderedJSON.parse(out)["hooks"]?["PostToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue)
        XCTAssertEqual(inner.map { $0["command"]?.stringValue }, ["/mine.sh"])
    }

    func test_uninstallWithoutQuipHookChangesNothing() throws {
        XCTAssertEqual(try ClaudeHookInstaller.uninstall(from: data(ownerFile)), data(ownerFile))
    }

    func test_hookThatOnlyMentionsQuipIsNotOurs() throws {
        let other = """
        {"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[
          {"type":"command","command":"echo '# quip-previews' > /tmp/x"}]}]}}
        """
        XCTAssertEqual(ClaudeHookInstaller.status(settings: data(other), hookPath: hook), .off)
        XCTAssertEqual(try ClaudeHookInstaller.uninstall(from: data(other)), data(other))
    }

    func test_invalidJSONIsRefusedAndReported() {
        let bad = data("{\"hooks\": ")
        XCTAssertEqual(ClaudeHookInstaller.status(settings: bad, hookPath: hook), .unreadable)
        XCTAssertThrowsError(try ClaudeHookInstaller.install(into: bad, hookPath: hook))
        XCTAssertThrowsError(try ClaudeHookInstaller.uninstall(from: bad))
    }

    func test_movedQuipIsStaleAndRepairReplacesIt() throws {
        let old = try ClaudeHookInstaller.install(into: nil, hookPath: "/Users/x/Applications/Quip.app/Contents/MacOS/quip-claude-hook")
        guard case .stale = ClaudeHookInstaller.status(settings: old, hookPath: hook) else {
            return XCTFail("expected stale")
        }
        let repaired = try ClaudeHookInstaller.install(into: old, hookPath: hook)
        XCTAssertEqual(ClaudeHookInstaller.status(settings: repaired, hookPath: hook), .on)
        let groups = try XCTUnwrap(OrderedJSON.parse(repaired)["hooks"]?["PostToolUse"]?.arrayValue)
        XCTAssertEqual(groups.count, 1)
    }

    func test_pathWithQuoteIsShellQuoted() {
        XCTAssertEqual(ClaudeHookInstaller.command(hookPath: "/a/it's/hook"),
                       "'/a/it'\\''s/hook' # quip-previews")
    }

    func test_onDiskBacksUpOnceAndFollowsSymlink() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hookinst-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.json")
        let link = dir.appendingPathComponent("settings.json")
        try data(ownerFile).write(to: real)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        try ClaudeHookInstaller.installOnDisk(hookPath: hook, url: link)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertEqual(ClaudeHookInstaller.statusOnDisk(hookPath: hook, url: link), .on)
        let backup = dir.appendingPathComponent("settings.json.quip-backup")
        XCTAssertEqual(try Data(contentsOf: backup), data(ownerFile))

        try ClaudeHookInstaller.uninstallOnDisk(url: link)
        XCTAssertEqual(try Data(contentsOf: real), data(ownerFile))
    }

    func test_escapesRoundTrip() throws {
        let s = #"{"a": "q\"b\\s\n\u0001é😀", "b": [], "c": {}, "n": 1.50, "e": -2e3}"#
        let v = try OrderedJSON.parse(data(s))
        XCTAssertEqual(try OrderedJSON.parse(data(v.serialized())), v)
        XCTAssertEqual(v["n"], .number("1.50"))
        XCTAssertEqual(v["a"]?.stringValue, "q\"b\\s\n\u{01}é😀")
    }

    // MARK: On by default

    func test_autoInstallsOnlyForAnInstalledQuipThatWasNeverTurnedOff() {
        let app = "/Applications/Quip.app"
        func auto(_ status: ClaudeHookInstaller.Status, off: Bool = false, claude: Bool = true,
                  path: String = app) -> Bool {
            ClaudeHookSwitch.shouldAutoInstall(status: status, userTurnedOff: off, claudeInstalled: claude, appPath: path)
        }
        XCTAssertTrue(auto(.off))
        XCTAssertTrue(auto(.stale(command: "'/old/quip-claude-hook' # quip-previews")))
        XCTAssertFalse(auto(.on))
        XCTAssertFalse(auto(.unreadable), "a file Quip can't parse is never touched")
        XCTAssertFalse(auto(.off, off: true), "turned off by someone stays off")
        XCTAssertFalse(auto(.off, claude: false), "no Claude Code, no settings file created")
        XCTAssertFalse(auto(.off, path: "/Users/x/Library/Developer/Xcode/DerivedData/QuipMac/Build/Products/Debug/Quip.app"),
                       "debug builds and test hosts leave the owner's settings alone")
        XCTAssertTrue(auto(.off, path: "/Users/x/Applications/Quip.app"))
    }
}
