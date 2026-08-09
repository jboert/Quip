// VibeCutPromptReader.swift
// QuipMac — reads VibeCut's prompt catalog from disk for one-way inherit
// (see the plan in ~/.claude/plans/cached-bubbling-mochi.md).
//
// This is the ONLY VibeCut file-format seam. Everything downstream — the include
// filter, id namespacing, tag/provenance, meta emission — lives in the pure Shared
// `VibeCutPromptMapper`, so this type just locates + decodes the JSON sources.

import Foundation

struct VibeCutPromptReader {
    /// Repo root (e.g. `~/Projects/vibecut`). The catalog is `<root>/shared/prompts.json`.
    let root: URL
    /// VibeCut's user prompt packs (`~/Library/Application Support/VibeCut/packs/*.json`).
    let packsDirectory: URL

    init(root: URL, packsDirectory: URL = VibeCutPromptReader.defaultPacksDirectory()) {
        self.root = root
        self.packsDirectory = packsDirectory
    }

    enum ReadError: Error, CustomStringConvertible {
        case repoNotFound(path: String)
        case unreadable(path: String)

        var description: String {
            switch self {
            case .repoNotFound(let p): return "VibeCut repo not found at \(p)"
            case .unreadable(let p): return "VibeCut prompts could not be read at \(p)"
            }
        }
    }

    var promptsFileURL: URL {
        root.appendingPathComponent("shared/prompts.json")
    }

    static func defaultPacksDirectory() -> URL {
        URL(fileURLWithPath:
            ("~/Library/Application Support/VibeCut/packs" as NSString).expandingTildeInPath)
    }

    /// The configured repo root: `vibecutRepoPath` UserDefaults override (tilde
    /// expanded) if set, else the `~/Projects/vibecut` default. Mirrors the
    /// override precedent used by `spawnCommand` / `tailscaleHostnameOverride`.
    static func defaultRoot() -> URL {
        let raw = UserDefaults.standard.string(forKey: "vibecutRepoPath")
            .flatMap { $0.isEmpty ? nil : $0 } ?? "~/Projects/vibecut"
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    /// Merged catalog plus the number of `.json` pack files that could not be
    /// decoded (surfaced to the phone so a corrupt import isn't silently ignored).
    /// `Sendable` so the whole read can be done off the main thread and the
    /// result handed back — see `handleSyncVibeCut`. The read walks a packs
    /// directory and decodes every JSON in it, which is not work the MainActor
    /// should be doing.
    struct ReadResult: Sendable {
        let catalog: VibeCutCatalog
        let skippedPacks: Int
    }

    /// Decode the catalog and merge any VibeCut prompt packs. Throws `.repoNotFound`
    /// when the git-tracked catalog is absent (so the caller can leave the existing
    /// inherited set untouched) and `.unreadable` on a read/parse failure of the main
    /// catalog. Pack files are best-effort: a single corrupt user pack must not block
    /// the rest of the VibeCut inherit sync — it is counted in `skippedPacks` instead.
    func read() throws -> ReadResult {
        let url = promptsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadError.repoNotFound(path: url.path)
        }
        do {
            let data = try Data(contentsOf: url)
            var catalog = try JSONDecoder().decode(VibeCutCatalog.self, from: data)
            let packs = readPackPrompts()
            catalog.prompts.append(contentsOf: packs.prompts)
            return ReadResult(catalog: catalog, skippedPacks: packs.skipped)
        } catch {
            throw ReadError.unreadable(path: url.path)
        }
    }

    private func readPackPrompts() -> (prompts: [VibeCutPrompt], skipped: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: packsDirectory.path) else {
            return ([], 0)
        }

        var prompts: [VibeCutPrompt] = []
        var skipped = 0
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = packsDirectory.appendingPathComponent(name)
            guard
                let data = try? Data(contentsOf: url),
                let pack = try? JSONDecoder().decode(VibeCutCatalog.self, from: data)
            else {
                skipped += 1
                continue
            }
            prompts.append(contentsOf: pack.prompts)
        }
        return (prompts, skipped)
    }
}
