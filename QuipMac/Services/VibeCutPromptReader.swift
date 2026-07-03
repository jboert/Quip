// VibeCutPromptReader.swift
// QuipMac — reads VibeCut's prompt catalog from disk for one-way inherit
// (see the plan in ~/.claude/plans/cached-bubbling-mochi.md).
//
// This is the ONLY VibeCut file-format seam. Everything downstream — the include
// filter, id namespacing, tag/provenance, meta emission — lives in the pure Shared
// `VibeCutPromptMapper`, so this type just locates + decodes the JSON.

import Foundation

struct VibeCutPromptReader {
    /// Repo root (e.g. `~/Projects/vibecut`). The catalog is `<root>/shared/prompts.json`.
    let root: URL

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

    /// The configured repo root: `vibecutRepoPath` UserDefaults override (tilde
    /// expanded) if set, else the `~/Projects/vibecut` default. Mirrors the
    /// override precedent used by `spawnCommand` / `tailscaleHostnameOverride`.
    static func defaultRoot() -> URL {
        let raw = UserDefaults.standard.string(forKey: "vibecutRepoPath")
            .flatMap { $0.isEmpty ? nil : $0 } ?? "~/Projects/vibecut"
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    /// Decode the catalog. Throws `.repoNotFound` when the JSON is absent (so the
    /// caller can leave the existing inherited set untouched) and `.unreadable`
    /// on a read/parse failure.
    func read() throws -> VibeCutCatalog {
        let url = promptsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadError.repoNotFound(path: url.path)
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(VibeCutCatalog.self, from: data)
        } catch {
            throw ReadError.unreadable(path: url.path)
        }
    }
}
