import Foundation

/// Send-side logic for a reviewed content share (US-005).
///
/// Builds the exact `SendTextMessage` the existing text path expects — the
/// prompt text is the shared composer's output, byte-for-byte — and maintains
/// the small recent-shares MRU list used for quick resend / debugging.
///
/// Pure Foundation, no UI or transport dependencies: the message construction
/// and MRU transformation are deterministic and unit-testable; the only side
/// effects live in the thin `UserDefaults` load/record helpers.
public enum ContentShareSend {

    /// Maximum number of drafts kept in the recent-shares MRU.
    public static let recentSharesCap = 20

    /// `UserDefaults` key holding the JSON-encoded `[ContentShareDraft]` MRU.
    public static let recentSharesDefaultsKey = "recentContentShares"

    // MARK: - Message construction

    /// The `SendTextMessage` for a reviewed share: same wire path as a typed
    /// or custom-button prompt (`send_text`, pressReturn, fresh `messageId`
    /// from the message's own initializer), with the text being exactly
    /// `ContentSharePromptComposer.compose(draft:mode:)`.
    static func message(
        for draft: ContentShareDraft,
        mode: ContentSharePromptMode,
        windowId: String
    ) -> SendTextMessage {
        SendTextMessage(
            windowId: windowId,
            text: ContentSharePromptComposer.compose(draft: draft, mode: mode),
            pressReturn: true
        )
    }

    // MARK: - Recent-shares MRU

    /// Pure MRU update: `draft` moves to the front (deduplicating an equal
    /// existing entry), the rest keep their order, and the list is capped at
    /// `recentSharesCap` by dropping the oldest entries.
    public static func recording(
        _ draft: ContentShareDraft,
        into recents: [ContentShareDraft]
    ) -> [ContentShareDraft] {
        var updated = recents.filter { $0 != draft }
        updated.insert(draft, at: 0)
        if updated.count > recentSharesCap {
            updated.removeLast(updated.count - recentSharesCap)
        }
        return updated
    }

    /// Load the persisted MRU. Missing or undecodable data yields an empty
    /// list — the MRU is a debugging convenience, never a hard dependency.
    public static func loadRecents(from defaults: UserDefaults = .standard) -> [ContentShareDraft] {
        guard let data = defaults.data(forKey: recentSharesDefaultsKey),
              let recents = try? JSONDecoder().decode([ContentShareDraft].self, from: data)
        else { return [] }
        return recents
    }

    /// Record a successfully sent draft into the persisted MRU.
    public static func recordRecent(
        _ draft: ContentShareDraft,
        in defaults: UserDefaults = .standard
    ) {
        let updated = recording(draft, into: loadRecents(from: defaults))
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: recentSharesDefaultsKey)
        }
    }
}
