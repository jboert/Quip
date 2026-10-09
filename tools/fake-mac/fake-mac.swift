// fake-mac.swift — a stand-in Quip Mac server for simulator QA.
//
// The iOS app gets its window list, prompt library and send acknowledgements
// only from a connected Mac, and a QA simulator must never connect to the
// owner's real Mac (a paired test host once overwrote the owner's phone
// settings). This script speaks enough of the Mac's WebSocket protocol for the
// phone to pair, authenticate, stay connected and render data from a fixture.
//
//   xcrun swift tools/fake-mac/fake-mac.swift [--port 8799] [--pin 11112222]
//       [--fixture tools/fake-mac/fixture.json] [--log <path>]
//       [--ack-paste] [--error-ids]
//
// Safety rules, enforced below:
//   * listens on 127.0.0.1 only (loopback address, loopback interface, and a
//     loopback-peer check), so nothing but this Mac and its simulators can
//     reach it;
//   * refuses port 8765 (the real Quip Mac's port) and any port something is
//     already listening on;
//   * never advertises over Bonjour;
//   * reads only its fixture (no Quip defaults, Keychain items, prompt files or
//     clipboard) and writes only its own log. Preference snapshots the phone
//     pushes are logged by key name and dropped; values are never logged or
//     stored. PINs are never logged, only their length.
//
// Wire shapes mirror Shared/MessageProtocol.swift. The handshake and post-auth
// sequence mirror QuipMac/Services/WebSocketServer.swift and the handlers in
// QuipMac/QuipMacApp.swift. README.md next to this file has the details.

import Foundation
import Network

// MARK: - Options

struct UsageError: Error {
    let message: String
}

struct Options {
    static let realMacPort: UInt16 = 8765

    var port: UInt16 = 8799
    var pin = "11112222"
    var fixturePath = Options.defaultFixturePath
    var logPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("quip-fake-mac.log")
    /// Ack `paste_prompt` with a `send_text_ack`, as the Mac will once US-115
    /// ships. Today's Mac sends no ack for a paste.
    var ackPaste = false
    /// Put the request's `messageId` on `error` replies, as US-115 plans.
    var errorIDs = false

    static var defaultFixturePath: String {
        let besideScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("fixture.json").path
        if FileManager.default.fileExists(atPath: besideScript) { return besideScript }
        return "tools/fake-mac/fixture.json"
    }

    static let usage = """
    usage: xcrun swift tools/fake-mac/fake-mac.swift [options]

      --port N        port to listen on, on 127.0.0.1 only (default 8799; 8765 is refused)
      --pin PIN       PIN the phone must send (default 11112222)
      --fixture PATH  windows and prompts to serve (default: fixture.json beside this script)
      --log PATH      also append every log line here (default: $TMPDIR/quip-fake-mac.log)
      --ack-paste     ack paste_prompt with send_text_ack (simulates the planned US-115 Mac change)
      --error-ids     put the request's messageId on `error` replies (also planned in US-115)
      -h, --help      show this help
    """

    static func parse(_ args: [String]) throws -> Options {
        var options = Options()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw UsageError(message: "\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--port":
                let raw = try value(flag)
                guard let port = UInt16(raw), port >= 1024 else {
                    throw UsageError(message: "--port must be a number from 1024 to 65535, got \(raw)")
                }
                options.port = port
            case "--pin":
                options.pin = try value(flag)
            case "--fixture":
                options.fixturePath = try value(flag)
            case "--log":
                options.logPath = try value(flag)
            case "--ack-paste":
                options.ackPaste = true
            case "--error-ids":
                options.errorIDs = true
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                throw UsageError(message: "unknown option \(flag)")
            }
            i += 1
        }
        guard options.port != realMacPort else {
            throw UsageError(message: "refusing port \(realMacPort): it is the real Quip Mac's port, and a "
                + "phone dialing it must never reach this fake (or the other way round)")
        }
        guard !options.pin.isEmpty, !options.pin.contains(where: \.isWhitespace) else {
            throw UsageError(message: "--pin must be non-empty and contain no spaces")
        }
        return options
    }
}

// MARK: - Fixture (the shapes the Mac sends, plus a few fake-only fields)

struct Frame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// `DisplayState` on the wire.
struct DisplayInfo: Codable {
    let id: String
    let name: String
    let isPrimary: Bool
    let aspect: Double
    let spanFrame: Frame
}

/// `SpaceState` on the wire.
struct SpaceInfo: Codable {
    let id: String
    let name: String
    let isCurrent: Bool
}

/// `WindowState` fields, plus fake-only fields that never go on the wire.
struct FixtureWindow: Decodable {
    let id: String
    let name: String
    let app: String
    let folder: String?
    let enabled: Bool
    let frame: Frame
    let state: String
    let color: String
    let isThinking: Bool?
    let claudeMode: String?
    let cliKind: String?
    let targetKind: String?
    let displayID: String?
    let spaceID: String?
    let isPinned: Bool?
    // Fake-only:
    /// Start with acks off, as if `dead <id>` had been typed.
    let dead: Bool?
    /// Text served as `terminal_content` when the phone asks for this window.
    let content: String?
    /// Fills `{{cwd}}` in a pasted prompt (the real Mac reads it from iTerm2).
    let cwd: String?

    var isTerminal: Bool {
        let lower = app.lowercased()
        return lower == "iterm" || lower == "iterm2" || lower == "terminal"
    }
}

/// `PromptEntry` on the wire.
struct PromptEntry: Codable {
    let id: String
    let label: String
    let body: String
    let tags: [String]?
    let targetAgent: String?
    let description: String?
}

struct Fixture: Decodable {
    /// `device_identity.displayName`.
    let displayName: String
    /// `layout_update.monitor`. The phone treats an equal monitor name as
    /// same-Mac evidence, so keep it unlike any real display's name.
    let monitor: String
    let screenAspect: Double?
    let spanAspect: Double?
    let displays: [DisplayInfo]?
    let spaces: [SpaceInfo]?
    let frontmostWindowId: String?
    let projectDirectories: [String]?
    let windows: [FixtureWindow]
    let prompts: [PromptEntry]

    static let states: Set<String> = ["neutral", "waiting_for_input", "stt_active"]
    static let cliKinds: Set<String> = ["claude", "codex", "grok", "shell", "cursor"]
    static let claudeModes: Set<String> = ["normal", "plan", "autoAccept"]
    static let targetAgents: Set<String> = ["claude", "codex", "cursor", "grok", "any"]

    static func load(path: String) throws -> Fixture {
        let data: Data
        let url = URL(fileURLWithPath: path)
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw UsageError(message: "cannot read fixture \(url.standardizedFileURL.path): \(error.localizedDescription) "
                + "Run from the repository root, or pass --fixture.")
        }
        let fixture: Fixture
        do {
            fixture = try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw UsageError(message: "fixture \(path) does not match the wire shapes: \(describe(error))")
        }
        try fixture.validate()
        return fixture
    }

    /// The phone drops a whole `layout_update` or `prompt_library` it cannot
    /// decode, so catch a bad fixture here, loudly, rather than as an empty grid.
    func validate() throws {
        func fail(_ message: String) -> UsageError { UsageError(message: "fixture: " + message) }
        guard !monitor.isEmpty else { throw fail("monitor must not be empty") }
        var windowIDs = Set<String>()
        for w in windows {
            guard !w.id.isEmpty, windowIDs.insert(w.id).inserted else {
                throw fail("window id \"\(w.id)\" is empty or repeated")
            }
            guard Fixture.states.contains(w.state) else {
                throw fail("window \(w.id): state \"\(w.state)\" is not one of \(Fixture.states.sorted())")
            }
            guard w.color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                throw fail("window \(w.id): color \"\(w.color)\" is not #RRGGBB")
            }
            if let kind = w.cliKind, !Fixture.cliKinds.contains(kind) {
                throw fail("window \(w.id): cliKind \"\(kind)\" is not one of \(Fixture.cliKinds.sorted())")
            }
            if let mode = w.claudeMode, !Fixture.claudeModes.contains(mode) {
                throw fail("window \(w.id): claudeMode \"\(mode)\" is not one of \(Fixture.claudeModes.sorted())")
            }
        }
        var promptIDs = Set<String>()
        for p in prompts {
            guard !p.id.isEmpty, !p.id.contains("/"), promptIDs.insert(p.id).inserted else {
                throw fail("prompt id \"\(p.id)\" is empty, contains \"/\" or is repeated")
            }
            guard !p.body.isEmpty else { throw fail("prompt \(p.id) has an empty body") }
            if let agent = p.targetAgent, !Fixture.targetAgents.contains(agent) {
                throw fail("prompt \(p.id): targetAgent \"\(agent)\" is not one of \(Fixture.targetAgents.sorted())")
            }
        }
        if let front = frontmostWindowId, !windowIDs.contains(front) {
            throw fail("frontmostWindowId \"\(front)\" is not a window in the fixture")
        }
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return "\(error)" }
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return p.isEmpty ? "the top level" : p
        }
        switch e {
        case .keyNotFound(let key, let c): return "missing \"\(key.stringValue)\" at \(path(c))"
        case .typeMismatch(_, let c): return "\(c.debugDescription) at \(path(c))"
        case .valueNotFound(_, let c): return "\(c.debugDescription) at \(path(c))"
        case .dataCorrupted(let c): return "\(c.debugDescription) at \(path(c))"
        @unknown default: return "\(e)"
        }
    }
}

// MARK: - Messages the fake sends (Shared/MessageProtocol.swift shapes)

struct WireWindow: Encodable {
    let id, name, app: String
    let folder: String?
    let enabled: Bool
    let frame: Frame
    let state, color: String
    let isThinking: Bool
    let claudeMode, cliKind, targetKind, displayID, spaceID: String?
    let isPinned: Bool
    /// Minimized through `minimize_window` and not restored since (Q-53).
    let isMinimized: Bool

    init(_ w: FixtureWindow, isMinimized: Bool = false, color: String? = nil) {
        id = w.id; name = w.name; app = w.app; folder = w.folder; enabled = w.enabled
        frame = w.frame; state = w.state; self.color = color ?? w.color; isThinking = w.isThinking ?? false
        claudeMode = w.claudeMode; cliKind = w.cliKind; targetKind = w.targetKind
        displayID = w.displayID; spaceID = w.spaceID; isPinned = w.isPinned ?? false
        self.isMinimized = isMinimized
    }
}

struct LayoutUpdateMsg: Encodable {
    let type = "layout_update"
    let monitor: String
    let screenAspect: Double?
    let windows: [WireWindow]
    let displays: [DisplayInfo]?
    let spanAspect: Double?
    let spaces: [SpaceInfo]?
}

struct AuthResultMsg: Encodable {
    let type = "auth_result"
    let success: Bool
    let error: String?
}

struct DeviceIdentityMsg: Encodable {
    let type = "device_identity"
    let deviceID: String
    let deviceKind = "mac"
    let displayName: String
    let localURLs: [String]
}

/// Everything granted, so the phone shows no permission badge.
struct MacPermissionsMsg: Encodable {
    let type = "mac_permissions"
    let accessibility = true
    let appleEvents = true
    let screenRecording = true
}

/// `preparing` keeps push-to-talk on the phone's own recognizer with no banner.
/// `ready` would route audio here, where nothing transcribes it, and `failed`
/// shows a permanent "Whisper offline" banner.
struct WhisperStatusMsg: Encodable {
    struct State: Encodable { let tag = "preparing" }
    let type = "whisper_status"
    let state = State()
}

struct PromptLibraryMsg: Encodable {
    let type = "prompt_library"
    let prompts: [PromptEntry]
}

struct FrontmostChangedMsg: Encodable {
    let type = "frontmost_changed"
    let windowId: String?
}

struct ProjectDirectoriesMsg: Encodable {
    let type = "project_directories"
    let directories: [String]
}

struct HeartbeatMsg: Encodable {
    let type = "heartbeat"
    let seq: Int
    let ts: Double
}

struct SendTextAckMsg: Encodable {
    let type = "send_text_ack"
    /// Echoed exactly as received.
    let messageId: String
    let injectMs: Int
    let totalMs: Int
    let path: String
}

struct ErrorMsg: Encodable {
    let type = "error"
    let reason: String
    /// Only with --error-ids (US-115 added this field on eb-branch; an installed
    /// Mac from before it omits it).
    let messageId: String?
}

/// The reply the Mac gives when it holds no backup for the device: an empty
/// snapshot, addressed to the device that asked (US-014).
struct PreferencesRestoreMsg: Encodable {
    struct Empty: Encodable {}
    let type = "preferences_restore"
    let deviceID: String
    let preferences = Empty()
}

struct TerminalContentMsg: Encodable {
    let type = "terminal_content"
    let windowId: String
    let content: String
    let urls: [String]
    let hasAutosuggest = false
}

struct PromptAckMsg: Encodable {
    let type: String
    let messageId: String
    let id: String
    let success: Bool
    let error: String?
}

struct ImageUploadErrorMsg: Encodable {
    let type = "image_upload_error"
    let imageId: String
    let reason: String
}

// MARK: - Log

/// One line per event to stdout and to the log file.
final class LogSink: @unchecked Sendable {
    let path: String
    private let file: FileHandle?
    private let lock = NSLock()
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(path: String) {
        self.path = path
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        file = FileHandle(forWritingAtPath: path)
        _ = try? file?.seekToEnd()
        if file == nil {
            try? FileHandle.standardError.write(contentsOf: Data("fake-mac: cannot open log \(path); logging to stdout only\n".utf8))
        }
    }

    func line(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let data = Data("\(stamp.string(from: Date())) \(text)\n".utf8)
        try? FileHandle.standardOutput.write(contentsOf: data)
        try? file?.write(contentsOf: data)
    }
}

// MARK: - Server

final class Client: @unchecked Sendable {
    let number: Int
    let connection: NWConnection
    var handshakeDone = false
    var authenticated = false
    private var rateWindowStart = Date.distantPast
    private var rateCount = 0

    init(number: Int, connection: NWConnection) {
        self.number = number
        self.connection = connection
    }

    var tag: String { "[c\(number)]" }

    /// Mirrors WebSocketServer.ClientConnection.allowMessage: 10 per second.
    func allowMessage(now: Date = Date()) -> Bool {
        if now.timeIntervalSince(rateWindowStart) >= 1 {
            rateWindowStart = now
            rateCount = 1
            return true
        }
        rateCount += 1
        return rateCount <= 10
    }
}

/// All state lives on `queue`; every handler and command runs there.
final class FakeMac: @unchecked Sendable {
    /// Fixed and unlike any real Mac's `quip.deviceID`, so the phone can never
    /// fold this fake's row into a real Mac's row (or a real Mac's Bonjour
    /// address into this row).
    static let deviceID = "FA4E3AC0-0000-4000-8000-000000000001"

    let options: Options
    let queue = DispatchQueue(label: "quip.fake-mac")
    let log: LogSink
    private var fixture: Fixture
    private var windows: [FixtureWindow]
    private var dead: Set<String>
    /// Windows minimized through `minimize_window` (Q-53); `select_window`
    /// restores, `close_window` and `reload` forget.
    private var minimized: Set<String> = []
    /// The latest `preferences_snapshot` per device, served back on
    /// `preferences_request` as the real Mac does. `freeze` stops updates so
    /// a stale backup can be replayed against newer edits (Q-63).
    private var storedPrefs: [String: Data] = [:]
    private var prefsFrozen = false
    /// Colors set through `set_color` (Q-44); nil resets to the fixture's.
    private var colorOverrides: [String: String] = [:]
    private var prompts: [PromptEntry]
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var nextClientNumber = 1
    private var recentMessageIDs: [String: Date] = [:]
    private var lastContentRequest: [String: Date] = [:]
    private var authFailures = 0
    private var lockoutUntil: Date?
    private var heartbeatSeq = 0
    private var heartbeatTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var announced = false
    private var stdinClosedEarly = false
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    var selfURL: String { "ws://127.0.0.1:\(options.port)" }

    /// The `quip://pair` link the phone decodes (Shared/PairingPayload.swift):
    /// the URL travels base64-encoded with its padding stripped.
    var pairingLink: String {
        let b64 = Data(selfURL.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let url = b64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b64
        let pin = options.pin.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? options.pin
        return "quip://pair?url=\(url)&pin=\(pin)"
    }

    init(options: Options, fixture: Fixture, log: LogSink) {
        self.options = options
        self.fixture = fixture
        self.log = log
        windows = fixture.windows
        dead = Set(fixture.windows.filter { $0.dead == true }.map(\.id))
        prompts = fixture.prompts
    }

    // MARK: Listening

    func start() {
        if Self.somethingListens(on: options.port) {
            fatal("something is already listening on 127.0.0.1:\(options.port); pick another --port")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let parameters = NWParameters(tls: nil, tcp: tcp)
        guard let port = NWEndpoint.Port(rawValue: options.port) else { fatal("bad port \(options.port)") }
        // 127.0.0.1 only, on the loopback interface only. Never 0.0.0.0.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.requiredInterfaceType = .loopback
        parameters.includePeerToPeer = false
        // Lets a restart rebind while the last run's sockets sit in TIME_WAIT.
        // The probe above already refused a port another process listens on.
        parameters.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 * 1024 * 1024  // WSLimits.maxMessageBytes
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            fatal("cannot listen on 127.0.0.1:\(options.port): \(error)")
        }
        // No `listener.service`: this fake is never advertised over Bonjour.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.announce()
            case .failed(let error): self.fatal("listener failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
        startHeartbeats()
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.shutdown(sig == SIGINT ? "Ctrl-C" : "SIGTERM") }
            source.resume()
            signalSources.append(source)
        }
    }

    private func announce() {
        log.line("fake-mac listening on \(selfURL) — loopback only, no Bonjour, pid \(getpid())")
        log.line("  fixture \(options.fixturePath): \(windows.count) windows, \(prompts.count) prompts; "
            + "PIN \(options.pin); log \(log.path)"
            + (options.ackPaste ? "; --ack-paste" : "") + (options.errorIDs ? "; --error-ids" : ""))
        log.line("  pair a booted simulator: xcrun simctl openurl <udid> '\(pairingLink)'")
        log.line("  commands: help status layout library close dead alive freeze thaw reload quit")
        announced = true
        if stdinClosedEarly { stdinClosed() }
    }

    /// True when a TCP connect to 127.0.0.1:port succeeds.
    static func somethingListens(on port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return false
        }
    }

    private func fatal(_ message: String) -> Never {
        log.line("fake-mac: \(message)")
        exit(1)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            log.line("REFUSED a connection from non-loopback peer \(connection.endpoint)")
            connection.cancel()
            return
        }
        let client = Client(number: nextClientNumber, connection: connection)
        nextClientNumber += 1
        clients[ObjectIdentifier(connection)] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready:
                client.handshakeDone = true
                // Same first frame as the real Mac with "Require PIN" on.
                self.log.line("\(client.tag) connected from \(connection.endpoint); sent auth_result auth_required")
                self.send(AuthResultMsg(success: false, error: "auth_required"), to: client)
                self.receive(on: client)
            case .failed(let error):
                self.drop(client, why: "failed: \(error)")
            case .cancelled:
                self.drop(client, why: "closed")
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Like the real Mac's PreHandshakeReapPolicy: a socket that never
        // upgrades to WebSocket (a TCP latency probe) is not kept forever.
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak client] in
            guard let self, let client, !client.handshakeDone,
                  self.clients[ObjectIdentifier(client.connection)] != nil else { return }
            self.clients.removeValue(forKey: ObjectIdentifier(client.connection))
            client.connection.cancel()
        }
    }

    private func drop(_ client: Client, why: String) {
        guard clients.removeValue(forKey: ObjectIdentifier(client.connection)) != nil else { return }
        if client.handshakeDone { log.line("\(client.tag) disconnected (\(why))") }
        client.connection.cancel()
    }

    private func receive(on client: Client) {
        client.connection.receiveMessage { [weak self, weak client] data, context, _, error in
            guard let self, let client else { return }
            if let error {
                self.drop(client, why: "receive error: \(error)")
                return
            }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata {
                if meta.opcode == .close {
                    self.drop(client, why: "phone sent close")
                    return
                }
                if meta.opcode != .text && meta.opcode != .binary {  // ping/pong, answered by the stack
                    self.receive(on: client)
                    return
                }
            }
            if let data, !data.isEmpty {
                self.handle(data, from: client)
            } else if context?.isFinal == true {
                self.drop(client, why: "end of stream")
                return
            }
            if self.clients[ObjectIdentifier(client.connection)] != nil { self.receive(on: client) }
        }
    }

    private func send<T: Encodable>(_ message: T, to client: Client) {
        let data: Data
        do {
            data = try encoder.encode(message)
        } catch {
            log.line("\(client.tag) encode FAILED for \(T.self): \(error)")
            return
        }
        sendRaw(data, kind: String(describing: T.self), to: client)
    }

    /// Already-serialized JSON, for messages whose body is passed through
    /// untouched (a stored preferences backup).
    private func sendRaw(_ data: Data, kind: String, to client: Client) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        client.connection.send(content: data, contentContext: context, isComplete: true,
                               completion: .contentProcessed { [weak self] error in
            if let error { self?.log.line("\(client.tag) send \(kind) failed: \(error)") }
        })
    }

    /// To every authenticated phone, as the real Mac's `broadcast` does.
    @discardableResult
    private func broadcast<T: Encodable>(_ message: T) -> Int {
        let targets = clients.values.filter(\.authenticated)
        for client in targets { send(message, to: client) }
        return targets.count
    }

    private func startHeartbeats() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)  // WebSocketServer.heartbeatInterval
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for client in self.clients.values where client.authenticated {
                self.heartbeatSeq += 1
                self.send(HeartbeatMsg(seq: self.heartbeatSeq, ts: Date().timeIntervalSince1970), to: client)
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: Inbound messages

    private func handle(_ data: Data, from client: Client) {
        guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = m["type"] as? String else {
            log.line("\(client.tag) recv frame with no readable type (\(data.count) bytes) — dropped, as the real Mac does")
            return
        }
        if type == "auth" {
            handleAuth(m, from: client)
            return
        }
        let head = "\(client.tag) recv \(type)"
        guard client.allowMessage() else {
            log.line(head + " — DROPPED: over 10 messages/s (the real Mac drops these silently)")
            return
        }
        guard client.authenticated else {
            log.line(head + " — DROPPED: not authenticated (as the real Mac)")
            return
        }
        switch type {
        case "send_text": handleSendText(m, head)
        case "paste_prompt": handlePastePrompt(m, head)
        case "quick_action": handleQuickAction(m, head)
        case "preferences_request":
            let device = m["deviceID"] as? String ?? ""
            if let prefs = storedPrefs[device],
               let body = try? JSONSerialization.jsonObject(with: prefs) as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: [
                   "type": "preferences_restore", "deviceID": device, "preferences": body
               ]) {
                let stamp = (body["savedAt"] as? Double).map { String(Int($0)) } ?? "none"
                log.line(head + " device=\(Self.short(device)) -> preferences_restore, stored backup "
                    + "(\(body.count) keys, savedAt \(stamp), to this phone only)")
                sendRaw(data, kind: "preferences_restore", to: client)
            } else {
                log.line(head + " device=\(Self.short(device)) -> preferences_restore, no backup "
                    + "(empty snapshot, to this phone only)")
                send(PreferencesRestoreMsg(deviceID: device), to: client)
            }
        case "preferences_snapshot":
            let device = m["deviceID"] as? String ?? ""
            let prefs = m["preferences"] as? [String: Any] ?? [:]
            let keys = prefs.keys.sorted()
            let stamp = (prefs["savedAt"] as? Double).map { String(Int($0)) } ?? "none"
            if prefsFrozen {
                log.line(head + " device=\(Self.short(device)) keys=[\(keys.joined(separator: ","))] savedAt \(stamp) "
                    + "-> IGNORED (prefs frozen; the stored backup stays stale)")
            } else if let data = try? JSONSerialization.data(withJSONObject: prefs) {
                storedPrefs[device] = data
                log.line(head + " device=\(Self.short(device)) keys=[\(keys.joined(separator: ","))] savedAt \(stamp) "
                    + "-> stored (values not logged)")
            }
        case "device_identity":
            log.line(head + " kind=\(m["deviceKind"] as? String ?? "?") device=\(Self.short(m["deviceID"] as? String)) "
                + "name=\(Self.quoted(m["displayName"] as? String ?? ""))")
        case "heartbeat_ack":
            log.line(head + " seq=\((m["seq"] as? Int).map(String.init) ?? "?")")
        case "phone_log":
            let lines = m["lines"] as? [String] ?? []
            log.line(head + " lines=\(lines.count): " + Self.preview(lines.joined(separator: " | "), limit: 240))
        case "request_content": handleRequestContent(m, head)
        case "select_window":
            let id = m["windowId"] as? String ?? ""
            log.line(head + " window=\(id)" + (windows.contains { $0.id == id } ? "" : " (not in the layout)"))
            // The Mac un-minimizes before it raises (Q-23), and the next layout
            // no longer reports the window minimized (Q-53).
            if minimized.remove(id) != nil {
                let n = broadcast(layoutMessage())
                log.line(head + " -> restored \(id) from the Dock, layout_update to \(n) phone(s)")
            }
        case "minimize_window": handleMinimizeWindow(m, head)
        case "set_color": handleSetColor(m, head)
        case "close_window": handleCloseWindow(m, head)
        case "put_prompt": handlePutPrompt(m, head)
        case "delete_prompt": handleDeletePrompt(m, head)
        case "image_upload":
            let imageId = m["imageId"] as? String ?? ""
            log.line(head + " image=\(Self.short(imageId)) window=\(m["windowId"] as? String ?? "") "
                + "bytes=\(data.count) -> image_upload_error (the fake stores no images)")
            broadcast(ImageUploadErrorMsg(imageId: imageId, reason: "fake-mac does not accept images"))
        case "register_push_device", "push_preferences":
            log.line(head + " token=\(Self.short(m["deviceToken"] as? String))"
                + ((m["environment"] as? String).map { " env=\($0)" } ?? ""))
        default:
            log.line(head + Self.summary(m))
        }
    }

    /// Mirrors WebSocketServer.handleAuthMessage, including the throttle
    /// (AuthThrottle: +200 ms per failure up to 2 s, 15-minute lockout after
    /// 10). Keyed globally rather than per host: every peer here is 127.0.0.1.
    private func handleAuth(_ m: [String: Any], from client: Client) {
        let head = "\(client.tag) recv auth"
        guard let pin = m["pin"] as? String else {
            log.line(head + " — malformed (no pin)")
            send(AuthResultMsg(success: false, error: "Malformed auth message"), to: client)
            return
        }
        if let until = lockoutUntil {
            if until > Date() {
                let secs = Int(until.timeIntervalSinceNow.rounded(.up))
                log.line(head + " — locked out, \(secs)s left")
                send(AuthResultMsg(success: false, error: "Too many attempts; try again in \(secs)s"), to: client)
                return
            }
            lockoutUntil = nil
            authFailures = 0
        }
        if pin == options.pin {
            authFailures = 0
            client.authenticated = true
            log.line(head + " — PIN ok (length \(pin.count)): AUTHENTICATED; sent auth_result success, device_identity")
            send(AuthResultMsg(success: true, error: nil), to: client)
            send(DeviceIdentityMsg(deviceID: Self.deviceID, displayName: fixture.displayName,
                                   localURLs: [selfURL]), to: client)
            sendWelcome(to: client)
        } else {
            authFailures += 1
            if authFailures >= 10 { lockoutUntil = Date().addingTimeInterval(15 * 60) }
            let delayMs = min(authFailures * 200, 2_000)
            log.line(head + " — WRONG PIN (got length \(pin.count)); auth_result \"Incorrect PIN\" in \(delayMs)ms; "
                + "socket stays open" + (lockoutUntil != nil ? "; now LOCKED OUT for 15 min" : ""))
            queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self, weak client] in
                guard let self, let client else { return }
                self.send(AuthResultMsg(success: false, error: "Incorrect PIN"), to: client)
            }
        }
    }

    /// What `onClientAuthenticated` sends on the real Mac, in its order. The
    /// real Mac broadcasts these to every phone; the fake sends them to the
    /// phone that just authenticated.
    private func sendWelcome(to client: Client) {
        send(layoutMessage(), to: client)
        log.line("\(client.tag) sent layout_update: \(windows.count) windows on \(Self.quoted(fixture.monitor)) "
            + "[\(windows.map(\.id).joined(separator: ", "))]")
        var rest: [String] = []
        if let dirs = fixture.projectDirectories, !dirs.isEmpty {
            send(ProjectDirectoriesMsg(directories: dirs), to: client)
            rest.append("project_directories(\(dirs.count))")
        }
        send(MacPermissionsMsg(), to: client)
        send(WhisperStatusMsg(), to: client)
        rest.append("mac_permissions(all granted)")
        rest.append("whisper_status(preparing)")
        send(PromptLibraryMsg(prompts: prompts), to: client)
        log.line("\(client.tag) sent prompt_library: \(prompts.count) prompts")
        let front = fixture.frontmostWindowId.flatMap { id in windows.contains { $0.id == id } ? id : nil }
        send(FrontmostChangedMsg(windowId: front), to: client)
        rest.append("frontmost_changed(\(front ?? "none"))")
        log.line("\(client.tag) sent " + rest.joined(separator: ", "))
    }

    private func layoutMessage() -> LayoutUpdateMsg {
        // The Mac floats pinned windows to the front of the list.
        let ordered = windows.filter { $0.isPinned == true } + windows.filter { $0.isPinned != true }
        return LayoutUpdateMsg(monitor: fixture.monitor, screenAspect: fixture.screenAspect,
                               windows: ordered.map { WireWindow($0, isMinimized: minimized.contains($0.id),
                                                                   color: colorOverrides[$0.id]) },
                               displays: fixture.displays,
                               spanAspect: fixture.spanAspect, spaces: fixture.spaces)
    }

    /// MessageDedupeTable: a messageId seen in the last 30 s is a duplicate.
    private func isDuplicate(_ messageId: String?) -> Bool {
        guard let messageId else { return false }
        let now = Date()
        recentMessageIDs = recentMessageIDs.filter { now.timeIntervalSince($0.value) < 30 }
        let key = messageId.uppercased()
        if recentMessageIDs[key] != nil { return true }
        recentMessageIDs[key] = now
        return false
    }

    private func handleSendText(_ m: [String: Any], _ head: String) {
        let windowId = m["windowId"] as? String ?? ""
        let messageId = m["messageId"] as? String
        let text = m["text"] as? String ?? ""
        var line = head + " window=\(windowId) messageId=\(Self.short(messageId)) "
            + "pressReturn=\(Self.flag(m["pressReturn"])) textLen=\(text.count) text=\(Self.preview(text))"
        if let raise = m["raiseWindow"] as? Bool { line += " raiseWindow=\(raise ? 1 : 0)" }
        if isDuplicate(messageId) {
            log.line(line + " -> DEDUPED: same messageId within 30s, no reply (as the real Mac)")
            return
        }
        deliver(windowId: windowId, messageId: messageId, line: line)
    }

    /// The real Mac acks once the text has landed, and only when the request
    /// carried a messageId; a window it no longer has gets an `error`. A window
    /// marked dead answers nothing at all, like an injection that never returns.
    private func deliver(windowId: String, messageId: String?, line: String) {
        guard let window = windows.first(where: { $0.id == windowId }) else {
            log.line(line + " -> no such window: error \"Window no longer exists\"")
            broadcast(ErrorMsg(reason: "Window no longer exists", messageId: options.errorIDs ? messageId : nil))
            return
        }
        if dead.contains(windowId) {
            log.line(line + " -> window is DEAD: no reply")
            return
        }
        guard let messageId else {
            log.line(line + " -> delivered; no messageId, so no ack (as the real Mac)")
            return
        }
        let injectMs = Int.random(in: 35...140)
        let totalMs = injectMs + Int.random(in: 3...25)
        let path = Self.route(for: window)
        log.line(line + " -> send_text_ack in \(totalMs)ms path=\(path)")
        queue.asyncAfter(deadline: .now() + .milliseconds(totalMs)) { [weak self] in
            self?.broadcast(SendTextAckMsg(messageId: messageId, injectMs: injectMs, totalMs: totalMs, path: path))
        }
    }

    /// `routingPath` in the Mac's send_text handler.
    static func route(for window: FixtureWindow) -> String {
        guard window.isTerminal else { return "genericApp" }
        let pasted = window.app.lowercased().hasPrefix("iterm") && (window.cliKind == "codex" || window.cliKind == "grok")
        return pasted ? "pasteText" : "sendText"
    }

    private func handlePastePrompt(_ m: [String: Any], _ head: String) {
        let promptId = m["id"] as? String ?? ""
        let windowId = m["windowId"] as? String ?? ""
        let messageId = m["messageId"] as? String
        var line = head + " prompt=\(promptId) window=\(windowId) messageId=\(Self.short(messageId)) "
            + "pressReturn=\(Self.flag(m["pressReturn"]))"
        if let raise = m["raiseWindow"] as? Bool { line += " raiseWindow=\(raise ? 1 : 0)" }
        if isDuplicate(messageId) {
            log.line(line + " -> DEDUPED: same messageId within 30s, no reply (as the real Mac)")
            return
        }
        guard let prompt = prompts.first(where: { $0.id == promptId }) else {
            // The Mac answers an attributed error since US-115; before it the
            // request was dropped silently, which --ack-paste off reproduces.
            guard options.ackPaste else {
                log.line(line + " -> unknown prompt id: ignored, no reply (a Mac from before US-115)")
                return
            }
            let reason = "Prompt paste failed: no prompt \"\(promptId)\" on this Mac"
            log.line(line + " -> unknown prompt id: error \"\(reason)\"")
            broadcast(ErrorMsg(reason: reason, messageId: options.errorIDs ? messageId : nil))
            return
        }
        if let window = windows.first(where: { $0.id == windowId }) {
            let (filled, unfilled) = Self.fill(prompt.body, for: window)
            line += " filled=\(Self.preview(filled))"
            if !unfilled.isEmpty { line += " unfilled=\(unfilled.joined(separator: ","))" }
        }
        if options.ackPaste {
            deliver(windowId: windowId, messageId: messageId, line: line)
        } else if !windows.contains(where: { $0.id == windowId }) {
            log.line(line + " -> no such window: error \"Window no longer exists\"")
            broadcast(ErrorMsg(reason: "Window no longer exists", messageId: options.errorIDs ? messageId : nil))
        } else if dead.contains(windowId) {
            log.line(line + " -> window is DEAD: no reply")
        } else {
            log.line(line + " -> pasted; no ack (today's Mac sends none; --ack-paste simulates US-115)")
        }
    }

    private static let placeholder = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_.\-]*)\s*\}\}"#)

    /// PromptTemplate.expand with the values PromptVariables would use. The
    /// clipboard is never read: `{{clipboard}}` stays literal here.
    static func fill(_ body: String, for window: FixtureWindow) -> (String, [String]) {
        let date: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let values = ["folder": window.folder ?? "", "window": window.name, "agent": window.cliKind ?? "shell",
                      "cwd": window.cwd ?? "", "date": date].filter { !$0.value.isEmpty }
        var text = ""
        var unfilled: [String] = []
        var cursor = body.startIndex
        for match in placeholder.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let whole = Range(match.range, in: body), let nameRange = Range(match.range(at: 1), in: body) else { continue }
            let name = body[nameRange].lowercased()
            text += body[cursor..<whole.lowerBound]
            if let value = values[name] {
                text += value
            } else {
                text += body[whole]
                if !unfilled.contains(name) { unfilled.append(name) }
            }
            cursor = whole.upperBound
        }
        text += body[cursor...]
        return (text, unfilled)
    }

    private func handleQuickAction(_ m: [String: Any], _ head: String) {
        let windowId = m["windowId"] as? String ?? ""
        let action = m["action"] as? String ?? ""
        let messageId = m["messageId"] as? String
        let line = head + " action=\(action) window=\(windowId) messageId=\(Self.short(messageId))"
            + (m["promptFingerprint"] is String ? " fingerprint=yes" : "")
        if isDuplicate(messageId) {
            log.line(line + " -> DEDUPED: same messageId within 30s (as the real Mac)")
            return
        }
        if action == "test_push" {
            log.line(line + " -> test push: nothing to do (the fake has no APNs)")
            return
        }
        guard windows.contains(where: { $0.id == windowId }) else {
            log.line(line + " -> no such window: error \"Window no longer exists\"")
            broadcast(ErrorMsg(reason: "Window no longer exists", messageId: options.errorIDs ? messageId : nil))
            return
        }
        log.line(line + " -> done (the Mac never acks quick actions)")
    }

    private func handleRequestContent(_ m: [String: Any], _ head: String) {
        let windowId = m["windowId"] as? String ?? ""
        let now = Date()
        // The real Mac answers at most twice a second per window.
        if let last = lastContentRequest[windowId], now.timeIntervalSince(last) < 0.5 {
            log.line(head + " window=\(windowId) -> throttled (<0.5s since the last one), as the real Mac")
            return
        }
        lastContentRequest[windowId] = now
        guard let window = windows.first(where: { $0.id == windowId }) else {
            log.line(head + " window=\(windowId) -> no such window: nothing sent (as the real Mac)")
            return
        }
        let content = window.content ?? (window.isTerminal
            ? "~/dev/\(window.folder ?? "project") $ "
            : "[non-terminal window — screenshot requires Screen Recording permission for Quip]")
        let urls = Self.urls(in: content)
        log.line(head + " window=\(windowId) -> terminal_content (\(content.count) chars, \(urls.count) urls)")
        broadcast(TerminalContentMsg(windowId: windowId, content: content, urls: urls))
    }

    static func urls(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#) else { return [] }
        let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// Q-53: the window stays in the layout, reported `isMinimized`, until
    /// `select_window` restores it. Unknown windows get the attributed error
    /// the Mac sends.
    /// `set_color` (Q-44): the real Mac validates the hex, stores an override
    /// and rebroadcasts the layout; the card recolors on that broadcast.
    private func handleSetColor(_ m: [String: Any], _ head: String) {
        let windowId = m["windowId"] as? String ?? ""
        let color = m["color"] as? String
        let line = head + " window=\(windowId) color=\(color ?? "nil")"
        guard windows.contains(where: { $0.id == windowId }) else {
            log.line(line + " -> no such window: ignored (as the real Mac)")
            return
        }
        if let color {
            let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else {
                log.line(line + " -> not #RRGGBB: ignored (as the real Mac)")
                return
            }
            colorOverrides[windowId] = "#" + hex.uppercased()
        } else {
            colorOverrides.removeValue(forKey: windowId)
        }
        let n = broadcast(layoutMessage())
        log.line(line + " -> stored, layout_update to \(n) phone(s)")
    }

    private func handleMinimizeWindow(_ m: [String: Any], _ head: String) {
        let windowId = m["windowId"] as? String ?? ""
        let messageId = m["messageId"] as? String
        let line = head + " window=\(windowId) messageId=\(Self.short(messageId))"
        if isDuplicate(messageId) {
            log.line(line + " -> DEDUPED (as the real Mac)")
            return
        }
        guard windows.contains(where: { $0.id == windowId }) else {
            log.line(line + " -> no such window: error \"Window no longer exists\"")
            broadcast(ErrorMsg(reason: "Window no longer exists", messageId: options.errorIDs ? messageId : nil))
            return
        }
        minimized.insert(windowId)
        let n = broadcast(layoutMessage())
        log.line(line + " -> minimized, layout_update to \(n) phone(s) (\(minimized.count) minimized)")
    }

    private func handleCloseWindow(_ m: [String: Any], _ head: String) {
        let windowId = m["windowId"] as? String ?? ""
        let messageId = m["messageId"] as? String
        let line = head + " window=\(windowId) messageId=\(Self.short(messageId))"
        if isDuplicate(messageId) {
            log.line(line + " -> DEDUPED (as the real Mac)")
            return
        }
        guard windows.contains(where: { $0.id == windowId }) else {
            log.line(line + " -> no such window: error \"Window no longer exists\"")
            broadcast(ErrorMsg(reason: "Window no longer exists", messageId: options.errorIDs ? messageId : nil))
            return
        }
        windows.removeAll { $0.id == windowId }
        minimized.remove(windowId)
        let n = broadcast(layoutMessage())
        log.line(line + " -> closed; layout_update (\(windows.count) windows) to \(n) phone(s)")
    }

    /// Kept in memory only — the fixture file is never written.
    private func handlePutPrompt(_ m: [String: Any], _ head: String) {
        let id = m["id"] as? String ?? ""
        let messageId = m["messageId"] as? String
        let line = head + " prompt=\(id) messageId=\(Self.short(messageId))"
        if isDuplicate(messageId) {
            log.line(line + " -> DEDUPED (as the real Mac)")
            return
        }
        guard !id.isEmpty, !id.contains("/"), let label = m["label"] as? String, let body = m["body"] as? String else {
            log.line(line + " -> malformed: put_prompt_ack failure")
            if let messageId {
                broadcast(PromptAckMsg(type: "put_prompt_ack", messageId: messageId, id: id, success: false,
                                       error: "Prompt could not be saved on the Mac."))
            }
            return
        }
        let entry = PromptEntry(id: id, label: label, body: body, tags: m["tags"] as? [String],
                                targetAgent: m["targetAgent"] as? String, description: m["description"] as? String)
        if let i = prompts.firstIndex(where: { $0.id == id }) { prompts[i] = entry } else { prompts.append(entry) }
        let n = broadcast(PromptLibraryMsg(prompts: prompts))
        if let messageId {
            broadcast(PromptAckMsg(type: "put_prompt_ack", messageId: messageId, id: id, success: true, error: nil))
        }
        log.line(line + " -> saved in memory; prompt_library (\(prompts.count)) and ack to \(n) phone(s)")
    }

    private func handleDeletePrompt(_ m: [String: Any], _ head: String) {
        let id = m["id"] as? String ?? ""
        let messageId = m["messageId"] as? String
        let line = head + " prompt=\(id) messageId=\(Self.short(messageId))"
        if isDuplicate(messageId) {
            log.line(line + " -> DEDUPED (as the real Mac)")
            return
        }
        let existed = prompts.contains { $0.id == id }
        prompts.removeAll { $0.id == id }
        let n = existed ? broadcast(PromptLibraryMsg(prompts: prompts)) : 0
        if let messageId {
            broadcast(PromptAckMsg(type: "delete_prompt_ack", messageId: messageId, id: id, success: existed,
                                   error: existed ? nil : "Prompt could not be deleted on the Mac."))
        }
        log.line(line + (existed ? " -> deleted in memory; prompt_library (\(prompts.count)) to \(n) phone(s)"
                                 : " -> no such prompt: delete_prompt_ack failure"))
    }

    // MARK: Commands (stdin)

    func command(_ raw: String) {
        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = words.first?.lowercased() else { return }
        let arg = words.dropFirst().joined(separator: " ")
        switch verb {
        case "help", "?":
            log.line("""
            commands:
              status          phones, windows (dead or not) and prompts
              layout          resend layout_update to every phone
              library         resend prompt_library to every phone
              close <window>  drop a window from the layout and resend it
              dead <window>   stop answering send_text for a window (no ack, no error)
              alive <window>  answer it again
              reload          re-read the fixture: restores closed windows and edited prompts
              quit            close every connection and exit
            <window> is an id, or any unique part of an id, name or folder.
            """)
        case "status":
            let phones = clients.values.filter(\.handshakeDone).sorted { $0.number < $1.number }
            log.line("status: \(phones.count) phone(s): "
                + (phones.isEmpty ? "none" : phones.map { "\($0.tag)\($0.authenticated ? " authenticated" : " awaiting PIN")" }
                    .joined(separator: ", ")))
            for w in windows {
                log.line("  \(w.id)  \(w.app)  \(w.folder ?? "-")  \(dead.contains(w.id) ? "DEAD" : "acking")"
                    + (minimized.contains(w.id) ? "  minimized" : ""))
            }
            log.line("  \(prompts.count) prompts; paste acks \(options.ackPaste ? "on" : "off"); "
                + "error ids \(options.errorIDs ? "on" : "off")")
        case "layout":
            let n = broadcast(layoutMessage())
            log.line("cmd layout -> layout_update (\(windows.count) windows) to \(n) phone(s)")
        case "freeze":
            prefsFrozen = true
            log.line("cmd freeze -> preferences_snapshot is ignored from now on (\(storedPrefs.count) backup(s) kept as they are)")
        case "thaw":
            prefsFrozen = false
            log.line("cmd thaw -> preferences_snapshot is stored again")
        case "library":
            let n = broadcast(PromptLibraryMsg(prompts: prompts))
            log.line("cmd library -> prompt_library (\(prompts.count) prompts) to \(n) phone(s)")
        case "close", "dead", "alive":
            guard let window = resolveWindow(arg, verb: verb) else { return }
            switch verb {
            case "close":
                windows.removeAll { $0.id == window.id }
                let n = broadcast(layoutMessage())
                log.line("cmd close \(window.id) -> layout_update (\(windows.count) windows) to \(n) phone(s)")
            case "dead":
                dead.insert(window.id)
                log.line("cmd dead \(window.id) -> send_text to it now gets no reply")
            default:
                dead.remove(window.id)
                log.line("cmd alive \(window.id) -> send_text to it is acked again")
            }
        case "reload":
            do {
                let fresh = try Fixture.load(path: options.fixturePath)
                fixture = fresh
                windows = fresh.windows
                dead = Set(fresh.windows.filter { $0.dead == true }.map(\.id))
                minimized = []
                prompts = fresh.prompts
                let n = broadcast(layoutMessage())
                broadcast(PromptLibraryMsg(prompts: prompts))
                log.line("cmd reload -> \(windows.count) windows, \(prompts.count) prompts, resent to \(n) phone(s)")
            } catch let error as UsageError {
                log.line("cmd reload FAILED, keeping the current data: \(error.message)")
            } catch {
                log.line("cmd reload FAILED, keeping the current data: \(error)")
            }
        case "quit", "exit":
            shutdown("quit")
        default:
            log.line("unknown command \(Self.quoted(verb)); type help")
        }
    }

    private func resolveWindow(_ arg: String, verb: String) -> FixtureWindow? {
        guard !arg.isEmpty else {
            log.line("usage: \(verb) <window id, or a unique part of an id, name or folder>")
            return nil
        }
        if let exact = windows.first(where: { $0.id == arg }) { return exact }
        let needle = arg.lowercased()
        let hits = windows.filter {
            $0.id.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
                || ($0.folder?.lowercased().contains(needle) ?? false)
        }
        if hits.count == 1 { return hits[0] }
        log.line(hits.isEmpty
            ? "\(verb): no window matches \(Self.quoted(arg)) (closed windows come back with reload)"
            : "\(verb): \(Self.quoted(arg)) matches \(hits.count) windows: \(hits.map(\.id).joined(separator: ", "))")
        return nil
    }

    func stdinClosed() {
        guard announced else {
            stdinClosedEarly = true  // said after the banner, not before it
            return
        }
        log.line("stdin closed: commands are off; stop with Ctrl-C or kill \(getpid())")
    }

    private func shutdown(_ why: String) {
        log.line("fake-mac stopping (\(why))")
        heartbeatTimer?.cancel()
        listener?.cancel()
        for client in clients.values { client.connection.cancel() }
        exit(0)
    }

    // MARK: Formatting

    static func short(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "none" }
        return String(id.prefix(8))
    }

    static func flag(_ value: Any?) -> String {
        (value as? Bool).map { $0 ? "1" : "0" } ?? "-"
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func preview(_ text: String, limit: Int = 48) -> String {
        let flat = text.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        return quoted(flat.count > limit ? String(flat.prefix(limit)) + "…" : flat)
    }

    /// Ids and other short fields worth a log line; never text, data or PINs.
    static func summary(_ m: [String: Any]) -> String {
        let keys = ["windowId", "sourceWindowId", "id", "action", "messageId", "sessionId", "seq", "imageId",
                    "target_id", "terminal_id", "layout", "pane", "directory", "agent", "windowNumber", "pinned", "color"]
        let parts = keys.compactMap { key -> String? in
            guard let value = m[key] else { return nil }
            if key == "messageId" || key == "sessionId" { return "\(key)=\(short(value as? String))" }
            return "\(key)=\(value)"
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)

let fakeOptions: Options
let fakeFixture: Fixture
do {
    fakeOptions = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    fakeFixture = try Fixture.load(path: fakeOptions.fixturePath)
} catch let error as UsageError {
    try? FileHandle.standardError.write(contentsOf: Data("fake-mac: \(error.message)\n\n\(Options.usage)\n".utf8))
    exit(2)
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("fake-mac: \(error)\n".utf8))
    exit(2)
}

let fakeMac = FakeMac(options: fakeOptions, fixture: fakeFixture, log: LogSink(path: fakeOptions.logPath))
fakeMac.queue.sync { fakeMac.start() }

Thread.detachNewThread { [fakeMac] in
    while let line = readLine() {
        fakeMac.queue.async { fakeMac.command(line) }
    }
    fakeMac.queue.async { fakeMac.stdinClosed() }
}

dispatchMain()
