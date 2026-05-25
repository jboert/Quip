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
    var onChange: (([PromptEntry]) -> Void)?

    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1

    /// `~/Library/Application Support/Quip/prompts/`. Created on first
    /// access if missing, with a README inside so the user knows what
    /// goes there.
    static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Quip/prompts", isDirectory: true)
    }

    func start() {
        ensureDirExists()
        seedReadmeIfNeeded()
        rescan()
        startWatching()
    }

    func stop() {
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
        let url = Self.directory.appendingPathComponent("\(safeID).txt")
        let fileBody = Self.renderFile(id: safeID, label: label, body: body,
                                       tags: tags, targetAgent: targetAgent, description: description)
        do {
            try fileBody.write(to: url, atomically: true, encoding: .utf8)
            // FS watcher will fire and rescan; return immediately so the
            // calling handler can ack the phone fast.
            return url
        } catch {
            print("[PromptLibrary] put failed for \(safeID): \(error)")
            return nil
        }
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
            return true
        } catch {
            print("[PromptLibrary] delete failed for \(safeID): \(error)")
            return false
        }
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
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.rescan() }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watcherFD, fd >= 0 { close(fd) }
            self?.watcherFD = -1
        }
        source.resume()
        watcher = source
    }
}
