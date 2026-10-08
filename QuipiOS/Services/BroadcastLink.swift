import Foundation

/// `quip://broadcast` links (PRD broadcast-and-search, US-114), so a Shortcut
/// or another app can open the Broadcast sheet filled in:
/// `quip://broadcast?text=<percent-encoded>` for a draft, or
/// `quip://broadcast?prompt=<id>` for a library prompt. A link only opens the
/// sheet; nothing is sent until the user taps Send.
///
/// The app asks this parser before `ContentShareDeepLink`, which would read
/// `broadcast` as a legacy window id.
enum BroadcastLink {
    struct Request: Equatable, Sendable {
        /// The draft, exactly as decoded. Nil when absent or blank, and
        /// whenever `promptID` is set.
        var text: String?
        /// A library prompt to preload, marked as from that prompt so each
        /// window gets its own placeholder values (US-107).
        var promptID: String?
    }

    /// The request in `url`, or nil when it is not a `quip://broadcast` link.
    /// `prompt` wins over `text`. A blank value counts as absent, so the first
    /// non-blank value of each name is used; other names are ignored. A link
    /// with neither opens an empty sheet.
    static func parse(_ url: URL) -> Request? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "quip",
              components.host?.lowercased() == "broadcast",
              components.path.isEmpty || components.path == "/" else { return nil }
        // URLComponents has already percent-decoded each value.
        func value(_ name: String) -> String? {
            components.queryItems?.lazy
                .filter { $0.name == name }
                .compactMap(\.value)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let promptID = value("prompt") {
            return Request(text: nil, promptID: promptID)
        }
        return Request(text: value("text"), promptID: nil)
    }
}
