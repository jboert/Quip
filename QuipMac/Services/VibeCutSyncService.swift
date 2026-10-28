// VibeCutSyncService.swift
// QuipMac — one sync engine + remembered status for the VibeCut prompt inherit.
//
// Two triggers funnel through sync(into:): the phone's `sync_vibecut` message
// (QuipMacApp.handleSyncVibeCut) and the Settings → Prompts "Sync Now" button.
// Keeping the read/map/replace pipeline in one place means the counts, the
// failure handling, and the no-wipe-on-a-transient-miss rule cannot drift
// between the two entry points. The service also persists the last outcome so
// Settings can answer "did a sync ever run, and how did it go?" — previously
// the only trace was a print() to stdout, invisible when launched from Finder.

import Foundation
import Observation

@MainActor
@Observable
final class VibeCutSyncService {

    /// Result of one sync attempt. Persisted (UserDefaults JSON) so the
    /// Settings pane still shows the last run after a relaunch.
    struct Outcome: Codable, Equatable, Sendable {
        let date: Date
        let synced: Int
        let skipped: Int
        let skippedPacks: Int
        let error: String?
    }

    private(set) var lastOutcome: Outcome?
    private(set) var isSyncing = false

    /// Latest repo probe: the resolved root path and whether the catalog file
    /// exists there. `repoFound == nil` until the first probe returns.
    private(set) var repoPath: String = VibeCutPromptReader.defaultRoot().path
    private(set) var repoFound: Bool?

    /// Whether VibeCut changed since the last successful sync (Q-82). Unknown is
    /// its own state: it is never shown as Current.
    enum Freshness: Equatable, Sendable {
        case unknown, neverSynced, current, changed
    }
    private(set) var freshness: Freshness = .unknown

    private static let outcomeKey = "vibecutLastSyncOutcome"
    private static let syncedFingerprintKey = "vibecutLastSyncedFingerprint"

    /// Pure rule behind `freshness`. `hasSynced` is true once any sync succeeded,
    /// including ones from before fingerprints were recorded: those read Unknown.
    static func freshness(syncedFingerprint: String?, currentFingerprint: String?,
                          hasSynced: Bool) -> Freshness {
        guard let current = currentFingerprint else { return .unknown }
        guard let synced = syncedFingerprint else { return hasSynced ? .unknown : .neverSynced }
        return synced == current ? .current : .changed
    }

    /// VibeCut source id → Quip id from earlier syncs (Q-79). Tests point this at a temp file.
    static var idMapURLOverrideForTests: URL?
    static var idMapURL: URL {
        if let idMapURLOverrideForTests { return idMapURLOverrideForTests }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Quip/vibecut-ids.json")
    }

    /// Missing or corrupt reads as no known ids, so every prompt falls back to its name-derived id.
    static func loadIDMap() -> [String: String] {
        guard let data = try? Data(contentsOf: idMapURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func saveIDMap(_ map: [String: String]) throws {
        let url = idMapURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(map).write(to: url, options: .atomic)
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.outcomeKey),
           let outcome = try? JSONDecoder().decode(Outcome.self, from: data) {
            lastOutcome = outcome
        }
    }

    /// Re-resolve the repo root (`vibecutRepoPath` default or ~/Projects/vibecut)
    /// and stat its catalog file off the main thread. Cheap, but Settings calls
    /// this on every pane appearance — and a stat can block on a dead network
    /// volume, which is exactly the class of main-thread work that has hung this
    /// app before. Fire-and-forget face of `probeFreshness()`.
    func refreshRepoProbe() {
        Task { @MainActor in _ = await self.probeFreshness() }
    }

    /// How long the stat may take before the probe gives up and answers
    /// Unknown. A dead network volume can block a stat indefinitely; the phone
    /// asking for status (Q-85) must never wait on it.
    nonisolated static let probeTimeout: TimeInterval = 3

    private struct ProbeResult: Sendable {
        let found: Bool
        let fingerprint: String?
    }

    /// Runs blocking `work` off the MainActor and gives up after `seconds`,
    /// answering nil. A task group cannot do this: it waits for every child
    /// before returning, and a blocked stat never sees cancellation. Here the
    /// work runs unstructured and whichever finishes first resumes the caller;
    /// a stuck stat keeps one detached thread, never the caller.
    nonisolated static func raceTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ work: @escaping @Sendable () -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            Task.detached(priority: .utility) { once.resume(work()) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(nil)
            }
        }
    }

    /// Resumes a continuation exactly once, from whichever racer gets there first.
    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
        func resume(_ value: T?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// The repo probe, awaited: resolves the root, stats the catalog and
    /// recomputes `freshness`, returning what it found. Callers that answer a
    /// phone must send THIS value, not the stored one: on a timeout or a path
    /// change mid-flight the stored state is left as it was and the answer is
    /// Unknown — never Current on a guess.
    func probeFreshness() async -> Freshness {
        let root = VibeCutPromptReader.defaultRoot()
        repoPath = root.path
        let timeout = Self.probeTimeout
        // Everything that can touch the disk, including building the reader's
        // URLs, happens inside the raced work, off the MainActor.
        let probed = await Self.raceTimeout(timeout) { () -> ProbeResult in
            let reader = VibeCutPromptReader(root: root)
            return ProbeResult(found: FileManager.default.fileExists(atPath: reader.promptsFileURL.path),
                               fingerprint: reader.sourceFingerprint())
        }
        guard let probed else {
            QuipLog.write(severity: .warn, subsystem: "vibecut",
                          message: "repo probe timed out after \(Int(timeout))s at \(root.path); freshness unknown",
                          to: LogPaths.webSocketPath)
            return .unknown
        }
        // The user may have changed the path while the stat was in flight.
        guard VibeCutPromptReader.defaultRoot().path == root.path else { return .unknown }
        repoFound = probed.found
        freshness = Self.freshness(
            syncedFingerprint: UserDefaults.standard.string(forKey: Self.syncedFingerprintKey),
            currentFingerprint: probed.fingerprint,
            hasSynced: lastOutcome.map { $0.error == nil } ?? false)
        return freshness
    }

    // MARK: Wire (Q-85)

    /// Pure: `Freshness` → its wire name. Static so tests never touch
    /// `UserDefaults.standard`.
    static func wire(_ freshness: Freshness) -> VibeCutFreshnessWire {
        switch freshness {
        case .unknown: return .unknown
        case .neverSynced: return .neverSynced
        case .current: return .current
        case .changed: return .changed
        }
    }

    /// Pure: the reply to a phone's `vibecut_status_request`. A failed last
    /// attempt carries its error and no count; never synced carries neither.
    static func statusMessage(freshness: Freshness, lastOutcome: Outcome?) -> VibeCutStatusMessage {
        VibeCutStatusMessage(
            freshness: wire(freshness),
            lastSyncAt: lastOutcome.map { $0.date.timeIntervalSince1970 },
            syncedCount: lastOutcome.flatMap { $0.error == nil ? $0.synced : nil },
            error: lastOutcome?.error)
    }

    /// The reply to a phone, built from the freshness the probe just
    /// answered (never the stored value, which a timed-out probe leaves stale).
    func statusMessage(freshness answered: Freshness) -> VibeCutStatusMessage {
        Self.statusMessage(freshness: answered, lastOutcome: lastOutcome)
    }

    /// Run one sync into `library` and record the outcome. Mirrors the original
    /// handler exactly: the file read happens off main; everything from the map
    /// on runs synchronously on the MainActor because `replaceVibeCutSet`'s
    /// one-broadcast guarantee depends on no `await` between its delete and its
    /// final rescan. A failed or empty read leaves the existing inherited set
    /// untouched.
    ///
    /// `trigger` names the entry point ("phone" / "settings-button") in the
    /// websocket.log line — every sync rewrites the whole inherited set on
    /// disk, so an unattributed one must be traceable to its caller.
    @discardableResult
    func sync(into library: PromptLibrary, trigger: String) async -> (outcome: Outcome, freshness: Freshness) {
        QuipLog.write(severity: .info, subsystem: "vibecut",
                      message: "sync started (trigger=\(trigger))",
                      to: LogPaths.webSocketPath)
        isSyncing = true
        defer { isSyncing = false }
        let outcome = await readMapAndReplace(into: library)
        // Awaited, not fired, and on EVERY path: the phone's ack carries
        // `freshness`, so it must be the post-sync answer. A failed sync used
        // to return before this and ack whatever the previous sync had left
        // (seen on hardware 2026-10-28: a refused v4 catalog acked "current").
        // After `record`, so `hasSynced` sees this outcome. The value goes
        // back to the caller so the ack carries what this probe answered.
        let answered = await probeFreshness()
        return (outcome, answered)
    }

    /// The read/map/replace pipeline behind `sync`. Every exit records its
    /// outcome; the caller probes freshness afterwards.
    private func readMapAndReplace(into library: PromptLibrary) async -> Outcome {
        let readResult: VibeCutPromptReader.ReadResult
        do {
            readResult = try await Task.detached(priority: .userInitiated) {
                try VibeCutPromptReader(root: VibeCutPromptReader.defaultRoot()).read()
            }.value
        } catch {
            let reason = (error as? VibeCutPromptReader.ReadError)?.description ?? "\(error)"
            return record(synced: 0, skipped: 0, skippedPacks: 0, error: reason)
        }

        let mapped = VibeCutPromptMapper.map(catalog: readResult.catalog, knownIDs: Self.loadIDMap())
        guard !mapped.entries.isEmpty else {
            return record(synced: 0, skipped: mapped.skipped,
                          skippedPacks: readResult.skippedPacks,
                          error: "No inheritable prompts found in VibeCut.")
        }

        let written: Int
        do {
            written = try library.replaceVibeCutSet(mapped.entries)
        } catch {
            return record(synced: 0, skipped: mapped.skipped,
                          skippedPacks: readResult.skippedPacks,
                          error: "VibeCut prompts were left unchanged: \(error.localizedDescription)")
        }
        // Only after the files are written: a failed sync must not record ids the phone never got.
        do { try Self.saveIDMap(mapped.idMap) } catch {
            QuipLog.write(severity: .error, subsystem: "vibecut",
                          message: "could not save vibecut-ids.json: \(error.localizedDescription)",
                          to: LogPaths.webSocketPath)
        }
        // What this sync read, so the probe below can answer Current / Changed.
        UserDefaults.standard.set(readResult.fingerprint, forKey: Self.syncedFingerprintKey)
        return record(synced: written, skipped: mapped.skipped,
                      skippedPacks: readResult.skippedPacks, error: nil)
    }

    private func record(synced: Int, skipped: Int, skippedPacks: Int, error: String?) -> Outcome {
        let outcome = Outcome(date: Date(), synced: synced, skipped: skipped,
                              skippedPacks: skippedPacks, error: error)
        lastOutcome = outcome
        if let data = try? JSONEncoder().encode(outcome) {
            UserDefaults.standard.set(data, forKey: Self.outcomeKey)
        }
        QuipLog.write(severity: error == nil ? .info : .error, subsystem: "vibecut",
                      message: "sync finished: \(synced) synced, \(skipped) skipped, "
                             + "\(skippedPacks) packs unreadable\(error.map { " — \($0)" } ?? "")",
                      to: LogPaths.webSocketPath)
        return outcome
    }
}
