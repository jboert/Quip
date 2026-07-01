import Foundation

/// A single sourced claim inside a content share draft.
///
/// `status` and `sourceUrl` are stored as plain strings (not enums) so that
/// non-Swift producers such as nugget-expo or FintechAdventures can populate
/// them with values Quip does not yet know about without breaking decode.
public struct ContentClaim: Codable, Sendable, Equatable {
    public var text: String
    public var sourceUrl: String?
    public var status: String?
    public var note: String?

    public init(text: String, sourceUrl: String? = nil, status: String? = nil, note: String? = nil) {
        self.text = text
        self.sourceUrl = sourceUrl
        self.status = status
        self.note = note
    }

    // Explicit keys lock the deterministic JSON field names for external consumers.
    private enum CodingKeys: String, CodingKey {
        case text
        case sourceUrl
        case status
        case note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// A stable, cross-app content-intake schema. iOS, Mac, and future integrations
/// (nugget-expo, FintechAdventures) exchange sourced news / context through this
/// type instead of ad-hoc stringly-typed payloads.
///
/// Decoding is tolerant: a minimal `{"title": …, "sourceUrl": …}` payload decodes
/// by defaulting the optional arrays to empty and the optional strings to nil, and
/// unknown extra fields are ignored. Only `title` is required. `schemaVersion`
/// defaults to `currentSchemaVersion` when absent.
///
/// The JSON field names are deterministic (locked by explicit `CodingKeys`) so a
/// non-Swift app can rely on them. Timestamps are stored as strings supplied by the
/// caller (ISO 8601 by convention) — the type has no current-date dependency.
public struct ContentShareDraft: Codable, Sendable, Equatable {
    /// The schema version a producer wrote against. Absent payloads default to this.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sourceApp: String?
    public var sourceRecordId: String?
    public var title: String
    public var summary: String?
    public var sourceUrl: String?
    public var sourceLabel: String?
    public var shareUrl: String?
    public var publishedAt: String?
    public var entities: [String]
    public var claims: [ContentClaim]
    public var suggestedUses: [String]
    public var createdAt: String?

    public init(
        schemaVersion: Int = ContentShareDraft.currentSchemaVersion,
        sourceApp: String? = nil,
        sourceRecordId: String? = nil,
        title: String,
        summary: String? = nil,
        sourceUrl: String? = nil,
        sourceLabel: String? = nil,
        shareUrl: String? = nil,
        publishedAt: String? = nil,
        entities: [String] = [],
        claims: [ContentClaim] = [],
        suggestedUses: [String] = [],
        createdAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sourceApp = sourceApp
        self.sourceRecordId = sourceRecordId
        self.title = title
        self.summary = summary
        self.sourceUrl = sourceUrl
        self.sourceLabel = sourceLabel
        self.shareUrl = shareUrl
        self.publishedAt = publishedAt
        self.entities = entities
        self.claims = claims
        self.suggestedUses = suggestedUses
        self.createdAt = createdAt
    }

    // Explicit keys lock the deterministic JSON field names for external consumers.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceApp
        case sourceRecordId
        case title
        case summary
        case sourceUrl
        case sourceLabel
        case shareUrl
        case publishedAt
        case entities
        case claims
        case suggestedUses
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? ContentShareDraft.currentSchemaVersion
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        sourceRecordId = try c.decodeIfPresent(String.self, forKey: .sourceRecordId)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel)
        shareUrl = try c.decodeIfPresent(String.self, forKey: .shareUrl)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        entities = try c.decodeIfPresent([String].self, forKey: .entities) ?? []
        claims = try c.decodeIfPresent([ContentClaim].self, forKey: .claims) ?? []
        suggestedUses = try c.decodeIfPresent([String].self, forKey: .suggestedUses) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}
