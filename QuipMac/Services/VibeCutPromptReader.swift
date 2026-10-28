// VibeCutPromptReader.swift
// QuipMac — reads VibeCut's prompt catalog from disk for one-way inherit
// (see the plan in ~/.claude/plans/cached-bubbling-mochi.md).
//
// This is the ONLY VibeCut file-format seam. Everything downstream — the include
// filter, id namespacing, tag/provenance, meta emission — lives in the pure Shared
// `VibeCutPromptMapper`, so this type just locates + decodes the JSON sources.

import Foundation
import CryptoKit

struct VibeCutPromptReader {
    /// Repo root (e.g. `~/Projects/vibecut`). The catalog is `<root>/shared/prompts.json`.
    let root: URL
    /// VibeCut's user prompt packs (`~/Library/Application Support/VibeCut/packs/*.json`).
    let packsDirectory: URL
    /// VibeCut's prompt-editor saves (`~/Library/Application Support/VibeCut/actions`, Q-77).
    let actionsDirectory: URL
    /// VibeCut's PRIVATE project-prompt store
    /// (`~/Library/Application Support/VibeCut/private/projects.json`). It holds
    /// the owner's project prompts and is never in any repo, so it is read from
    /// the app-support folder only. Missing is normal: no project prompts.
    let privateStoreURL: URL

    init(root: URL, packsDirectory: URL = VibeCutPromptReader.defaultPacksDirectory(),
         actionsDirectory: URL = VibeCutEditRecords.defaultActionsDirectory(),
         privateStoreURL: URL = VibeCutPromptReader.defaultPrivateStoreURL()) {
        self.root = root
        self.packsDirectory = packsDirectory
        self.actionsDirectory = actionsDirectory
        self.privateStoreURL = privateStoreURL
    }

    enum ReadError: Error, CustomStringConvertible {
        case repoNotFound(path: String)
        case unreadable(path: String)
        case unsupportedVersion(String)

        var description: String {
            switch self {
            case .repoNotFound(let p): return "VibeCut repo not found at \(p)"
            case .unreadable(let p): return "VibeCut prompts could not be read at \(p)"
            case .unsupportedVersion(let v):
                return "VibeCut catalog version \(v) is newer than this Quip understands"
            }
        }
    }

    /// Highest catalog `version` major this Quip understands.
    static let supportedCatalogMajor = 3
    /// The only pack `format` this Quip understands.
    static let supportedPackFormat = "vibecutpack/1"

    var promptsFileURL: URL {
        root.appendingPathComponent("shared/prompts.json")
    }

    var fragmentsFileURL: URL {
        root.appendingPathComponent("shared/prompt-fragments.json")
    }

    var organizationFileURL: URL {
        root.appendingPathComponent("shared/prompt-organization.json")
    }

    static func defaultPacksDirectory() -> URL {
        URL(fileURLWithPath:
            ("~/Library/Application Support/VibeCut/packs" as NSString).expandingTildeInPath)
    }

    static func defaultPrivateStoreURL() -> URL {
        URL(fileURLWithPath:
            ("~/Library/Application Support/VibeCut/private/projects.json" as NSString).expandingTildeInPath)
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
        /// `sourceFingerprint()` taken just BEFORE the read (Q-82): a file that
        /// changes mid-read shows as "changed" next time, never as "current".
        var fingerprint: String? = nil
    }

    /// SHA-256 over every file a sync reads — the catalog, fragments,
    /// organization, each pack, and each editor save — by name and bytes, so
    /// Settings can say whether VibeCut changed since the last sync (Q-82).
    /// Nil when the catalog is missing: "unknown", not "changed".
    func sourceFingerprint() -> String? {
        guard let catalog = try? Data(contentsOf: promptsFileURL) else { return nil }
        var hasher = SHA256()
        func add(_ name: String, _ data: Data?) {
            hasher.update(data: Data("\(name)\u{0}\(data?.count ?? -1)\u{0}".utf8))
            if let data { hasher.update(data: data) }
        }
        add("prompts.json", catalog)
        add("prompt-fragments.json", try? Data(contentsOf: fragmentsFileURL))
        add("prompt-organization.json", try? Data(contentsOf: organizationFileURL))
        add("private/projects.json", try? Data(contentsOf: privateStoreURL))
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: packsDirectory.path)) ?? []).sorted()
        where name.hasSuffix(".json") {
            add("packs/" + name, try? Data(contentsOf: packsDirectory.appendingPathComponent(name)))
        }
        for name in ((try? fm.contentsOfDirectory(atPath: actionsDirectory.path)) ?? []).sorted()
        where name.hasSuffix(".edit.json") || name.hasSuffix(".scpt") {
            add("actions/" + name, try? Data(contentsOf: actionsDirectory.appendingPathComponent(name)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Decode the catalog and merge any VibeCut prompt packs. Throws `.repoNotFound`
    /// when the git-tracked catalog is absent (so the caller can leave the existing
    /// inherited set untouched), `.unsupportedVersion` when the catalog `version` major
    /// is newer than Quip understands (or unparseable), and `.unreadable` on a
    /// read/parse failure of the main catalog. Pack files are best-effort: a single corrupt user pack must not block
    /// the rest of the VibeCut inherit sync — it is counted in `skippedPacks` instead.
    func read() throws -> ReadResult {
        let url = promptsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadError.repoNotFound(path: url.path)
        }
        let fingerprint = sourceFingerprint()
        do {
            let data = try Data(contentsOf: url)
            var catalog = try JSONDecoder().decode(VibeCutCatalog.self, from: data)
            // A missing version is a legacy catalog and is accepted.
            if let version = catalog.version, !Self.isSupported(version: version) {
                throw ReadError.unsupportedVersion(version)
            }
            let packs = readPackPrompts()
            catalog.prompts.append(contentsOf: packs.prompts)
            // After packs: store prompts are appended, and assignments scope
            // catalog/pack buttons to projects by VibeCut id.
            catalog = Self.applyPrivateStore(to: catalog, storeData: try? Data(contentsOf: privateStoreURL))
            // Before fragments: a saved edit may still contain a placeholder.
            catalog = VibeCutEditRecords.apply(to: catalog, actionsDirectory: actionsDirectory)
            // Optional: a catalog with no placeholders needs no fragment file.
            let fragments = (try? Data(contentsOf: fragmentsFileURL))
                .map { VibeCutPromptMapper.decodeFragments($0) } ?? [:]
            catalog = VibeCutPromptMapper.expandFragments(in: catalog, fragments: fragments)
            // Optional: without it prompts just carry no purpose/needs tags.
            let annotations = (try? Data(contentsOf: organizationFileURL))
                .map { VibeCutPromptMapper.decodeOrganization($0) } ?? [:]
            catalog = VibeCutPromptMapper.applyOrganization(in: catalog, annotations: annotations)
            return ReadResult(catalog: catalog, skippedPacks: packs.skipped, fingerprint: fingerprint)
        } catch let error as ReadError {
            throw error
        } catch {
            throw ReadError.unreadable(path: url.path)
        }
    }

    /// Shape of VibeCut's private store (`version` 1). Decoded leniently: any
    /// failure reads as "no store" and never blocks the rest of the sync.
    private struct PrivateStore: Decodable {
        var version: Int?
        var prompts: [VibeCutPrompt]?
        var assignments: [String: [String]]?
    }

    static let supportedStoreVersion = 1

    /// Fold the private store into `catalog`: its prompts are appended (text,
    /// category `project`, `projects` carried, flagged so the mapper tags them
    /// local-only), and each assignment sets `projects` on the catalog prompt
    /// with that VibeCut id. Nil data, a corrupt file, or a `version` above 1
    /// leaves the catalog untouched.
    static func applyPrivateStore(to catalog: VibeCutCatalog, storeData: Data?) -> VibeCutCatalog {
        guard let storeData,
              let store = try? JSONDecoder().decode(PrivateStore.self, from: storeData),
              (store.version ?? 1) <= supportedStoreVersion else { return catalog }
        var out = catalog
        for (id, projects) in store.assignments ?? [:] where !projects.isEmpty {
            for i in out.prompts.indices where out.prompts[i].id == id {
                out.prompts[i].projects = projects
            }
        }
        for var p in store.prompts ?? [] {
            p.type = "text"
            p.category = "project"
            p.fromPrivateStore = true
            out.prompts.append(p)
        }
        return out
    }

    /// Major = the integer before the first ".". Unparseable counts as unsupported.
    private static func isSupported(version: String) -> Bool {
        let head = version.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        guard let major = Int(head) else { return false }
        return major <= supportedCatalogMajor
    }

    /// Just the pack's top-level `format`; `VibeCutCatalog` stays untouched.
    private struct PackHeader: Decodable {
        let format: String?
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
                let header = try? JSONDecoder().decode(PackHeader.self, from: data),
                header.format == Self.supportedPackFormat,
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
