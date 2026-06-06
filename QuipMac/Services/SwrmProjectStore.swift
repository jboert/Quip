// SwrmProjectStore.swift
// QuipMac — owns the user-configured set of swrm project roots and the
// one-SwrmEventTailer-per-root lifecycle.
//
// Persistence mirrors PushNotificationService: a single UserDefaults key
// holding a JSON-encoded array, loaded in init and re-encoded on every
// mutation. The `@Observable` macro drives the Settings tab re-render.
//
// Story split: US-002 owns the *live* add/remove (each starts/stops its
// tailer immediately, no app restart). App-launch start of all persisted
// roots is US-008's job — `startAll()`/`stopAll()` exist here for that
// wiring but are NOT called at init.

import Foundation

@MainActor
@Observable
final class SwrmProjectStore {

    /// Absolute filesystem paths of every configured swrm project root.
    /// Ordered by insertion (stable for a predictable Settings list).
    private(set) var roots: [String] = []

    /// Live tailers keyed by root path. At most one per configured root;
    /// created on `add`/`startAll`, torn down on `remove`/`stopAll`.
    private var tailers: [String: SwrmEventTailer] = [:]

    /// Installed on every tailer's `onEvents`. The coordinator (US-004/US-008)
    /// sets this once; the store forwards each tailer's deliveries along with
    /// the tailer that produced them (so consumers know the project root).
    /// Setting it (re)wires every currently-running tailer.
    var onTailerEvents: (@MainActor (SwrmEventTailer, [SwrmEvent]) -> Void)? {
        didSet { for tailer in tailers.values { wire(tailer) } }
    }

    private static let storageKey = "swrmProjectRoots"

    init() {
        load()
    }

    // MARK: persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        roots = decoded
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(roots)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            SwrmEventTailer.globalLog("SwrmProjectStore PERSIST FAILED: \(error.localizedDescription) (\(roots.count) roots not saved)")
        }
    }

    // MARK: validation

    /// Why an add was rejected. Surfaced inline in the Settings tab.
    enum AddError: LocalizedError {
        case notADirectory
        case duplicate

        var errorDescription: String? {
            switch self {
            case .notADirectory: return "That path isn't an existing folder."
            case .duplicate:     return "That folder is already configured."
            }
        }
    }

    /// A path is acceptable when it is an existing directory (it already
    /// contains, or can contain, a `.swrm/` subdir — any directory can gain
    /// one) and isn't already configured.
    func validate(path: String) -> AddError? {
        let normalized = Self.normalize(path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir)
        guard exists && isDir.boolValue else { return .notADirectory }
        if roots.contains(normalized) { return .duplicate }
        return nil
    }

    // MARK: mutation (live)

    /// Add a root and start its tailer immediately. Returns `nil` on success
    /// or the rejection reason for inline display.
    @discardableResult
    func add(path: String) -> AddError? {
        if let error = validate(path: path) { return error }
        let normalized = Self.normalize(path)
        roots.append(normalized)
        persist()
        startTailer(for: normalized)
        return nil
    }

    /// Remove a root and stop its tailer immediately.
    func remove(path: String) {
        let normalized = Self.normalize(path)
        roots.removeAll { $0 == normalized }
        persist()
        stopTailer(for: normalized)
    }

    // MARK: tailer lifecycle

    /// Start tailers for every persisted root (US-008 app-launch wiring).
    /// Idempotent — skips roots that already have a running tailer.
    func startAll() {
        for root in roots { startTailer(for: root) }
    }

    /// Stop and release every tailer (US-008 quit/background wiring).
    func stopAll() {
        for path in Array(tailers.keys) { stopTailer(for: path) }
    }

    private func startTailer(for path: String) {
        guard tailers[path] == nil else { return }
        let tailer = SwrmEventTailer(projectRoot: URL(fileURLWithPath: path))
        wire(tailer)
        tailers[path] = tailer
        tailer.start()
    }

    private func stopTailer(for path: String) {
        guard let tailer = tailers.removeValue(forKey: path) else { return }
        tailer.stop()
    }

    private func wire(_ tailer: SwrmEventTailer) {
        tailer.onEvents = { [weak self, weak tailer] events in
            guard let self, let tailer else { return }
            self.onTailerEvents?(tailer, events)
        }
    }

    /// Standardize a path so duplicate detection and dictionary keys are
    /// stable (resolves `~`, trailing slashes, `.`/`..`).
    private static func normalize(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
            .precomposedStringWithCanonicalMapping
            .standardizedPath
    }
}

private extension String {
    var standardizedPath: String {
        (self as NSString).standardizingPath
    }
}
