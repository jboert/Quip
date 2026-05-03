import Foundation

/// One Quip backend the user has paired with this phone. Persisted as JSON in
/// `@AppStorage("pairedBackendsData")`. The `id` is the daemon's stable
/// device UUID delivered in `DeviceIdentityMessage` right after auth_ok —
/// keys per-backend state (Keychain PIN, paired-backend row, session slice)
/// against something that survives URL/hostname changes.
///
/// New entries can be added with a synthetic `id` of the form `"legacy-<uuid>"`
/// before the first auth round-trip; `BackendConnectionManager` rekeys the
/// entry once the real `device_identity` arrives.
struct PairedBackend: Codable, Identifiable, Hashable {
    var id: String
    var url: String
    var name: String
    var lastSeenLayoutMonitorName: String?
    var kind: BackendKind
    var lastUsed: Date
    var pinned: Bool
    /// Whether the app should keep a live WebSocket to this backend. Newly
    /// paired entries default to `true`; the user toggles old entries off so
    /// the manager doesn't fan out keepalives to every machine ever paired.
    /// Decoded with a `true` default so payloads written before this field
    /// existed don't kill the connection on first launch — a separate
    /// migration step in `BackendConnectionManager.loadPaired()` then prunes
    /// to "active only" once per install.
    var enabled: Bool

    init(id: String,
         url: String,
         name: String,
         lastSeenLayoutMonitorName: String? = nil,
         kind: BackendKind = .unknown,
         lastUsed: Date = Date(),
         pinned: Bool = false,
         enabled: Bool = true) {
        self.id = id
        self.url = url
        self.name = name
        self.lastSeenLayoutMonitorName = lastSeenLayoutMonitorName
        self.kind = kind
        self.lastUsed = lastUsed
        self.pinned = pinned
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, name, lastSeenLayoutMonitorName, kind, lastUsed, pinned, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.url = try c.decode(String.self, forKey: .url)
        self.name = try c.decode(String.self, forKey: .name)
        self.lastSeenLayoutMonitorName = try c.decodeIfPresent(String.self, forKey: .lastSeenLayoutMonitorName)
        self.kind = try c.decodeIfPresent(BackendKind.self, forKey: .kind) ?? .unknown
        self.lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed) ?? Date()
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

enum BackendKind: String, Codable, Hashable {
    case mac
    case linux
    case unknown
}
