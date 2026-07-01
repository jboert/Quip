import Foundation

/// Pure, view-model state backing the pending-share review UI (US-004).
///
/// Holds the parked `ContentShareDraft`, the reviewer's mode + target-window
/// choices, and the live connection flag, and derives everything the review
/// sheet renders (display strings, the composed prompt, and the Send-enabled
/// gate). It has no SwiftUI or app dependency so it can be unit-tested directly
/// and reused by Mac later; the sheet is a thin renderer over this type.
public struct ContentShareReviewState: Equatable, Sendable {
    public var draft: ContentShareDraft
    /// The mode whose prompt will be sent. Seeded from the deep link's `mode`.
    public var mode: ContentSharePromptMode
    /// The chosen target window id, or nil until the reviewer picks one.
    public var selectedWindowId: String?
    /// Human name of the selected window, shown in the review UI when available.
    public var selectedWindowName: String?
    /// Whether the active WebSocket client is currently connected.
    public var isConnected: Bool

    public init(
        draft: ContentShareDraft,
        mode: ContentSharePromptMode,
        selectedWindowId: String? = nil,
        selectedWindowName: String? = nil,
        isConnected: Bool = false
    ) {
        self.draft = draft
        self.mode = mode
        self.selectedWindowId = selectedWindowId
        self.selectedWindowName = selectedWindowName
        self.isConnected = isConnected
    }

    /// Title shown at the top of the review UI.
    public var title: String { draft.title }

    /// Summary shown under the source line, or nil when the draft has none.
    public var summary: String? { Self.nonEmpty(draft.summary) }

    /// The URL treated as the canonical source for display: the direct
    /// `sourceUrl` when present, otherwise the `shareUrl` fallback. The composed
    /// prompt still carries both — this is only the single line the review UI
    /// surfaces as "the final source URL".
    public var finalSourceURL: String? {
        Self.nonEmpty(draft.sourceUrl) ?? Self.nonEmpty(draft.shareUrl)
    }

    /// A short attribution label: explicit `sourceLabel`, else the producing
    /// `sourceApp`, else the host of the final source URL. nil when nothing is
    /// available to attribute.
    public var sourceLabel: String? {
        if let label = Self.nonEmpty(draft.sourceLabel) { return label }
        if let app = Self.nonEmpty(draft.sourceApp) { return app }
        if let url = finalSourceURL, let host = Self.host(of: url) { return host }
        return nil
    }

    /// The exact text that will be sent — the shared composer output for the
    /// current draft + mode. Deterministic for the same inputs.
    public var composedPrompt: String {
        ContentSharePromptComposer.compose(draft: draft, mode: mode)
    }

    /// The mode choices offered by the review UI.
    public static let availableModes: [ContentSharePromptMode] = ContentSharePromptMode.allCases

    /// Send is allowed only once a target window is selected AND the client is
    /// connected. Guards against injecting text with no destination or over a
    /// dead socket.
    public var canSend: Bool {
        selectedWindowId != nil && isConnected
    }

    // MARK: - Helpers

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Best-effort host extraction for attribution display. Returns nil when the
    /// string is not a parseable absolute URL with a host.
    private static func host(of urlString: String) -> String? {
        guard let host = URLComponents(string: urlString)?.host, !host.isEmpty else {
            return nil
        }
        return host
    }
}
