// PromptLibrary.swift
// QuipMac — watches ~/Library/Application Support/Quip/prompts/*.txt
// and exposes the catalog to the iPhone (wishlist §57). Mirrors the
// Stream Deck "clipboard prompt" pattern from
// /Users/erickbzovi/Projects/streamdeck-claude-scripts: each file is a
// named prompt the user can paste into the active iTerm session with
// one tap from the phone.

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class PromptLibrary {

    private static let logger = Logger(subsystem: "com.quip.mac", category: "PromptLibrary")

    /// Latest snapshot of prompts on disk. Updated on launch + whenever
    /// the directory's contents change (DispatchSourceFileSystemObject
    /// watches mtime; we rescan on any event). Each PromptEntry carries
    /// the full body now so iPhone can edit without a second round-trip.
    private(set) var entries: [PromptEntry] = []

    /// Called when `entries` changes. Wired by the host to broadcast a
    /// PromptLibraryMessage to every connected client.
    var onChange: (@MainActor ([PromptEntry]) -> Void)?

    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1
    private var watcherRescanTask: Task<Void, Never>?

    /// `~/Library/Application Support/Quip/prompts/`. Created on first
    /// access if missing, with a README inside so the user knows what
    /// goes there.
    static var directory: URL {
        if let directoryOverrideForTests {
            return directoryOverrideForTests
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Quip/prompts", isDirectory: true)
    }
    static var directoryOverrideForTests: URL?

    func start() {
        ensureDirExists()
        seedReadmeIfNeeded()
        rescan()
        startWatching()
    }

    func stop() {
        watcherRescanTask?.cancel()
        watcherRescanTask = nil
        watcher?.cancel()
        watcher = nil
        if watcherFD >= 0 {
            close(watcherFD)
            watcherFD = -1
        }
    }

    /// Look up the full body for a given entry id (used when the phone
    /// fires paste_prompt). Returns nil if the file was deleted or
    /// renamed since the last scan.
    func body(for id: String) -> String? {
        entries.first(where: { $0.id == id })?.body
    }

    /// Write a prompt to disk under `<id>.txt`. If `label` differs from
    /// `id`, prefix the file with `# label\n\n` so the round-trip
    /// preserves the friendly title. Returns the URL on success, nil on
    /// failure (filesystem error or sanitization rejection).
    @discardableResult
    func put(id: String, label: String, body: String,
             tags: [String]? = nil, targetAgent: String? = nil, description: String? = nil) -> URL? {
        let safeID = Self.sanitizeID(id)
        guard !safeID.isEmpty else { return nil }
        // Saving a prompt crashed the WHOLE Mac app (2026-06-14 18:14): the
        // path went PromptLibrary.put → String.write(to:atomically:) →
        // swift-foundation writeToFileAux → SIGTRAP (a runtime trap, NOT a
        // thrown error — so the old do/catch couldn't catch it). The prompts
        // directory already existed with 26 files at the time, so this was
        // the atomic temp+rename machinery trapping, not a missing folder.
        //
        // Fix: write via the ObjC `FileManager.createFile` (returns Bool,
        // never throws, never traps) instead of any swift-foundation atomic
        // write. A prompt .txt is small and non-critical, so the loss of
        // atomicity is fine. ensureDirExists() keeps the parent present.
        ensureDirExists()
        let url = Self.directory.appendingPathComponent("\(safeID).txt")
        let fileBody = Self.renderFile(id: safeID, label: label, body: body,
                                       tags: tags, targetAgent: targetAgent, description: description)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(fileBody.utf8)) else {
            print("[PromptLibrary] put failed for \(safeID): createFile returned false")
            return nil
        }
        // Keep clients in sync immediately. The file watcher remains a
        // fallback for external edits and coalesced writes.
        rescan()
        return url
    }

    /// Delete the prompt file for the given id. README.txt is excluded
    /// from sanitization since it can't be deleted via this path anyway.
    @discardableResult
    func delete(id: String) -> Bool {
        let safeID = Self.sanitizeID(id)
        guard !safeID.isEmpty, safeID != "README" else { return false }
        let url = Self.directory.appendingPathComponent("\(safeID).txt")
        do {
            try FileManager.default.removeItem(at: url)
            rescan()
            return true
        } catch {
            print("[PromptLibrary] delete failed for \(safeID): \(error)")
            return false
        }
    }

    /// Replace the entire inherited VibeCut set on disk in ONE batch that fires
    /// exactly one broadcast. Deletes every `vibecut__*.txt` (the reserved
    /// namespace only — never touches the user's own prompts or README.txt), then
    /// writes the fresh set via the same non-throwing `createFile` path as `put()`,
    /// then rescans ONCE. Returns the number of files written.
    ///
    /// The single-broadcast guarantee relies on this running synchronously on the
    /// MainActor: the FS watcher's rescan hops through a 0.15s-debounced
    /// `@MainActor` Task, so it cannot preempt this method mid-batch, and the
    /// trailing watcher-driven `rescan()` no-ops against `rescan()`'s equality
    /// guard (`newEntries == entries`). N prompts → one `prompt_library` message,
    /// not N. Do not introduce an `await` between the delete and the final rescan.
    @discardableResult
    func replaceVibeCutSet(_ inherited: [PromptEntry]) -> Int {
        ensureDirExists()
        let fm = FileManager.default

        // 1. Delete the prior inherited set — reserved `vibecut__` filename
        //    namespace ONLY, so a user-authored prompt (or README.txt) is never
        //    at risk even if it happens to carry a `vibecut` tag.
        if let urls = try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) {
            for url in urls where url.pathExtension == "txt"
                && url.lastPathComponent.hasPrefix(VibeCutPromptMapper.idPrefix) {
                try? fm.removeItem(at: url)
            }
        }

        // 2. Write the fresh set (non-throwing createFile — see put()'s SIGTRAP note).
        var written = 0
        for entry in inherited {
            let safeID = Self.sanitizeID(entry.id)
            guard !safeID.isEmpty else { continue }
            let url = Self.directory.appendingPathComponent("\(safeID).txt")
            let fileBody = Self.renderFile(id: safeID, label: entry.label, body: entry.body,
                                           tags: entry.tags, targetAgent: entry.targetAgent,
                                           description: entry.description)
            if fm.createFile(atPath: url.path, contents: Data(fileBody.utf8)) { written += 1 }
        }

        // 3. One rescan → one onChange → one broadcast.
        rescan()
        return written
    }

    /// Strip path separators / leading dots / shell metacharacters so a
    /// hostile id (e.g. `../../../etc/passwd`) can't escape the prompts
    /// directory or write outside it. Allowed: alphanumeric, dash,
    /// underscore, dot in the middle. Empty result = reject.
    static func sanitizeID(_ raw: String) -> String {
        var out = ""
        for ch in raw {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." {
                out.append(ch)
            } else if ch == " " {
                out.append("-")
            }
        }
        // Strip leading dots (no hidden files, no `.` / `..` traversal).
        while out.first == "." { out.removeFirst() }
        return out
    }

    private func ensureDirExists() {
        try? FileManager.default.createDirectory(at: Self.directory,
                                                 withIntermediateDirectories: true)
    }

    private func seedReadmeIfNeeded() {
        let readme = Self.directory.appendingPathComponent("README.txt")
        guard !FileManager.default.fileExists(atPath: readme.path) else { return }
        let body = """
        Quip prompt library
        ===================

        Drop one .txt file per prompt in this directory. Filename (without
        the .txt extension) becomes the label shown on the iPhone, and
        the file body becomes the prompt that gets typed into the active
        iTerm session when you tap that row.

        First-line override: if the file starts with "# Some title", that
        line becomes the label and is stripped from the prompt body. Use
        this when you want a friendlier label than the filename allows.

        Bulk import from Stream Deck scripts:
            ~/Projects/Quip/QuipMac/Tools/import-streamdeck-prompts.sh \\
                ~/Projects/streamdeck-claude-scripts

        That uses osadecompile to pull the `set the clipboard to "..."`
        body out of each .scpt and writes it here as a .txt file.

        Reserved: files named "vibecut__*.txt" are managed by the VibeCut
        prompt-inherit sync (Settings -> Prompts -> Sync on the phone). They
        are deleted + rewritten on every sync, so do NOT hand-edit them or
        name your own prompts with the "vibecut__" prefix.
        """
        try? body.write(to: readme, atomically: true, encoding: .utf8)
    }

    /// Read every `.txt` in the directory (skip README), build entries +
    /// body cache, fire onChange when the result differs from last scan.
    private func rescan() {
        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: Self.directory,
                                              includingPropertiesForKeys: nil)
        } catch {
            Self.logger.error("PromptLibrary directory listing failed at \(Self.directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let textFiles = urls
            .filter { $0.pathExtension == "txt" && $0.lastPathComponent != "README.txt" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

        var newEntries: [PromptEntry] = []
        for url in textFiles {
            let raw: String
            do {
                raw = try String(contentsOf: url, encoding: .utf8)
            } catch {
                Self.logger.warning("PromptLibrary skipping \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let id = url.deletingPathExtension().lastPathComponent
            let p = Self.parsePrompt(filename: id, raw: raw)
            newEntries.append(PromptEntry(id: id, label: p.label, body: p.body,
                                          tags: p.tags, targetAgent: p.targetAgent, description: p.description))
        }

        if newEntries == entries { return }
        entries = newEntries
        onChange?(newEntries)
    }

    /// Parsed shape of a prompt file: optional `# label`, optional
    /// `<!-- quip:meta ... -->` front-matter (§6.1), then the body.
    struct ParsedPrompt: Equatable {
        let label: String
        let body: String
        let tags: [String]?
        let targetAgent: String?
        let description: String?
    }

    /// Pure parser — pulled out for tests. Handles legacy headerless files
    /// and `# label` files unchanged, plus an optional `<!-- quip:meta -->`
    /// block carrying tags/agent/desc.
    nonisolated static func parsePrompt(filename: String, raw: String) -> ParsedPrompt {
        var lines = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")

        var label = filename
        // Only treat `# ...` as a label when there's a body after it, matching
        // the legacy behavior (a lone "# x" line stays body).
        if lines.count > 1, let first = lines.first, first.hasPrefix("# ") {
            let l = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { label = l }
            lines.removeFirst()
        }
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }

        var tags: [String]?
        var agent: String?
        var desc: String?
        if lines.first?.trimmingCharacters(in: .whitespaces) == "<!-- quip:meta" {
            lines.removeFirst()
            while let m = lines.first, m.trimmingCharacters(in: .whitespaces) != "-->" {
                let t = m.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("tags:") {
                    let arr = String(t.dropFirst(5)).split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    tags = arr.isEmpty ? nil : arr
                } else if t.hasPrefix("agent:") {
                    let v = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    agent = v.isEmpty ? nil : v
                } else if t.hasPrefix("desc:") {
                    let v = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    desc = v.isEmpty ? nil : v
                }
                lines.removeFirst()
            }
            if !lines.isEmpty { lines.removeFirst() }  // drop "-->"
        }

        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedPrompt(label: label, body: body, tags: tags, targetAgent: agent, description: desc)
    }

    /// Back-compat shim for callers that only want (label, body).
    nonisolated static func extractLabelAndBody(filename: String, raw: String) -> (label: String, body: String) {
        let p = parsePrompt(filename: filename, raw: raw)
        return (p.label, p.body)
    }

    /// The `<!-- quip:meta -->` block, or nil when no metadata is set.
    nonisolated static func metaBlock(tags: [String]?, targetAgent: String?, description: String?) -> String? {
        var ls: [String] = []
        if let tags, !tags.isEmpty { ls.append("tags: " + tags.joined(separator: ", ")) }
        if let a = targetAgent, !a.isEmpty { ls.append("agent: \(a)") }
        if let d = description, !d.isEmpty { ls.append("desc: \(d)") }
        guard !ls.isEmpty else { return nil }
        return "<!-- quip:meta\n" + ls.joined(separator: "\n") + "\n-->\n"
    }

    /// Render the on-disk file contents. **Byte-identical to the legacy
    /// format when no metadata is set** (guards existing files from churn).
    nonisolated static func renderFile(id: String, label: String, body: String,
                                       tags: [String]?, targetAgent: String?, description: String?) -> String {
        let labelDiffers = !label.isEmpty && label != id
        let meta = metaBlock(tags: tags, targetAgent: targetAgent, description: description)
        var out = ""
        if labelDiffers { out += "# \(label)\n" }
        if let meta { out += meta }
        if labelDiffers || meta != nil { out += "\n" }
        out += "\(body)\n"
        return out
    }

    private func startWatching() {
        let path = Self.directory.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watcherFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )
        // DispatchSource invokes these handlers on a background dispatch
        // queue. They MUST be @Sendable — that forces them NONISOLATED.
        // Otherwise the compiler infers @MainActor isolation (PromptLibrary is
        // @MainActor), and the runtime traps via swift_task_checkIsolatedSwift
        // the instant DispatchSource calls the closure off-main, BEFORE any
        // body runs (so an inner Task/assumeIsolated can't save it). This was
        // the repeated SIGTRAP on 2026-06-15 (20:55 / 21:07 / 21:11), firing
        // on every prompts-dir change — including put()'s own write. The hop
        // to the MainActor happens via a Task INSIDE the @Sendable closure.
        let onEvent: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleWatcherRescan() }
        }
        source.setEventHandler(handler: onEvent)
        let onCancel: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.watcherFD >= 0 else { return }
                close(self.watcherFD)
                self.watcherFD = -1
            }
        }
        source.setCancelHandler(handler: onCancel)
        source.resume()
        watcher = source
    }

    private func scheduleWatcherRescan() {
        // 0.15s debounce so a burst of file-system events (e.g. an atomic
        // write's temp-create + rename, or a bulk import) coalesces into one
        // rescan. A cancellable @MainActor Task replaces the old
        // DispatchWorkItem — rescan() is main-actor state, and the Task runs
        // on the actor's executor (no isolation-assert trap).
        watcherRescanTask?.cancel()
        watcherRescanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }
}
