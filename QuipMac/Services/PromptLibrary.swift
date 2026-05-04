// PromptLibrary.swift
// QuipMac — watches ~/Library/Application Support/Quip/prompts/*.txt
// and exposes the catalog to the iPhone (wishlist §57). Mirrors the
// Stream Deck "clipboard prompt" pattern from
// /Users/erickbzovi/Projects/streamdeck-claude-scripts: each file is a
// named prompt the user can paste into the active iTerm session with
// one tap from the phone.

import Foundation
import Observation

@MainActor
@Observable
final class PromptLibrary {

    /// Latest snapshot of prompts on disk. Updated on launch + whenever
    /// the directory's contents change (DispatchSourceFileSystemObject
    /// watches mtime; we rescan on any event).
    private(set) var entries: [PromptEntry] = []
    /// Full bodies keyed by entry id. iPhone never sees this — only the
    /// preview (first ~120 chars) goes over the wire to keep the
    /// PromptLibraryMessage payload small. Mac uses this when the phone
    /// fires `paste_prompt`.
    private(set) var bodiesByID: [String: String] = [:]

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
        bodiesByID[id]
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
        guard let urls = try? fm.contentsOfDirectory(at: Self.directory,
                                                    includingPropertiesForKeys: nil) else {
            return
        }
        let textFiles = urls
            .filter { $0.pathExtension == "txt" && $0.lastPathComponent != "README.txt" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

        var newEntries: [PromptEntry] = []
        var newBodies: [String: String] = [:]
        for url in textFiles {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            let (label, body) = Self.extractLabelAndBody(filename: id, raw: raw)
            let preview = String(body.prefix(120))
            newEntries.append(PromptEntry(
                id: id, label: label,
                bodyPreview: preview, bodyBytes: body.utf8.count
            ))
            newBodies[id] = body
        }

        if newEntries == entries { return }
        entries = newEntries
        bodiesByID = newBodies
        onChange?(newEntries)
    }

    /// Pure helper — pulled out for tests. If the file's first non-empty
    /// line starts with `# `, treat that as the label and strip it from
    /// the body. Otherwise label = filename.
    static func extractLabelAndBody(filename: String, raw: String) -> (label: String, body: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstNewline = trimmed.firstIndex(of: "\n"),
              trimmed.hasPrefix("# ") else {
            return (filename, trimmed)
        }
        let titleLine = String(trimmed[..<firstNewline])
        let label = String(titleLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let bodyStart = trimmed.index(after: firstNewline)
        let body = String(trimmed[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (label.isEmpty ? filename : label, body)
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
