import Foundation

/// Q-88 US-007: unsent text, kept per window, so switching windows (or
/// relaunching) never loses or cross-posts what was typed.
///
/// Drafts can hold secrets, so they live in their own file per Mac in
/// Application Support — complete file protection, excluded from backup —
/// and never in `UserDefaults`, `PreferencesSnapshot`, `phone.log` or
/// anything sent to the Mac.
struct DraftStore: Equatable {
    static let maxBytes = 4096
    static let maxDrafts = 50

    /// Least recently written first.
    private(set) var entries: [Entry] = []

    struct Entry: Codable, Equatable {
        let id: String
        let text: String
    }

    func text(for windowId: String) -> String {
        entries.first { $0.id == windowId }?.text ?? ""
    }

    /// Empty text removes the draft (a send, or a cleared field).
    mutating func set(_ text: String, for windowId: String) {
        entries.removeAll { $0.id == windowId }
        guard !text.isEmpty else { return }
        entries.append(Entry(id: windowId, text: Self.capped(text)))
        if entries.count > Self.maxDrafts { entries.removeFirst(entries.count - Self.maxDrafts) }
    }

    mutating func prune(keeping ids: Set<String>) {
        entries.removeAll { !ids.contains($0.id) }
    }

    /// At most `maxBytes` of UTF-8, cut between characters, never inside one.
    static func capped(_ text: String) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var out = ""
        var bytes = 0
        for ch in text {
            let n = ch.utf8.count
            guard bytes + n <= maxBytes else { break }
            out.append(ch)
            bytes += n
        }
        return out
    }
}

/// Where draft files live. Tests pass an in-memory pair.
struct DraftFiles {
    var read: (_ backendId: String) -> Data?
    var write: (_ data: Data, _ backendId: String) throws -> Void

    /// Unreadable while the phone is locked; replaced whole, never half written.
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    static func fileName(forBackendId backendId: String) -> String { "drafts.v1.\(backendId).json" }

    static func disk(directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory,
                                                                 in: .userDomainMask).first) -> DraftFiles {
        DraftFiles(
            read: { backendId in
                guard let directory else { return nil }
                return try? Data(contentsOf: directory.appendingPathComponent(fileName(forBackendId: backendId)))
            },
            write: { data, backendId in
                guard let directory else { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var url = directory.appendingPathComponent(fileName(forBackendId: backendId))
                try data.write(to: url, options: writeOptions)
                // An atomic write is a new file: mark every one.
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            })
    }
}

/// The drafts of every Mac, and which window the text field belongs to now.
@MainActor
final class DraftBook {
    private let files: DraftFiles
    private let log: (String) -> Void
    private var stores: [String: DraftStore] = [:]
    /// The Mac and window whose draft is in the text field.
    private(set) var owner: (backendId: String, windowId: String)?

    init(files: DraftFiles = .disk(), log: @escaping (String) -> Void = { PhoneLog.log($0) }) {
        self.files = files
        self.log = log
    }

    /// The field now belongs to `windowId` on `backendId`. Files `fieldText`
    /// under the old owner and returns the new owner's draft, or nil when the
    /// owner did not change (leave the field alone). `kept` names the ids
    /// whose drafts survive (the recency stack); others are dropped.
    func swap(fieldText: String, toBackend backendId: String, window windowId: String?,
              kept: (String) -> Set<String>) -> String? {
        let next = windowId.flatMap { backendId.isEmpty ? nil : (backendId, $0) }
        if owner?.backendId == next?.0, owner?.windowId == next?.1 { return nil }
        stash(fieldText, kept: kept)
        owner = next.map { (backendId: $0.0, windowId: $0.1) }
        guard let owner else { return "" }
        return store(owner.backendId).text(for: owner.windowId)
    }

    /// Files `fieldText` under the current owner and writes that Mac's file.
    func stash(_ fieldText: String, kept: (String) -> Set<String>) {
        guard let owner else { return }
        var drafts = store(owner.backendId)
        drafts.set(fieldText, for: owner.windowId)
        drafts.prune(keeping: kept(owner.backendId).union([owner.windowId]))
        guard drafts != stores[owner.backendId] else { return }
        stores[owner.backendId] = drafts
        do {
            try files.write(try JSONEncoder().encode(drafts.entries), owner.backendId)
        } catch {
            log("drafts write FAILED — unsent text not saved")
        }
    }

    private func store(_ backendId: String) -> DraftStore {
        if let loaded = stores[backendId] { return loaded }
        var store = DraftStore()
        if let data = files.read(backendId) {
            do {
                for entry in try JSONDecoder().decode([DraftStore.Entry].self, from: data) {
                    store.set(entry.text, for: entry.id)
                }
            } catch {
                log("drafts decode FAILED bytes=\(data.count) — unsent text dropped")
            }
        }
        stores[backendId] = store
        return store
    }
}
