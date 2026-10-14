import SwiftUI
import AVFoundation

/// Small yellow dot that pulses to draw attention to a window card.
/// Used on the window picker when Claude is waiting for input — subtle
/// foreground-state signal since the PRD calls for no banner here.
struct AttentionPulseDot: View {
    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.yellow.opacity(0.5))
                .scaleEffect(scale)
            Circle()
                .fill(Color.yellow)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                scale = 1.8
            }
        }
    }
}

/// `UITextView`-backed terminal text view. SwiftUI `Text` with `.link`
/// AttributedString is documented to be tappable but in practice tap routing
/// drops to the floor inside our InlineTerminalContent layout (parent
/// ScrollView gestures + view-modifier cascades both interfere). UITextView
/// owns its own gesture stack and tap-to-open-url is rock solid.
///
/// The view uses `dataDetectorTypes = .link` plus `linkTextAttributes` for
/// styling, and gets the SAME scheme filter as `linkifiedTerminalContent` via
/// a delegate `shouldInteractWith url:` hook that rejects taps on non-http(s)
/// matches (so README.md / Quip.app render as links visually but ignore the
/// tap; that's a minor cosmetic loss vs. the alternative of building the
/// attributed string by hand).
struct LinkableTerminalText: UIViewRepresentable {
    let content: String
    /// The phone's own font size (GH #38); never affects the Mac terminal.
    var fontSize: Double = TerminalTextSize.standard
    /// Receives the new size when a pinch ends.
    var onFontSizeChange: ((Double) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true            // owns scrolling
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = .link
        tv.linkTextAttributes = [
            .foregroundColor: UIColor.cyan,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        tv.delegate = context.coordinator
        tv.alwaysBounceVertical = true
        // Pinch previews with a transform and commits the size on release, so
        // a 2,000-line re-layout happens once per pinch, not once per frame.
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        tv.addGestureRecognizer(pinch)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.fontSize = fontSize
        coordinator.onFontSizeChange = onFontSizeChange
        // Same text at the same size: leave the view alone so a refresh never
        // moves the reader.
        let sizeChanged = coordinator.renderedFontSize != fontSize
        guard tv.attributedText.string != content || sizeChanged else { return }
        coordinator.renderedFontSize = fontSize
        // Follow new output only if the reader was already at the bottom
        // (`TerminalScrollPolicy`, same rule as the screenshot view). Scrolled
        // up reading history, they stay where they are.
        let pinned = TerminalScrollPolicy.isPinnedToBottom(
            contentHeight: tv.contentSize.height,
            offsetY: tv.contentOffset.y,
            visibleHeight: tv.bounds.height - tv.adjustedContentInset.bottom)
        let savedOffset = tv.contentOffset
        // A size change keeps the reader at the same place in the text, not
        // the same pixel offset (which would land elsewhere at a new size).
        let savedFraction = tv.contentSize.height > 0 ? tv.contentOffset.y / tv.contentSize.height : 0
        let attr = NSMutableAttributedString(string: content, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85),
        ])
        tv.attributedText = attr
        if pinned {
            let bottom = NSRange(location: max(0, attr.length - 1), length: 1)
            tv.scrollRangeToVisible(bottom)
        } else {
            tv.layoutIfNeeded()
            let maxY = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
            let y = sizeChanged ? savedFraction * tv.contentSize.height : savedOffset.y
            tv.setContentOffset(CGPoint(x: savedOffset.x, y: min(max(0, y), maxY)), animated: false)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var fontSize: Double = TerminalTextSize.standard
        var renderedFontSize: Double?
        var onFontSizeChange: ((Double) -> Void)?

        @objc func handlePinch(_ pinch: UIPinchGestureRecognizer) {
            guard let tv = pinch.view else { return }
            switch pinch.state {
            case .changed:
                let preview = TerminalTextSize.pinched(fontSize, scale: pinch.scale) / fontSize
                tv.transform = CGAffineTransform(scaleX: preview, y: preview)
            case .ended:
                tv.transform = .identity
                onFontSizeChange?(TerminalTextSize.pinched(fontSize, scale: pinch.scale))
            default:
                tv.transform = .identity
            }
        }

        /// iOS 17+ tap handler. The OLD `shouldInteractWith url:in:interaction:`
        /// delegate method is deprecated; iOS 17 routes taps through this method
        /// instead and falls through to a no-op if it returns nil. Returning
        /// the system's default openURL action — wrapped in a fresh UIAction
        /// to FORCE immediate execution rather than the iOS 17 default of
        /// showing a Safari-style preview menu first.
        ///
        /// Scheme filter: `dataDetectorTypes = .link` matches bare TLDs
        /// (`README.md` → `http://README.md`, `Quip.app` → `http://Quip.app`).
        /// We reject those by inspecting the original substring's prefix.
        @available(iOS 17.0, *)
        func textView(_ textView: UITextView,
                      primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            let scheme = url.scheme?.lowercased() ?? ""
            let allowed: Bool
            if scheme == "mailto" {
                allowed = true
            } else if scheme == "http" || scheme == "https" {
                let raw = (textView.attributedText.string as NSString).substring(with: textItem.range)
                allowed = raw.hasPrefix("http://") || raw.hasPrefix("https://")
            } else {
                allowed = false
            }
            guard allowed else { return nil }
            // Return a custom UIAction that calls UIApplication.shared.open
            // directly. iOS 17's defaultAction sometimes resolves to "show
            // preview popover" instead of "open immediately"; this guarantees
            // immediate openURL on tap.
            return UIAction(title: "Open Link") { _ in
                UIApplication.shared.open(url, options: [:]) { success in
                    if !success {
                        NSLog("[LinkableTerminalText] open(%@) returned false", url.absoluteString)
                    }
                }
            }
        }

        /// Suppress the iOS 17 link preview menu so tap → open immediately
        /// without an intermediate "show URL preview" popover.
        @available(iOS 17.0, *)
        func textView(_ textView: UITextView,
                      menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            return nil
        }

        /// Pre-iOS 17 fallback (unreachable on this app — deployment target is
        /// iOS 17.0 — but kept defensively in case the project bumps backward).
        func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                      in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            let scheme = URL.scheme?.lowercased() ?? ""
            if scheme == "mailto" { return true }
            if scheme == "http" || scheme == "https" {
                let raw = (textView.attributedText.string as NSString).substring(with: characterRange)
                return raw.hasPrefix("http://") || raw.hasPrefix("https://")
            }
            return false
        }
    }
}

/// Wrap http(s) URLs in the terminal content with `.link` attributes so SwiftUI's
/// `Text` renders them as tappable. Only matches with an explicit `http://` or
/// `https://` prefix are linkified — `NSDataDetector` happily matches bare TLDs,
/// which would turn `README.md` (`.md` is a real TLD) and `Quip.app` into links.
///
/// Kept around for unit-test reuse + as documentation of the scheme-filter rule;
/// the actual render path now goes through `LinkableTerminalText` (UITextView).
func linkifiedTerminalContent(_ raw: String) -> AttributedString {
    var attr = AttributedString(raw)

    // Bake the default white foreground into the attributed string itself so
    // the call site doesn't need a `.foregroundStyle` modifier on the Text.
    // The modifier interferes with link-tap recognition by making SwiftUI
    // recompute foreground per-character at render time and stomping on the
    // link attribute's tap-routing. Setting it on the attributed string
    // leaves the per-run link runs intact and tappable.
    attr.foregroundColor = .white.opacity(0.85)

    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
        return attr
    }
    let ns = raw as NSString
    detector.enumerateMatches(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
        guard let match, let url = match.url,
              let range = Range(match.range, in: attr) else { return }
        let matched = ns.substring(with: match.range)
        // Allow http(s) explicitly + mailto: for emails (NSDataDetector returns
        // bare addresses as `mailto:foo@bar.com` URLs natively, so this filter
        // accepts both `mailto:hi@example.com` substring matches and bare
        // `noreply@anthropic.com` matches surfaced by the detector).
        guard matched.hasPrefix("http://") || matched.hasPrefix("https://")
              || matched.hasPrefix("mailto:") || url.scheme?.lowercased() == "mailto"
        else { return }
        attr[range].link = url
        attr[range].underlineStyle = .single
        // Brighter foreground for link runs so they stand out from the .85
        // white body text — visually distinguishes "this is tappable".
        attr[range].foregroundColor = .cyan
    }
    return attr
}

/// User preference for how window content renders. `.auto` keeps the
/// historic image > text > loading priority; `.image` and `.text` are
/// hard overrides that stop the panel flickering between modes when the
/// Mac's screenshot stream is unstable.
enum ContentRenderMode: String, CaseIterable, Identifiable {
    case auto, image, text
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .image: return "Image"
        case .text: return "Text"
        }
    }
}

/// §18.2 — Multi-select answer bar for Claude's `[ ]` checkbox menus. Each chip
/// toggles a pick locally (no keystroke sent), and Submit fires ONE action
/// `select_multi:<n,n,…>` with the prompt fingerprint. Sending all picks at once
/// is what fixes the old per-tap drop: the terminal screen doesn't mutate until
/// submit, so the Mac's single fingerprint re-validation still matches.
private struct MultiSelectAnswerBar: View {
    let options: [Int]
    let fingerprint: String?
    /// Live terminal content — seeds `picks` from the boxes Claude pre-checked.
    let content: String
    /// (action, fingerprint) — action is `select_multi:1,3`.
    let onSubmit: (String, String?) -> Void
    @State private var picks: Set<Int> = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { n in
                    let on = picks.contains(n)
                    Button {
                        if on { picks.remove(n) } else { picks.insert(n) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: on ? "checkmark.square.fill" : "square")
                            Text("\(n)")
                        }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(on ? Color.accentColor : Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Option \(n)")
                    .accessibilityValue(on ? "Selected" : "Not selected")
                    .accessibilityAddTraits(.isButton)
                }

                Button {
                    let chosen = options.filter { picks.contains($0) }
                    guard !chosen.isEmpty else { return }
                    onSubmit("select_multi:" + chosen.map(String.init).joined(separator: ","), fingerprint)
                    picks = []
                } label: {
                    Text(picks.isEmpty ? "Submit" : "Submit \(picks.count)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(picks.isEmpty ? Color.white.opacity(0.4) : Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(picks.isEmpty ? Color.white.opacity(0.08) : Color.green.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(picks.isEmpty)
                .accessibilityLabel("Submit selected options")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
        // Seed from the boxes Claude pre-checked so the bar shows (and can edit)
        // the real starting selection. Submit then represents the desired FINAL
        // set the US-004 Mac diff consumes.
        .onAppear { picks = MultiSelectSync.initialPicks(liveContent: content) }
        // Re-seed from the NEW prompt's checked set when the fingerprint changes
        // out from under us — a fresh pre-checked prompt shows its pre-checked
        // boxes rather than clearing to empty.
        .onChange(of: fingerprint) { _, _ in picks = MultiSelectSync.initialPicks(liveContent: content) }
    }
}

/// §18.3 — Answer bar for a single-line INLINE bracketed prompt
/// (`Approve which to delete? [all / 1 / 2 / 3 / none / pick]`). Single-select:
/// one tap = one answer. A digit token reuses the proven `select_N` path; a word
/// token (`all`/`none`/`pick`/…) sends `answer_text:<word>`. Both carry the
/// prompt fingerprint so the Mac re-validates the token is still offered before
/// typing it + Return.
private struct InlineAnswerBar: View {
    let tokens: [String]
    let fingerprint: String?
    /// (action, fingerprint) — action is `select_2` or `answer_text:all`.
    let onSubmit: (String, String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tokens, id: \.self) { tok in
                    Button {
                        let action = tok.allSatisfy(\.isNumber) ? "select_\(tok)" : "answer_text:\(tok)"
                        onSubmit(action, fingerprint)
                    } label: {
                        Text(tok)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                            .background(Color.accentColor.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Answer \(tok)")
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

struct InlineTerminalContent: View {
    let content: String
    let screenshot: String?
    /// URLs extracted Mac-side for the tap-to-open tray. Empty → tray hides.
    /// Screenshot mode (the typical case) renders URLs as pixels with no tap
    /// routing, so this tray is how they become interactive.
    let urls: [String]
    /// The inline autosuggestion (ghost text) the Mac read off this window's
    /// input line, or nil when none is showing. Gates the accept-autocomplete
    /// button (US-003); defaults nil so callers without live state (QA pair
    /// layout, previews) keep compiling and the button stays inert.
    var autosuggest: TerminalAutosuggest? = nil
    private var hasAutosuggest: Bool { autosuggest != nil }
    let windowName: String
    let windowColor: Color
    /// Keys the loading timer, so switching windows restarts it. Falls back to
    /// the name for callers that have no id.
    var windowId: String? = nil
    /// When the Mac last answered for this window. Drives the "N s old" chip
    /// and the slow-loading text (`TerminalPanelFreshness`); nil hides both.
    var lastUpdate: Date? = nil
    @Binding var isExpanded: Bool
    var onRefresh: () -> Void
    /// (action, promptFingerprint?) — fingerprint is non-nil only for one-tap
    /// answers when the Labs flag is on, so the Mac re-validates. (§3.2)
    var onSendAction: (String, String?) -> Void

    /// Single testable seam for the native row above the terminal pixels. The
    /// row and the header button must keep using the legacy `press_right` wire
    /// action; the Mac re-scrapes and chooses Tab or Right-arrow at inject time.
    static func acceptAutosuggest(using send: (String, String?) -> Void) {
        send("press_right", nil)
    }
    @AppStorage(LabsFlags.oneTapAnswer) private var labsOneTapAnswer = false
    /// Swipe handler — `direction` is +1 (swipe left = next window) or -1
    /// (swipe right = previous window), matching `MainiOSView.cycleWindow`.
    /// Optional for previews / non-swiping callers.
    var onCycleWindow: ((Int) -> Void)? = nil
    @Environment(\.quipColors) private var colors
    @AppStorage("tintContentBorder") private var tintContentBorder = true
    /// Toggle for the tap-to-open URL tray. Default on. Users who don't want
    /// the extra row between header and screenshot can hide it from Settings.
    @AppStorage("urlTrayEnabled") private var urlTrayEnabled = true
    /// How many of the most recent URLs to show. Mac sends everything it
    /// finds in the 200-line scrape window; iOS caps here so a `tail -f`
    /// log doesn't produce a pill strip that scrolls for days.
    @AppStorage("urlTrayLimit") private var urlTrayLimit = 10
    /// The phone's own terminal font size (GH #38). Never sent to the Mac.
    /// Persisted, and shared between portrait and landscape.
    @AppStorage("terminalTextSize") private var terminalTextSize = TerminalTextSize.standard
    /// Screenshot pinch zoom, 1× = fit to width. Not persisted: a new
    /// session starts fitted.
    @State private var screenshotZoom: CGFloat = 1
    @State private var screenshotZoomAtPinchStart: CGFloat = 1
    /// `auto` (default) preserves the image > text > loading priority and
    /// last-good-screenshot caching. `image` and `text` are hard overrides
    /// that lock the renderer to one branch — useful when the Mac screenshot
    /// stream is intermittently empty and the auto path keeps bouncing
    /// between image and text. Stored as the enum's rawValue.
    @AppStorage("contentRenderMode") private var contentRenderModeRaw: String = ContentRenderMode.auto.rawValue
    private var contentRenderMode: ContentRenderMode {
        ContentRenderMode(rawValue: contentRenderModeRaw) ?? .auto
    }
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    /// The clock the freshness chip and the slow-loading text read. Advanced
    /// by `refreshTimer` only while one of them could change, so a live
    /// panel is not re-rendered for nothing.
    @State private var now = Date()
    /// When the panel last entered the loading branch for this window.
    @State private var loadingSince: Date?
    private var loadingKey: String { "\(windowId ?? windowName)|\(currentBranch == .loading)" }

    /// Live horizontal offset applied to the content panel while a
    /// window-cycle swipe is in progress. Dampened to 30% of the finger
    /// travel + capped at ±80pt so the card feels physical without
    /// yanking off-screen. Snaps back to 0 on gesture end if the threshold
    /// isn't hit. Zero when idle.
    @State private var swipeOffset: CGFloat = 0

    /// True when the screenshot ScrollView is at-or-near the bottom — gates
    /// the auto-scroll-to-bottom that fires on every screenshot refresh.
    /// Default true so the very first screenshot lands at the live tail
    /// (matches the pre-§36 behavior for users who don't manually scroll).
    @State private var isPinnedToBottom = true

    /// 0…1 normalized swipe magnitude, derived from swipeOffset. Used to
    /// drive the lift-off shadow and the scale-down so the card reads as
    /// "coming off the top of the deck" rather than just a flat slide.
    private var swipeProgress: CGFloat {
        min(1, abs(swipeOffset) / 80)
    }

    /// Which of the three render branches is active. Pinned by
    /// `InlineTerminalContentBranchTests` so future refactors don't silently
    /// flip the priority again.
    enum RenderBranch { case image, text, loading }

    /// Priority for `.auto`: image > text > loading. Image is the normal
    /// state and the one the state layer works hard to preserve (last-good
    /// screenshot caching so network blips don't kick us out). Text is the
    /// acceptable fallback when no screenshot has ever been received — user's
    /// stated preference is "plain text beats an empty Loading screen."
    /// Loading is the truly-no-content state (first connect, window switches).
    ///
    /// `.image` mode locks to the screenshot branch — if the screenshot is
    /// missing or undecodable, fall through to `.loading` rather than `.text`,
    /// so the panel never silently revert to text mid-session.
    /// `.text` mode locks to the text branch the same way.
    ///
    /// The URL tray above the content still renders regardless of branch,
    /// so tappable URLs remain available even while waiting for a screenshot.
    static func branch(content: String, screenshot: String?, mode: ContentRenderMode = .auto) -> RenderBranch {
        let imageReady: Bool = {
            guard let screenshot, let data = Data(base64Encoded: screenshot),
                  UIImage(data: data) != nil else { return false }
            return true
        }()
        switch mode {
        case .image:
            return imageReady ? .image : .loading
        case .text:
            return content.isEmpty ? .loading : .text
        case .auto:
            if imageReady { return .image }
            if !content.isEmpty { return .text }
            return .loading
        }
    }

    private var currentBranch: RenderBranch {
        Self.branch(content: content, screenshot: screenshot, mode: contentRenderMode)
    }

    /// Copy shown in the loading branch — distinguishes "auto / first
    /// connect" from "you forced image/text and the corresponding payload
    /// hasn't arrived yet" so the user knows it's waiting on data, not a
    /// crashed renderer.
    private var loadingPlaceholder: String {
        switch contentRenderMode {
        case .image: return "Waiting for screenshot…"
        case .text:  return "Waiting for terminal text…"
        case .auto:  return "Loading…"
        }
    }

    private func syncLoadingSince() {
        let date = Date()
        loadingSince = currentBranch == .loading ? date : nil
        now = date
    }

    private func tick(_ date: Date) {
        let mayBeStale = lastUpdate.map { date.timeIntervalSince($0) >= TerminalPanelFreshness.staleAfter - 2 } ?? false
        if loadingSince != nil || mayBeStale { now = date }
    }

    /// Tiny pill in the header showing which render branch is live.
    /// Horizontal scroll of tap-to-open URL pills. Renders above the
    /// terminal content, below the window-name header. Hidden entirely when
    /// `urls` is empty so zero-URL scrapes (the common case) don't burn
    /// vertical real estate. Each pill: tap → `UIApplication.shared.open`.
    @ViewBuilder
    private var urlTray: some View {
        // Keep the most recent N URLs — `TerminalURLExtractor` preserves
        // document order so suffix() == newest. Hide entirely when empty
        // or when the user has the tray turned off in Settings.
        let visible = Array(urls.suffix(max(1, urlTrayLimit)))
        if urlTrayEnabled && !visible.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(visible, id: \.self) { url in
                        Button {
                            if let u = URL(string: url) {
                                UIApplication.shared.open(u)
                            }
                        } label: {
                            Text(urlTrayLabel(for: url))
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(Color.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.15))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(Color.cyan.opacity(0.35), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .background(Color.white.opacity(0.03))
        }
    }

    /// Pill label — drop the scheme prefix for http(s)/mailto because it's
    /// visual noise that wastes pill width on a phone. The tap handler uses
    /// the full URL string so functionality is unchanged.
    private func urlTrayLabel(for url: String) -> String {
        if url.hasPrefix("https://") { return String(url.dropFirst("https://".count)) }
        if url.hasPrefix("http://")  { return String(url.dropFirst("http://".count)) }
        if url.hasPrefix("mailto:")  { return String(url.dropFirst("mailto:".count)) }
        return url
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(windowColor)
                    .frame(width: 8, height: 8)
                Text(windowName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                    // One line, so the stale chip truncates the name rather
                    // than wrapping it and growing the header.
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Q-62: frozen text looked live. The chip rides the header row
                // (no new row) and a tap asks again.
                if currentBranch != .loading,
                   let stale = TerminalPanelFreshness.staleLabel(lastUpdate: lastUpdate, now: now) {
                    Button { onRefresh() } label: {
                        Text(stale)
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel(TerminalPanelFreshness.spokenStaleLabel(lastUpdate: lastUpdate, now: now) ?? stale)
                    .accessibilityHint("Asks the Mac again")
                }
                Spacer()
                // Phone-only text size (GH #38): changes how the phone draws
                // the text, never the Mac terminal's font. Pinching the text
                // does the same. Hold either button to reset.
                Button {
                    terminalTextSize = TerminalTextSize.stepped(terminalTextSize, by: -1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(terminalTextSize > TerminalTextSize.minimum ? 0.5 : 0.2))
                }
                .disabled(terminalTextSize <= TerminalTextSize.minimum)
                .contextMenu {
                    Button("Reset text size") { terminalTextSize = TerminalTextSize.standard }
                }
                .accessibilityLabel("Smaller text")
                Button {
                    terminalTextSize = TerminalTextSize.stepped(terminalTextSize, by: 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(terminalTextSize < TerminalTextSize.maximum ? 0.5 : 0.2))
                }
                .disabled(terminalTextSize >= TerminalTextSize.maximum)
                .contextMenu {
                    Button("Reset text size") { terminalTextSize = TerminalTextSize.standard }
                }
                .accessibilityLabel("Larger text")
                // Expand / collapse — hides the window-picker card above to
                // give the terminal more vertical real estate. Tap again to
                // bring the picker back. Compact: single icon button, reuses
                // the same row, reversible state.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                // §38 — iTerm scrollback nav. Two buttons in the header
                // (page up / page down) with long-press for top / bottom.
                // Sends quick_action strings; Mac side translates to
                // Shift+PageUp/Down or Cmd+Home/End via System Events.
                // Mac throttles per-window so rapid taps still fire.
                Button {
                    onSendAction("scroll_page_up", nil)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .accessibilityLabel("Scroll up one page")
                .accessibilityHint("Long-press to scroll to top")
                .accessibilityAddTraits(.isButton)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .onEnded { _ in onSendAction("scroll_top", nil) }
                )
                Button {
                    onSendAction("scroll_page_down", nil)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .accessibilityLabel("Scroll down one page")
                .accessibilityHint("Long-press to scroll to bottom (live)")
                .accessibilityAddTraits(.isButton)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .onEnded { _ in onSendAction("scroll_bottom", nil) }
                )
                // Accept autocomplete — presses Right-arrow in the focused
                // terminal to commit the shell/Claude inline suggestion (greyed
                // ghost text). Compact: reuses this header row, no new fixed row.
                // Gated on hasAutosuggest (US-003): active only when the Mac
                // reports a live suggestion, so a tap never nudges the cursor
                // into empty air.
                Button {
                    guard hasAutosuggest else { return }
                    onSendAction("press_right", nil)
                } label: {
                    Image(systemName: "text.append")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(hasAutosuggest ? 0.5 : 0.15))
                }
                .disabled(!hasAutosuggest)
                .accessibilityLabel("Accept autocomplete")
                .accessibilityHint("Accepts the shown suggestion on the Mac")
                .accessibilityAddTraits(.isButton)
                Button { onRefresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))

            // The terminal screenshot is pixels, so tapping the visible text
            // cannot carry an action. Surface it as a real Button immediately
            // above the image. A Codex placeholder focuses the phone field;
            // true ghost text remains the mobile equivalent of Right-arrow.
            if let autosuggest {
                let isPromptPlaceholder = AutosuggestDetector.isPromptMarkerOnly(autosuggest.typed)
                Button {
                    Self.acceptAutosuggest(using: onSendAction)
                } label: {
                    HStack(spacing: 0) {
                        Text(autosuggest.typed)
                            .foregroundStyle(colors.textSecondary)
                        Text(autosuggest.suggestion)
                            .foregroundStyle(colors.textSecondary.opacity(0.55))
                        Spacer(minLength: 6)
                        Image(systemName: "text.append")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.textSecondary)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colors.surface.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal-autosuggest-accept")
                .accessibilityLabel(isPromptPlaceholder
                                    ? "Focus prompt input"
                                    : "Accept suggestion: \(autosuggest.suggestion)")
                .accessibilityHint(isPromptPlaceholder
                                   ? "Opens the phone keyboard for a new prompt"
                                   : "Accepts the greyed suggestion on the Mac")
            }

            // §18 — context-aware numbered-prompt chips. When the shared
            // detector finds an agent CLI's numeric choice menu, render one
            // in-app button per detected option so Codex/Claude prompts with
            // 1...N choices are answerable without typing.
            // `answerableOptions`, not `detect`: the widget appends a free-text
            // "Type something" row after the real options, and a chip for it
            // opens an editor the phone cannot type into. Keystroke generation
            // still sees the full run, so the walk to Submit is unaffected.
            if let options = NumberedPromptDetector.answerableOptions(in: content), options.count >= 2 {
                let fingerprint = NumberedPromptDetector.fingerprint(in: content)
                if NumberedPromptDetector.isMultiSelect(in: content) {
                    // §18.2 — checkbox (multi-select) menu: accumulate picks on
                    // the phone, then submit them together so the terminal
                    // screen only mutates once. The Mac re-validates that single
                    // submit against `fingerprint` (no per-tap drop), toggles
                    // each pick, and presses Return once.
                    MultiSelectAnswerBar(options: options, fingerprint: fingerprint,
                                         content: content, onSubmit: onSendAction)
                } else if labsOneTapAnswer {
                    // §3.2 Labs — prominent, equal-width answer buttons with the
                    // prompt fingerprint so the Mac re-validates before injecting.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(options, id: \.self) { n in
                                Button {
                                    onSendAction("select_\(n)", fingerprint)
                                } label: {
                                    Text("\(n)")
                                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.white)
                                        .frame(minWidth: 46)
                                        .frame(height: 40)
                                        .background(Color.accentColor)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .accessibilityLabel("Pick option \(n)")
                                .accessibilityHint("Submit \(n) to the current prompt")
                                .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                } else {
                    // §18 — compact chips (default). Tap emits `select_<n>`;
                    // no fingerprint → Mac injects without re-validation.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(options, id: \.self) { n in
                                Button {
                                    onSendAction("select_\(n)", nil)
                                } label: {
                                    Text("\(n)")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.white)
                                        .frame(minWidth: 28)
                                        .frame(height: 24)
                                        .background(Color.accentColor.opacity(0.85))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .accessibilityLabel("Pick option \(n)")
                                .accessibilityHint("Submit \(n) to the current prompt")
                                .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                }
            } else if let tokens = NumberedPromptDetector.detectInlineOptions(in: content), tokens.count >= 2 {
                // §18.3 — inline bracketed choice prompt (`…? [all / 1 / 2 / none]`).
                // Single-select: each chip answers immediately. Digit tokens reuse
                // `select_N`; word tokens (all/none/pick/…) send `answer_text:<word>`.
                InlineAnswerBar(tokens: tokens,
                                fingerprint: NumberedPromptDetector.fingerprint(in: content),
                                onSubmit: onSendAction)
            }

            // URL tray above the content area so users can open URLs from
            // the screenshot (which is pixels and can't be tapped in-situ).
            urlTray

            // Three render branches, selected by `currentBranch` (pure fn
            // pinned by InlineTerminalContentBranchTests):
            //   .image   → SwiftUI Image inside ScrollView (zoom/pan, scroll-to-bottom)
            //   .text    → UITextView (own scroll, tap-to-open URL) — fallback
            //              when screenshot capture fails
            //   .loading → placeholder
            switch currentBranch {
            case .image:
                if let screenshot, let imageData = Data(base64Encoded: screenshot),
                   let uiImage = UIImage(data: imageData) {
                    // §36 — only auto-scroll to the new bottom when the
                    // user was already pinned there. If they scrolled up
                    // to read older content, the 2s screenshot refresh
                    // used to yank them right back down. Now we track
                    // distance-from-bottom and only re-pin when within
                    // ~40pt of the floor (close enough that they were
                    // clearly following the live tail).
                    // GH #38 — pinch to zoom (1×–4×), pan while zoomed,
                    // double-tap to fit again. GeometryReader outside the
                    // ScrollView (the reverse does not lay out).
                    GeometryReader { geo in
                    ScrollViewReader { proxy in
                        let baseScroll = ScrollView(screenshotZoom > 1 ? [.vertical, .horizontal] : .vertical) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width * screenshotZoom)
                                .id("bottom")
                        }
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    screenshotZoom = ScreenshotZoom.clamped(screenshotZoomAtPinchStart * value)
                                }
                                .onEnded { _ in
                                    screenshotZoomAtPinchStart = screenshotZoom
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation {
                                screenshotZoom = 1
                                screenshotZoomAtPinchStart = 1
                            }
                        }

                        if #available(iOS 18.0, *) {
                            baseScroll
                                .onScrollGeometryChange(for: Bool.self) { geo in
                                    let distance = geo.contentSize.height
                                        - (geo.contentOffset.y + geo.containerSize.height)
                                    return distance < 40
                                } action: { _, atBottom in
                                    isPinnedToBottom = atBottom
                                }
                                .onChange(of: screenshot) { _, _ in
                                    guard isPinnedToBottom else { return }
                                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                                }
                        } else {
                            baseScroll
                        }
                    }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .text:
                LinkableTerminalText(content: content, fontSize: terminalTextSize) { size in
                    terminalTextSize = size
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                Text(TerminalPanelFreshness.loadingText(base: loadingPlaceholder,
                                                        waitingSince: loadingSince, now: now))
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            }
        }
        .background(colors.overlayContainer)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Tinted border in the selected window's palette color so the
        // content panel visually ties back to the rectangle above it — easy
        // to tell at a glance which window you're driving, especially when
        // more than one window is on the picker. Controlled by a Settings
        // toggle; `.clear` hides it without shifting any layout.
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    tintContentBorder ? windowColor.opacity(0.7) : Color.clear,
                    lineWidth: 1.5
                )
        )
        // Deck-of-cards lift: Y-axis 3D flip + slight scale-down + shadow
        // that grows with swipe magnitude. All three cues together read as
        // "card being lifted off the top of a stack," not just "view being
        // dragged sideways." Tuned subtle — max ~9° rotation, 3% shrink,
        // soft shadow at full swipe.
        .rotation3DEffect(
            .degrees(Double(swipeOffset) * 0.22),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.6
        )
        .scaleEffect(1 - swipeProgress * 0.03)
        .shadow(
            color: .black.opacity(0.45 * swipeProgress),
            radius: 14 * swipeProgress,
            x: swipeOffset * 0.2,
            y: 4 * swipeProgress
        )
        .offset(x: swipeOffset)
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.75), value: swipeOffset)
        .onAppear {
            syncLoadingSince()
            onRefresh()
        }
        .onChange(of: loadingKey) { _, _ in syncLoadingSince() }
        .onReceive(refreshTimer) { date in
            tick(date)
            onRefresh()
        }
        // Swipe left/right on the panel → cycle windows. Threshold 90pt +
        // 2:1 horizontal-to-vertical ratio so vertical scroll inside the
        // image ScrollView + pinch-zoom still work. `simultaneousGesture`
        // so we don't block the screenshot's own gesture stack.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    // Only show drag feedback when the motion is clearly
                    // horizontal — otherwise the panel twitches sideways
                    // when the user is trying to scroll the screenshot.
                    // A zoomed screenshot pans instead of switching windows.
                    guard screenshotZoom <= 1, abs(dx) > abs(dy) * 2 else {
                        if swipeOffset != 0 { swipeOffset = 0 }
                        return
                    }
                    let damped = dx * 0.35
                    swipeOffset = max(-80, min(80, damped))
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    swipeOffset = 0
                    guard screenshotZoom <= 1, abs(dx) > 90, abs(dx) > abs(dy) * 2 else { return }
                    // Left swipe (dx < 0) advances to the NEXT window,
                    // matching the iOS convention of "content slides left
                    // to reveal what comes next," like Photos or TabView.
                    onCycleWindow?(dx < 0 ? 1 : -1)
                }
        )
    }

    private func keyButton(_ label: String, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                }
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

// MARK: - Quick Button Config
