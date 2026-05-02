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

    init(id: String,
         url: String,
         name: String,
         lastSeenLayoutMonitorName: String? = nil,
         kind: BackendKind = .unknown,
         lastUsed: Date = Date(),
         pinned: Bool = false) {
        self.id = id
        self.url = url
        self.name = name
        self.lastSeenLayoutMonitorName = lastSeenLayoutMonitorName
        self.kind = kind
        self.lastUsed = lastUsed
        self.pinned = pinned
    }
}

enum BackendKind: String, Codable, Hashable {
    case mac
    case linux
    case unknown
}
