// SwrmEventTailer.swift
// QuipMac — subscribes to a swrm project's append-only event spine by
// incrementally tailing `<projectRoot>/.swrm/events.ndjson`. This is the
// canonical "other apps subscribe to the spine" pattern swrm is designed
// for: swrm requires ZERO changes — we copy its own Swift reader contract
// (`EventLog.readIncremental`, native/SwrmCore/Sources/SwrmCore/EventLog.swift)
// and mirror its TS tailer's cursor discipline (src/events/subscribe.ts).
//
// US-001 scope: tail one project's log restart-safe (byte+seq cursor) and
// deliver parsed events via `onEvents`. Title resolution (US-003), the
// trigger filter (US-004), push/inject (US-005/007) and lifecycle wiring
// (US-008) build on top of this; they are NOT in this file.
//
// Everything here is best-effort and non-throwing: a missing dir/log logs
// a warning and no-ops, never crashes. See the swrm-board-integration PRD.

import Foundation
import Observation

// MARK: - Event model (copied from swrm EventLog.swift, trimmed to the
// summary fields Quip needs: data carries {from, to, title})

/// One swrm event envelope (`events: v1`). `data` is decoded into the small
/// set of fields Quip reads; unknown payload keys are ignored.
struct SwrmEvent: Identifiable, Equatable {
    let seq: Int
    let ts: String              // ISO-8601 Z, e.g. "2026-06-03T17:08:21Z"
    let project: String?
    let actor: String           // "user" | "agent:<name>"
    let type: String            // e.g. "task.moved"
    let version: Int
    let aggregateType: String   // "task" | "attempt" | …
    let aggregateID: String     // numeric or string id, normalized
    let data: SwrmEventData

    var id: Int { seq }

    /// The agent name when `actor` is "agent:<name>", else nil (→ a user event).
    var agentName: String? {
        actor.hasPrefix("agent:") ? String(actor.dropFirst("agent:".count)) : nil
    }

    /// US-004 trigger predicate: a story was moved into the `in_progress`
    /// column ("Started"). Pure — depends only on the event envelope, so it
    /// is directly unit-testable with no I/O. The card (US-004), push (US-005)
    /// and terminal inject (US-007) all fan out from this one condition.
    var isStoryStarted: Bool {
        type == "task.moved" && data.to == "in_progress"
    }
}

/// The subset of an event's `data` payload Quip uses: a story title (on
/// `task.created`/`task.planned`) and the column move (`from`/`to`, on
/// `task.moved`). All optional.
struct SwrmEventData: Equatable {
    var title: String?
    var from: String?
    var to: String?
}

// MARK: - Reader (copied from swrm EventLogReader — the inter-app contract)

/// Swift reader for swrm's event spine. Reads `.swrm/events.ndjson` directly
/// (no server, offline, restart-safe); each line is one event envelope.
/// Torn-trailing-line tolerant exactly like swrm's own reader.
enum SwrmEventReader {
    /// `<projectRoot>/.swrm/events.ndjson` — the committed, portable log.
    static func eventsFileURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".swrm", isDirectory: true)
            .appendingPathComponent("events.ndjson")
    }

    /// One-shot full read of a project's log (every event with `seq > since`,
    /// chronological). Used to seed caches at startup (US-003); slurps the
    /// whole file, which is correct and cheap at single-project scale.
    static func read(projectRoot: URL, since: Int = 0, limit: Int? = nil) -> [SwrmEvent] {
        read(fileURL: eventsFileURL(projectRoot: projectRoot), since: since, limit: limit)
    }

    /// Read directly from an `.ndjson` file (the testable seam).
    static func read(fileURL: URL, since: Int = 0, limit: Int? = nil) -> [SwrmEvent] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return [] // file may not exist yet — no events
        }
        var out: [SwrmEvent] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lastIndex = lines.indices.last
        for (i, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue } // blank lines are always benign
            guard let bytes = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            else {
                // Only the LAST non-blank line can be a benign torn/partial
                // trailing write; an interior unparseable line is permanently
                // corrupt, so surface it once (parity with swrm's reader).
                if i != lastIndex {
                    SwrmEventTailer.globalLog("read: skipping corrupt NDJSON line \(i + 1) in \(fileURL.lastPathComponent)")
                }
                continue
            }
            guard let ev = parse(obj), ev.seq > since else { continue }
            out.append(ev)
        }
        out.sort { $0.seq < $1.seq }
        if let limit, out.count > limit { out = Array(out.suffix(limit)) }
        return out
    }

    /// Tail a log incrementally from a byte cursor — the native twin of swrm's
    /// TS `createTailer`. Seeks to `byteOffset`, reads only `[byteOffset, EOF)`,
    /// and returns the cursor (`nextOffset`) to resume from.
    ///
    /// Torn-line discipline matches `read(...)`: it splits on "\n" keeping the
    /// final segment, which is HELD BACK — its bytes are not consumed and
    /// `nextOffset` does NOT advance past the last complete-line boundary, so
    /// the next read picks the line up whole once it finishes. `since` gates
    /// delivery by seq so a re-read across a cursor boundary never
    /// double-delivers.
    static func readIncremental(fileURL: URL, byteOffset: Int, since: Int)
        -> (events: [SwrmEvent], nextOffset: Int)
    {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return ([], byteOffset) // file may not exist yet — no new events
        }
        defer { try? handle.close() }

        // Seek to the cursor; a cursor past EOF (truncation) reads nothing.
        do {
            try handle.seek(toOffset: UInt64(max(0, byteOffset)))
        } catch {
            return ([], byteOffset)
        }
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else {
            return ([], byteOffset) // no new bytes since the cursor
        }
        guard let text = String(data: chunk, encoding: .utf8) else {
            // Non-UTF-8 mid-stream (a multibyte char split across this read's
            // EOF). Hold everything for next pump; don't advance the cursor.
            return ([], byteOffset)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // The final segment is the held-back tail — never parsed here. Its
        // byte length is what we DON'T consume from this chunk.
        let tail = lines.last.map(String.init) ?? ""
        let consumed = chunk.count - tail.utf8.count
        let nextOffset = byteOffset + consumed

        var out: [SwrmEvent] = []
        let complete = lines.dropLast()
        for raw in complete {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let bytes = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            else {
                SwrmEventTailer.globalLog("readIncremental: skipping corrupt NDJSON line in \(fileURL.lastPathComponent)")
                continue
            }
            guard let ev = parse(obj), ev.seq > since else { continue }
            out.append(ev)
        }
        out.sort { $0.seq < $1.seq }
        return (out, nextOffset)
    }

    // MARK: parsing

    static func parse(_ o: [String: Any]) -> SwrmEvent? {
        guard let seq = intValue(o["seq"]),
              let type = o["type"] as? String, !type.isEmpty,
              let ts = o["ts"] as? String
        else { return nil }

        let agg = o["aggregate"] as? [String: Any]
        let aggType = (agg?["type"] as? String) ?? "unknown"
        let aggID = stringValue(agg?["id"]) ?? ""

        return SwrmEvent(
            seq: seq,
            ts: ts,
            project: o["project"] as? String,
            actor: (o["actor"] as? String) ?? "user",
            type: type,
            version: intValue(o["v"]) ?? 1,
            aggregateType: aggType,
            aggregateID: aggID,
            data: parseData(o["data"] as? [String: Any] ?? [:])
        )
    }

    static func parseData(_ d: [String: Any]) -> SwrmEventData {
        var e = SwrmEventData()
        e.title = d["title"] as? String
        e.from = d["from"] as? String
        e.to = d["to"] as? String
        return e
    }

    /// JSON numbers arrive as NSNumber; ids may also be plain strings.
    static func intValue(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func stringValue(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}

// MARK: - Cursor (byte offset + seq), persisted OUTSIDE .swrm/

/// A resume point for one project's tail. `byteOffset` is where to seek next;
/// `seq` is the highest delivered event seq (the dedupe gate).
struct SwrmCursor: Codable, Equatable {
    var byteOffset: Int
    var seq: Int

    static let zero = SwrmCursor(byteOffset: 0, seq: 0)
}

/// Persists one cursor per project root under Quip's app-support — NOT inside
/// `.swrm/` (that is swrm's committed log; we are a read-only subscriber).
/// Mirrors swrm `subscribe.ts`'s cursor authority: the consumer owns its
/// resume point. Best-effort: read failures fall back to `.zero`, write
/// failures are logged and swallowed.
enum SwrmCursorStore {
    /// `~/Library/Application Support/Quip/swrm/cursors/`. Overridable in tests
    /// (set single-threaded in test setup before any access).
    nonisolated(unsafe) static var directoryOverrideForTests: URL?

    static var directory: URL {
        if let directoryOverrideForTests { return directoryOverrideForTests }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Quip/swrm/cursors", isDirectory: true)
    }

    /// Stable, human-readable filename derived from the absolute root path:
    /// drop the leading slash and replace separators so two roots never share
    /// a file. Collision-free for real filesystem paths.
    static func filename(forRootPath rootPath: String) -> String {
        var out = ""
        for ch in rootPath {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        while out.first == "_" { out.removeFirst() }
        if out.isEmpty { out = "root" }
        return out + ".json"
    }

    static func cursorURL(forRootPath rootPath: String) -> URL {
        directory.appendingPathComponent(filename(forRootPath: rootPath))
    }

    /// Whether a cursor has ever been persisted for this root. Used by the
    /// tailer's US-008 first-launch policy to distinguish a brand-new root
    /// (seed past history, no replay) from a resume (honor the saved cursor).
    static func exists(forRootPath rootPath: String) -> Bool {
        FileManager.default.fileExists(atPath: cursorURL(forRootPath: rootPath).path)
    }

    static func load(forRootPath rootPath: String) -> SwrmCursor {
        let url = cursorURL(forRootPath: rootPath)
        // No file is the normal first-launch case (`exists` above is what the
        // policy actually keys on), so absence stays quiet. A file that IS
        // there but won't decode is different: falling back to `.zero` replays
        // the entire event history, and until now it did that without a word.
        guard FileManager.default.fileExists(atPath: url.path) else { return .zero }
        do {
            return try JSONDecoder().decode(SwrmCursor.self, from: Data(contentsOf: url))
        } catch {
            SwrmEventTailer.globalLog("cursor load failed for \(rootPath): \(error.localizedDescription) — "
                      + "resetting to .zero, which REPLAYS the full event history for this root")
            return .zero
        }
    }

    static func save(_ cursor: SwrmCursor, forRootPath rootPath: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = cursorURL(forRootPath: rootPath)
        do {
            let data = try JSONEncoder().encode(cursor)
            try data.write(to: url, options: .atomic)
        } catch {
            SwrmEventTailer.globalLog("cursor save failed for \(rootPath): \(error.localizedDescription)")
        }
    }
}

// MARK: - Tailer

/// Tails one swrm project's event log incrementally and delivers parsed events
/// on the main actor via `onEvents`. Driven by an fs watch on the `.swrm/`
/// directory (watch the DIR, not the file — the file may not exist yet and
/// gets atomically replaced) plus a poll-timer fallback for missed events.
@MainActor
@Observable
final class SwrmEventTailer {

    /// The project root whose `.swrm/events.ndjson` we tail.
    let projectRoot: URL

    /// Delivered on the main actor whenever new events are read. The host wires
    /// this to the title cache / trigger / broadcast pipeline (later stories).
    var onEvents: (@MainActor ([SwrmEvent]) -> Void)?

    /// Poll cadence for the fs-watch fallback. The watch should catch most
    /// writes; this backstops a missed event (and the first-existence of a
    /// log that didn't exist when we started watching).
    private let pollInterval: TimeInterval

    private var cursor: SwrmCursor
    private var started = false

    // US-008 first-launch policy: true only when a cursor was already persisted
    // for this root at init. A fresh root (false) seeds its cursor to the end of
    // the current log on `start()` so configuring a project mid-history doesn't
    // replay every past `task.moved` as a "story started" card/push/inject storm.
    private let hadPersistedCursor: Bool

    // US-003: in-memory story-title cache keyed by aggregateID. `task.moved`
    // carries only {from,to} — never a title — so the title is learned from the
    // `task.created`/`task.planned` events that DO carry `data.title`, both as
    // they stream (`ingestTitles`) and via a one-shot full-history seed at
    // start (`seedTitleCache`). File-only: no swrm SQLite access.
    private(set) var titleCache: [String: String] = [:]

    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1
    private var pollTimer: DispatchSourceTimer?
    private var pendingPump: DispatchWorkItem?

    // Pump serialization: file reads run off-main on `ioQueue`; cursor mutation
    // and delivery happen on main. At most one pump is in flight; a request
    // that arrives mid-pump is coalesced into a single re-pump.
    private let ioQueue = DispatchQueue(label: "com.quip.mac.swrm.tail", qos: .utility)
    private var isPumping = false
    private var pumpQueued = false

    init(projectRoot: URL, pollInterval: TimeInterval = 2.0) {
        self.projectRoot = projectRoot
        self.pollInterval = pollInterval
        self.cursor = SwrmCursorStore.load(forRootPath: projectRoot.path)
        self.hadPersistedCursor = SwrmCursorStore.exists(forRootPath: projectRoot.path)
    }

    /// Begin tailing. Catches up from the persisted cursor immediately, then
    /// watches the `.swrm/` dir and arms a poll fallback. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        Self.globalLog("start: \(projectRoot.path) (cursor offset=\(cursor.byteOffset) seq=\(cursor.seq))")
        seedTitleCache()     // US-003: seed title cache from full history (file-only)
        if !hadPersistedCursor {
            seedCursorToLatest()  // US-008: skip pre-existing history on first launch
        }
        requestPump()        // catch up on anything written while we were down
        startWatching()
        startPolling()
    }

    /// Stop tailing and release the fs watch + timer. Idempotent.
    func stop() {
        guard started else { return }
        started = false
        Self.globalLog("stop: \(projectRoot.path)")
        pendingPump?.cancel(); pendingPump = nil
        pollTimer?.cancel(); pollTimer = nil
        watcher?.cancel(); watcher = nil
        if watcherFD >= 0 { close(watcherFD); watcherFD = -1 }
    }

    /// The current resume point (exposed for tests/diagnostics).
    var currentCursor: SwrmCursor { cursor }

    // MARK: title cache (US-003)

    /// Event types that carry a story title in `data.title`. `task.moved`
    /// deliberately does NOT — hence the cache.
    private static let titleBearingTypes: Set<String> = ["task.created", "task.planned"]

    /// One-shot full read of the project's history to (re)seed the title cache.
    /// Independent of the byte cursor, so titles from a `task.created` consumed
    /// in a prior run (now behind the cursor) survive a restart. File-only — no
    /// swrm SQLite. Synchronous; the per-project log is small (see `read` doc).
    /// `@discardableResult` returns the cache size for tests/diagnostics.
    @discardableResult
    func seedTitleCache() -> Int {
        ingestTitles(from: SwrmEventReader.read(projectRoot: projectRoot))
        return titleCache.count
    }

    /// Absorb titles from any title-bearing events in `events` into the cache.
    /// Later titles win (an edited story title overwrites an earlier one).
    func ingestTitles(from events: [SwrmEvent]) {
        for ev in events where Self.titleBearingTypes.contains(ev.type) {
            guard let title = ev.data.title, !title.isEmpty, !ev.aggregateID.isEmpty
            else { continue }
            titleCache[ev.aggregateID] = title
        }
    }

    /// Resolve a story's display title by aggregateID, with the PRD fallback
    /// `Story #<id>` when no title was ever seen (no crash, no blank).
    func resolvedTitle(forAggregateID id: String) -> String {
        if let title = titleCache[id], !title.isEmpty { return title }
        return "Story #\(id)"
    }

    // MARK: first-launch cursor seed (US-008)

    /// US-008: advance the cursor to the end of the current log WITHOUT
    /// delivering, so a root configured mid-history doesn't replay every past
    /// `task.moved` to `in_progress` as a fresh "story started" storm of
    /// cards/pushes/injects. Reuses the reader's torn-line discipline:
    /// `readIncremental(byteOffset:0)` returns `nextOffset` at the last
    /// complete-line boundary (a half-written trailing line is held back and
    /// picked up whole on the next real pump) and the highest seq seen. Only
    /// called for a fresh root (no persisted cursor). File-only; titles are
    /// seeded separately by `seedTitleCache` (cursor-independent), so a later
    /// real move still resolves its title.
    private func seedCursorToLatest() {
        let fileURL = SwrmEventReader.eventsFileURL(projectRoot: projectRoot)
        let result = SwrmEventReader.readIncremental(
            fileURL: fileURL, byteOffset: 0, since: 0)
        cursor.byteOffset = result.nextOffset
        if let maxSeq = result.events.map(\.seq).max() {
            cursor.seq = max(cursor.seq, maxSeq)
        }
        SwrmCursorStore.save(cursor, forRootPath: projectRoot.path)
        Self.globalLog("first-launch seed: \(projectRoot.path) cursor advanced to offset=\(cursor.byteOffset) seq=\(cursor.seq) (no historical replay)")
    }

    // MARK: pump

    private func requestPump() {
        guard started else { return }
        if isPumping { pumpQueued = true; return }
        isPumping = true

        let fileURL = SwrmEventReader.eventsFileURL(projectRoot: projectRoot)
        let start = cursor
        let rootPath = projectRoot.path

        ioQueue.async { [weak self] in
            let result = SwrmEventReader.readIncremental(
                fileURL: fileURL, byteOffset: start.byteOffset, since: start.seq)
            DispatchQueue.main.async {
                guard let self else { return }
                // Advance the cursor: byte offset always moves to nextOffset;
                // seq advances to the highest delivered (monotonic, never back).
                self.cursor.byteOffset = result.nextOffset
                if let maxSeq = result.events.map(\.seq).max() {
                    self.cursor.seq = max(self.cursor.seq, maxSeq)
                }
                SwrmCursorStore.save(self.cursor, forRootPath: rootPath)

                if !result.events.isEmpty {
                    // US-003: learn titles from this batch (seq-sorted, so a
                    // task.created precedes a same-batch task.moved) BEFORE
                    // delivery, so onEvents handlers can resolve titles.
                    self.ingestTitles(from: result.events)
                    Self.globalLog("delivered \(result.events.count) event(s) from \(rootPath) (cursor offset=\(self.cursor.byteOffset) seq=\(self.cursor.seq))")
                    self.onEvents?(result.events)
                }

                self.isPumping = false
                if self.pumpQueued {
                    self.pumpQueued = false
                    self.requestPump()
                }
            }
        }
    }

    /// Debounce bursty fs events (an append can fire several .write/.extend
    /// notifications) into a single pump.
    private func scheduleDebouncedPump() {
        pendingPump?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingPump = nil
            self?.requestPump()
        }
        pendingPump = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: fs watch + poll

    /// Watch the `.swrm/` DIRECTORY, not the log file: the log may not exist
    /// when we start, and swrm may atomically replace it (rename swaps the
    /// inode out from under a file-level watch). A dir watch survives both.
    /// If the dir doesn't exist yet, the poll fallback covers it.
    private func startWatching() {
        let dir = projectRoot.appendingPathComponent(".swrm", isDirectory: true).path
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            Self.globalLog("watch: .swrm/ not present yet at \(dir) — relying on poll fallback")
            return
        }
        watcherFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.scheduleDebouncedPump() }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watcherFD, fd >= 0 { close(fd) }
            self?.watcherFD = -1
        }
        source.resume()
        watcher = source
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.requestPump() }
        }
        timer.resume()
        pollTimer = timer
    }

    // MARK: logging

    /// Append a line to `~/Library/Logs/Quip/swrm.log`. `nonisolated static`
    /// so the reader/cursor-store (off-actor) can log too. Best-effort.
    nonisolated static func globalLog(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        let path = LogPaths.swrmPath
        LogPaths.rotateIfNeeded(path: path)
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
        print("[SwrmEventTailer] \(msg)")
    }
}
