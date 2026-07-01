import Foundation

/// The classified destination of an incoming `quip://…` deep link.
///
/// Classification is pure (URL → route) so it can be unit-tested without the
/// SwiftUI app. The side effects (pairing, selecting a window, presenting the
/// pending-share review) stay in the app's `onOpenURL`; this type only decides
/// *which* branch a URL belongs to.
public enum QuipDeepLinkRoute: Equatable {
    /// `quip://pair?url=…&pin=…` — tap-to-pair (payload decoded by the app).
    case pair
    /// `quip://perms` — pop the Mac-permissions settings section.
    case perms
    /// `quip://window/<id>` or legacy `quip://<id>` — select that window.
    case window(String)
    /// `quip://share?title=…&url=…` — a reviewed content draft plus its
    /// requested mode (nil when the `mode` param is absent or unrecognized).
    case share(ContentShareDraft, ContentSharePromptMode?)
    /// Not a recognized / well-formed `quip://` link — the app ignores it.
    case none
}

/// Parses `quip://share` deep links (and classifies the other `quip://` routes)
/// into the shared content-intake schema.
///
/// Recognized `quip://share` query parameters:
/// - `title`        → `ContentShareDraft.title`
/// - `url`          → `ContentShareDraft.sourceUrl`
/// - `summary`      → `ContentShareDraft.summary`
/// - `source`       → `ContentShareDraft.sourceLabel`
/// - `shareUrl`     → `ContentShareDraft.shareUrl`
/// - `sourceApp`    → `ContentShareDraft.sourceApp`
/// - `sourceRecordId` → `ContentShareDraft.sourceRecordId`
/// - `mode`         → `ContentSharePromptMode` (nil if absent/unknown)
///
/// Values are percent-decoded by `URLComponents`, so `%20` (space), `%26` (&),
/// and percent-encoded UTF-8 (Unicode) round-trip in `title` and `summary`.
public enum ContentShareDeepLink {

    /// Classify any `quip://` URL. Non-`quip` schemes and unrecognized shapes
    /// return `.none`; the caller must handle file URLs before calling this.
    public static func route(for url: URL) -> QuipDeepLinkRoute {
        guard url.scheme == "quip" else { return .none }
        switch url.host {
        case "pair":
            return .pair
        case "perms":
            return .perms
        case "window":
            // quip://window/<id>
            let id = url.pathComponents.dropFirst().first ?? ""
            return id.isEmpty ? .none : .window(id)
        case "share":
            guard let parsed = parseShare(url) else { return .none }
            return .share(parsed.draft, parsed.mode)
        case let host?:
            // Legacy fallback: quip://<windowId> (no "window/" prefix).
            guard !host.isEmpty, url.pathComponents.count <= 1 else { return .none }
            return .window(host)
        case nil:
            return .none
        }
    }

    /// Parse a `quip://share` URL into a draft and optional mode.
    ///
    /// Returns `nil` for a malformed link — one carrying neither a non-empty
    /// `title` nor a non-empty `url`. When only `url` is present it becomes the
    /// draft title so source attribution is never lost.
    public static func parseShare(_ url: URL) -> (draft: ContentShareDraft, mode: ContentSharePromptMode?)? {
        guard url.scheme == "quip", url.host == "share" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // URLComponents percent-decodes each value. Collapse to a lookup,
        // treating empty strings as absent so `?title=` doesn't pass the guard.
        var params: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            if let value = item.value, !value.isEmpty {
                params[item.name] = value
            }
        }

        let titleParam = params["title"]
        let sourceUrl = params["url"]
        // Need at least one anchor; fall back to the URL as the title.
        guard let title = titleParam ?? sourceUrl else { return nil }

        let draft = ContentShareDraft(
            sourceApp: params["sourceApp"],
            sourceRecordId: params["sourceRecordId"],
            title: title,
            summary: params["summary"],
            sourceUrl: sourceUrl,
            sourceLabel: params["source"],
            shareUrl: params["shareUrl"]
        )
        let mode = params["mode"].flatMap(ContentSharePromptMode.init(rawValue:))
        return (draft, mode)
    }
}
