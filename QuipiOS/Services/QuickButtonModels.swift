import SwiftUI
import AVFoundation

enum QuickButton: String, CaseIterable, Identifiable {
    // Declaration order matters — `allCases` uses it to render the settings
    // list and the enabled row on the phone. Grouped:
    //   Slash commands (sends "/foo"),
    //   Claude Code answers (Y/N and number choices),
    //   Terminal keystrokes (Esc, Ctrl-C, Ctrl-D, Tab, Backspace).
    case slash, plan, btw, compact, clearContext, prd
    case commitPushPr, caveman, ultraReview
    // Popular commands, reachable from the long-press slash palette without
    // being pinned to the row: the Superpowers plugin workflow, then Claude
    // Code's own pickers.
    case brainstorm, writePlan, executePlan, resume, model, context
    // Commands Codex has, some of which Claude Code shares. `SlashAgents`
    // decides which windows' palettes list each one (Q-72).
    case initProject, status, permissions, mcp, newChat, diff, review, side
    case yes, no, one, two, three
    case esc, ctrlC, ctrlD, tab, backspace, clearInput
    case shiftTab
    // Q-89: walk a menu that has no numbers to type.
    case arrowUp, arrowDown
    // Accepts shell/agent inline autocomplete. The legacy wire action remains
    // `press_right`; the Mac re-scrapes and chooses Tab or Right-arrow.
    case acceptAutocomplete
    // Opens the Broadcast sheet on the phone; sends nothing by itself (US-109).
    case broadcast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slash: return "/"
        case .plan: return "/plan"
        case .btw: return "/btw"
        case .compact: return "/compact"
        case .clearContext: return "/clear"
        case .prd: return "/prd"
        case .commitPushPr: return "/commit-commands:commit-push-pr"
        case .caveman: return "/caveman:caveman"
        case .ultraReview: return "/ultrareview"
        case .brainstorm: return "/superpowers:brainstorming"
        case .writePlan: return "/superpowers:writing-plans"
        case .executePlan: return "/superpowers:executing-plans"
        case .resume: return "/resume"
        case .model: return "/model"
        case .context: return "/context"
        case .initProject: return "/init"
        case .status: return "/status"
        case .permissions: return "/permissions"
        case .mcp: return "/mcp"
        case .newChat: return "/new"
        case .diff: return "/diff"
        case .review: return "/review"
        case .side: return "/side"
        case .yes: return "Y"
        case .no: return "N"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .esc: return "Esc"
        case .ctrlC: return "Ctrl+C"
        case .ctrlD: return "Ctrl+D"
        case .tab: return "Tab"
        case .backspace: return "Backspace"
        case .clearInput: return "Clear input"
        case .shiftTab: return "Shift+Tab"
        case .arrowUp: return "Up arrow"
        case .arrowDown: return "Down arrow"
        case .acceptAutocomplete: return "Accept autocomplete"
        case .broadcast: return "Broadcast"
        }
    }

    /// Short label shown in the on-screen button itself (vs. `displayName`
    /// which shows in Settings).
    var label: String {
        switch self {
        case .slash: return "/"
        case .plan: return "/plan"
        case .btw: return "/btw"
        case .compact: return "/compact"
        case .clearContext: return "/clear"
        case .prd: return "/prd"
        // Long slash commands shortened to fit the phone button row.
        // Settings still lists the full command.
        case .commitPushPr: return "/ship"
        case .caveman: return "/cave"
        case .ultraReview: return "/ultra"
        case .brainstorm: return "/brainstorm"
        case .writePlan: return "/writeplan"
        case .executePlan: return "/execplan"
        case .resume: return "/resume"
        case .model: return "/model"
        case .context: return "/context"
        case .initProject: return "/init"
        case .status: return "/status"
        case .permissions: return "/perms"
        case .mcp: return "/mcp"
        case .newChat: return "/new"
        case .diff: return "/diff"
        case .review: return "/review"
        case .side: return "/side"
        case .yes: return "Y"
        case .no: return "N"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .esc: return "Esc"
        case .ctrlC: return "Ctrl+C"
        case .ctrlD: return "Ctrl+D"
        case .tab: return "Tab"
        // Icon-only buttons — the SF Symbol carries the meaning. Empty label
        // keeps the button compact.
        case .backspace: return ""
        case .clearInput: return ""
        case .shiftTab: return ""
        case .arrowUp, .arrowDown: return ""
        case .acceptAutocomplete: return ""
        case .broadcast: return ""
        }
    }

    var systemImage: String? {
        switch self {
        case .backspace: return "delete.left"
        case .esc: return "escape"
        case .ctrlC: return "xmark.octagon"
        case .ctrlD: return "eject"
        case .tab: return "arrow.right.to.line"
        case .clearInput: return "delete.left.fill"
        case .shiftTab: return "arrow.left.to.line"
        case .arrowUp: return "arrow.up"
        case .arrowDown: return "arrow.down"
        case .acceptAutocomplete: return "text.append"
        // The Broadcast bar's icon, so the two entry points look alike.
        case .broadcast: return "dot.radiowaves.left.and.right"
        default: return nil
        }
    }

    enum Action {
        case sendText(String, pressReturn: Bool)
        case quickAction(String)
        /// Handled on the phone: opens the Broadcast sheet.
        case openBroadcast
    }

    var isSlashCommand: Bool {
        if case .sendText(let text, _) = action { return text.hasPrefix("/") }
        return false
    }

    /// Logical grouping used by the on-screen quick-button row to position
    /// each cluster: slash commands left, answers centered (under the mic),
    /// keystrokes right. `app` keys open something on the phone.
    enum Category { case slash, answer, keystroke, app }

    var category: Category {
        switch self {
        case .slash, .plan, .btw, .compact, .clearContext, .prd, .commitPushPr, .caveman, .ultraReview,
             .brainstorm, .writePlan, .executePlan, .resume, .model, .context,
             .initProject, .status, .permissions, .mcp, .newChat, .diff, .review, .side: return .slash
        case .yes, .no, .one, .two, .three: return .answer
        case .esc, .ctrlC, .ctrlD, .tab, .backspace, .clearInput, .shiftTab, .arrowUp, .arrowDown,
             .acceptAutocomplete: return .keystroke
        case .broadcast: return .app
        }
    }

    var action: Action {
        switch self {
        // Bare "/" — opens Claude Code's slash command palette so the user
        // can pick one via autocomplete. No trailing space (unlike /plan,
        // /btw, /prd) so Claude's Ink dropdown fires immediately.
        case .slash: return .sendText("/", pressReturn: false)
        case .plan: return .sendText("/plan ", pressReturn: false)
        case .btw: return .sendText("/btw ", pressReturn: false)
        // /compact auto-submits because unlike /plan or /btw it doesn't
        // take a follow-up argument — it's a standalone command that
        // tells Claude "summarize the context now."
        case .compact: return .sendText("/compact", pressReturn: true)
        case .clearContext: return .sendText("/clear", pressReturn: true)
        // /prd takes a follow-up description, so don't auto-submit — same
        // pattern as /plan and /btw.
        case .prd: return .sendText("/prd ", pressReturn: false)
        // Standalone commands — auto-submit.
        case .commitPushPr: return .sendText("/commit-commands:commit-push-pr", pressReturn: true)
        case .caveman: return .sendText("/caveman:caveman", pressReturn: true)
        case .ultraReview: return .sendText("/ultrareview", pressReturn: true)
        // The Superpowers skills take what to work on, so leave the prompt
        // open for it — same pattern as /plan.
        case .brainstorm: return .sendText("/superpowers:brainstorming ", pressReturn: false)
        case .writePlan: return .sendText("/superpowers:writing-plans ", pressReturn: false)
        case .executePlan: return .sendText("/superpowers:executing-plans ", pressReturn: false)
        // These open Claude Code's own pickers / report, so submit at once.
        case .resume: return .sendText("/resume", pressReturn: true)
        case .model: return .sendText("/model", pressReturn: true)
        case .context: return .sendText("/context", pressReturn: true)
        case .initProject: return .sendText("/init", pressReturn: true)
        case .status: return .sendText("/status", pressReturn: true)
        case .permissions: return .sendText("/permissions", pressReturn: true)
        case .mcp: return .sendText("/mcp", pressReturn: true)
        case .newChat: return .sendText("/new", pressReturn: true)
        case .diff: return .sendText("/diff", pressReturn: true)
        case .review: return .sendText("/review", pressReturn: true)
        // Codex's side question, like Claude's /btw: leave it open for the
        // question.
        case .side: return .sendText("/side ", pressReturn: false)
        case .yes: return .quickAction("press_y")
        case .no: return .quickAction("press_n")
        case .one: return .sendText("1", pressReturn: true)
        case .two: return .sendText("2", pressReturn: true)
        case .three: return .sendText("3", pressReturn: true)
        case .esc: return .quickAction("press_escape")
        case .ctrlC: return .quickAction("press_ctrl_c")
        case .ctrlD: return .quickAction("press_ctrl_d")
        case .tab: return .quickAction("press_tab")
        case .backspace: return .quickAction("press_backspace")
        case .clearInput: return .quickAction("clear_input")
        // Raw Shift+Tab — cycles Claude mode (normal → autoAccept → plan).
        case .shiftTab: return .quickAction("press_shift_tab")
        case .arrowUp: return .quickAction("press_up")
        case .arrowDown: return .quickAction("press_down")
        // Accepts the live inline suggestion; Mac chooses Tab or Right-arrow.
        case .acceptAutocomplete: return .quickAction("press_right")
        case .broadcast: return .openBroadcast
        }
    }

    static func decode(_ raw: String) -> [QuickButton] {
        raw.split(separator: ",").compactMap { QuickButton(rawValue: String($0)) }
    }

    static func encode(_ buttons: [QuickButton]) -> String {
        buttons.map(\.rawValue).joined(separator: ",")
    }
}

// MARK: - Custom Buttons + Slot Ordering

/// Action a user-defined button performs when tapped. Mirrors the three
/// `QuickButton.Action` shapes so render + send code can route customs
/// through the same `fireQuickButton`-style path.
enum CustomPayload: Hashable {
    /// Send "/foo[ ]" — autoSubmit controls whether to press Return after.
    /// Slash commands like /clear / /compact auto-submit; /plan / /btw
    /// don't (they take a follow-up argument).
    case slash(text: String, autoSubmit: Bool)
    /// Send arbitrary text (no leading slash). autoSubmit toggles Return.
    case rawText(text: String, autoSubmit: Bool)
    /// Send a `quick_action` to the Mac (press_y / press_n / press_escape /
    /// press_ctrl_c / press_ctrl_d / press_tab / press_backspace /
    /// clear_input / press_shift_tab).
    case keystroke(action: String)
}

// Hand-rolled Codable for the same reason as QuickSlot — synthesis fails
// under our build settings. Wire format: `kind` discriminator + payload
// fields. `kind` strings are persisted, don't rename without a migration.
extension CustomPayload: Codable {
    private enum CodingKeys: String, CodingKey { case kind, text, autoSubmit, action }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "slash":
            self = .slash(
                text: try c.decode(String.self, forKey: .text),
                autoSubmit: try c.decode(Bool.self, forKey: .autoSubmit)
            )
        case "rawText":
            self = .rawText(
                text: try c.decode(String.self, forKey: .text),
                autoSubmit: try c.decode(Bool.self, forKey: .autoSubmit)
            )
        case "keystroke":
            self = .keystroke(action: try c.decode(String.self, forKey: .action))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown CustomPayload kind: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .slash(let text, let auto):
            try c.encode("slash", forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encode(auto, forKey: .autoSubmit)
        case .rawText(let text, let auto):
            try c.encode("rawText", forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encode(auto, forKey: .autoSubmit)
        case .keystroke(let action):
            try c.encode("keystroke", forKey: .kind)
            try c.encode(action, forKey: .action)
        }
    }
}

/// User-defined button. Persisted as JSON in `customButtonsJSON` and
/// referenced from `QuickSlot.custom(id)` so the slot list and the
/// definitions table stay independent (re-ordering doesn't mutate
/// definitions; deleting from definitions removes any slots pointing at
/// that id at next render).
struct CustomButton: Codable, Hashable, Identifiable {
    let id: UUID
    var label: String
    /// Optional SF Symbol name. Empty / unknown falls back to text label.
    var systemImage: String?
    var payload: CustomPayload
    /// Agent CLIs (`CLIKind` raw values) a slash button is for (Q-72); nil
    /// or empty means every agent. Raw strings so an agent a newer build
    /// adds does not cost an older build the whole button.
    var agentIDs: [String]? = nil
}

/// One entry in the user's quick-button row. The row renders these in
/// declaration order (no auto-clustering — the user controls position by
/// inserting `.spacer` slots, Apple-toolbar-style).
enum QuickSlot: Hashable, Identifiable {
    case builtin(QuickButton)
    case custom(UUID)
    /// Reference to a Mac-side prompt (wishlist §B3). Renders as a pill
    /// labeled with the prompt's display name; tapping fires
    /// PastePromptMessage to the active window. The prompt itself lives
    /// on the Mac in ~/Library/Application Support/Quip/prompts/<id>.txt
    /// and may not exist if the Mac hasn't broadcast its catalog yet —
    /// the renderer shows a placeholder pill in that case.
    case prompt(promptID: String)
    /// Single keyboard button labeled "Prompts" — opens the prompt
    /// library sheet sorted by most-recently-used. Replaces the
    /// per-prompt slot pattern when the user has many prompts (the
    /// individual `.prompt(promptID:)` slot doesn't scale past ~5
    /// prompts on the keyboard row). Tap → sheet → tap a prompt →
    /// fires PastePromptMessage to the active window. The phone
    /// records lastUsed locally so ordering reflects this device's
    /// usage rather than the catalog's filename order.
    case promptsPicker
    /// Fixed-width gap between adjacent slots. Multiple spacers in a row
    /// stack their widths. Carries a UUID so SwiftUI lists can identify
    /// each spacer separately when there's more than one.
    case spacer(UUID)

    var id: String {
        switch self {
        case .builtin(let b): return "b:\(b.rawValue)"
        case .custom(let uid): return "c:\(uid.uuidString)"
        case .prompt(let pid): return "p:\(pid)"
        case .promptsPicker: return "pp"
        case .spacer(let uid): return "s:\(uid.uuidString)"
        }
    }
}

// Codable hand-rolled — Swift's automatic synthesis chokes on this enum
// shape under our build settings. Stable wire format: `kind` discriminator
// + a value field per case. `kind` strings are part of the persistence
// format — don't rename without a migration.
extension QuickSlot: Codable {
    private enum CodingKeys: String, CodingKey { case kind, button, customID, promptID, spacerID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "builtin":
            let raw = try c.decode(String.self, forKey: .button)
            guard let button = QuickButton(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .button, in: c,
                    debugDescription: "Unknown QuickButton raw value: \(raw)"
                )
            }
            self = .builtin(button)
        case "custom":
            self = .custom(try c.decode(UUID.self, forKey: .customID))
        case "prompt":
            self = .prompt(promptID: try c.decode(String.self, forKey: .promptID))
        case "promptsPicker":
            self = .promptsPicker
        case "spacer":
            self = .spacer(try c.decode(UUID.self, forKey: .spacerID))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown QuickSlot kind: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let b):
            try c.encode("builtin", forKey: .kind)
            try c.encode(b.rawValue, forKey: .button)
        case .custom(let id):
            try c.encode("custom", forKey: .kind)
            try c.encode(id, forKey: .customID)
        case .prompt(let pid):
            try c.encode("prompt", forKey: .kind)
            try c.encode(pid, forKey: .promptID)
        case .promptsPicker:
            try c.encode("promptsPicker", forKey: .kind)
        case .spacer(let id):
            try c.encode("spacer", forKey: .kind)
            try c.encode(id, forKey: .spacerID)
        }
    }
}

/// Encode/decode + legacy-CSV migration for the slot list. Kept as a
/// caseless enum (namespace) so the helpers don't accidentally get
/// instantiated.
enum QuickSlotStore {
    /// Latches the decode-failure log on the offending blob. `decode` is called
    /// from `MainiOSView.effectiveQuickSlots`, a COMPUTED PROPERTY consumed in
    /// `body` — and `body` re-evaluates on every output_delta / terminal_content
    /// / keystroke / TTS event. A corrupt blob (exactly the condition this log
    /// detects, and a realistic one: `PreferencesSyncService` restores this blob
    /// from the Mac, so cross-version schema drift lands here) would otherwise
    /// print hundreds of lines per second while terminal output streams, which
    /// destroys the log instead of informing it.
    ///
    /// Latched on the blob itself, so a CHANGED blob is re-reported and a
    /// successful decode re-arms — "log once until the cause changes".
    static let decodeLatch = LogLatch()

    /// Empty `raw` is the fresh-install path and stays silent. A NON-empty
    /// `raw` that fails to decode is schema drift / corruption: the user's
    /// saved button row is about to be silently replaced by defaults, which
    /// reads as "Quip forgot my buttons" with zero log evidence. Log loudly —
    /// but ONCE per distinct corrupt blob (see `decodeLatch`).
    /// `log` and `latch` are injected (same shape as
    /// `WebSocketClient.decodeMessage`) so tests can assert both the drop and
    /// its cadence without trapping stdout or leaking state between cases.
    static func decode(_ raw: String,
                       log: (String) -> Void = { print($0) },
                       latch: LogLatch = decodeLatch) -> [QuickSlot] {
        guard !raw.isEmpty else { return [] }
        guard let data = raw.data(using: .utf8) else {
            let v = latch.verdict(for: "utf8:\(raw)")
            if v.shouldLog {
                log("[Quip][Store] quickSlots decode FAILED: raw is not valid UTF-8 (chars=\(raw.count)) — row reset to defaults" + v.suffix)
            }
            return []
        }
        do {
            // Slot by slot: one this build does not know (a button or kind a
            // newer build added, met in a restored backup) is skipped instead
            // of costing the whole row (US-109). Builds before this one still
            // drop the whole row on such a slot.
            let decoded = try JSONDecoder().decode([LossyQuickSlot].self, from: data)
            let slots = decoded.compactMap(\.slot)
            if slots.count < decoded.count {
                let v = latch.verdict(for: "skip:\(raw)")
                if v.shouldLog {
                    log("[Quip][Store] quickSlots skipped \(decoded.count - slots.count) of \(decoded.count) slot(s) this build does not know — kept the rest" + v.suffix)
                }
            } else {
                latch.noteSuccess()
            }
            return slots
        } catch {
            let v = latch.verdict(for: "json:\(raw)")
            if v.shouldLog {
                log("[Quip][Store] quickSlots decode FAILED bytes=\(data.count) err=\(error) — saved button row lost, resetting to defaults" + v.suffix)
            }
            return []
        }
    }

    /// One element of the saved row; `slot` is nil when this build cannot
    /// decode it.
    private struct LossyQuickSlot: Decodable {
        let slot: QuickSlot?
        init(from decoder: Decoder) throws {
            slot = try? QuickSlot(from: decoder)
        }
    }

    /// An encode failure here persists `"[]"` over the user's real row — a
    /// destructive silent wipe. Keep the existing fallback (callers assign
    /// straight into @AppStorage) but make the wipe audible.
    static func encode(_ slots: [QuickSlot], log: (String) -> Void = { print($0) }) -> String {
        do {
            let data = try JSONEncoder().encode(slots)
            guard let str = String(data: data, encoding: .utf8) else {
                log("[Quip][Store] quickSlots encode FAILED: UTF-8 conversion (slots=\(slots.count)) — row NOT persisted")
                return "[]"
            }
            return str
        } catch {
            log("[Quip][Store] quickSlots encode FAILED slots=\(slots.count) err=\(error) — row NOT persisted")
            return "[]"
        }
    }

    /// Migrate the legacy CSV `enabledQuickButtons` representation to the
    /// new ordered slot list. Inserts a `.spacer` whenever the category
    /// changes between adjacent built-ins, so the migrated row visually
    /// matches the old auto-cluster layout (slash | answers | keystrokes).
    static func migrate(fromCSV csv: String) -> [QuickSlot] {
        let buttons = QuickButton.decode(csv)
        var slots: [QuickSlot] = []
        var lastCategory: QuickButton.Category?
        for btn in buttons {
            if let last = lastCategory, last != btn.category {
                slots.append(.spacer(UUID()))
            }
            slots.append(.builtin(btn))
            lastCategory = btn.category
        }
        return slots
    }

    /// Fresh-install starter row. Designed so a new user (or a QA run on a
    /// freshly-erased simulator) sees both built-ins AND a custom button
    /// the moment the app connects — proving the feature exists without
    /// a Settings drill-down. Includes a `.custom(demoCustomID)` slot
    /// that pairs with `CustomButtonStore.defaultDemo()` to render a
    /// visible custom-button pill out of the box.
    static func defaultSlots(demoCustomID: UUID) -> [QuickSlot] {
        return [
            .builtin(.btw),
            .custom(demoCustomID),
            .spacer(UUID()),
            .builtin(.yes),
            .builtin(.no),
            .spacer(UUID()),
            .builtin(.one),
            .builtin(.two),
            .spacer(UUID()),
            .builtin(.esc),
            .builtin(.backspace),
        ]
    }
}

/// Encode/decode the custom-button definitions table.
enum CustomButtonStore {
    /// Same render-cadence hazard as `QuickSlotStore.decodeLatch`, and worse:
    /// `MainiOSView.customButtonDefs` is read by `effectiveQuickSlots` AND by
    /// `body` directly, so a corrupt blob decodes 3+ times per render.
    static let decodeLatch = LogLatch()

    /// See `QuickSlotStore.decode` — empty is the fresh-install path; a
    /// non-empty blob that won't decode means the user's custom buttons are
    /// being silently dropped. Logged once per distinct corrupt blob.
    static func decode(_ raw: String,
                       log: (String) -> Void = { print($0) },
                       latch: LogLatch = decodeLatch) -> [CustomButton] {
        guard !raw.isEmpty else { return [] }
        guard let data = raw.data(using: .utf8) else {
            let v = latch.verdict(for: "utf8:\(raw)")
            if v.shouldLog {
                log("[Quip][Store] customButtons decode FAILED: raw is not valid UTF-8 (chars=\(raw.count)) — buttons lost" + v.suffix)
            }
            return []
        }
        do {
            let buttons = try JSONDecoder().decode([CustomButton].self, from: data)
            latch.noteSuccess()
            return buttons
        } catch {
            let v = latch.verdict(for: "json:\(raw)")
            if v.shouldLog {
                log("[Quip][Store] customButtons decode FAILED bytes=\(data.count) err=\(error) — saved custom buttons lost" + v.suffix)
            }
            return []
        }
    }

    static func encode(_ buttons: [CustomButton], log: (String) -> Void = { print($0) }) -> String {
        do {
            let data = try JSONEncoder().encode(buttons)
            guard let str = String(data: data, encoding: .utf8) else {
                log("[Quip][Store] customButtons encode FAILED: UTF-8 conversion (buttons=\(buttons.count)) — NOT persisted")
                return "[]"
            }
            return str
        } catch {
            log("[Quip][Store] customButtons encode FAILED buttons=\(buttons.count) err=\(error) — NOT persisted")
            return "[]"
        }
    }

    /// Single starter custom button seeded on truly-fresh installs so the
    /// quick-button row visibly proves the custom-button feature exists.
    /// UUID is stable so re-entering the seed path can detect "already
    /// seeded" without searching by label. Slash payload is a friendly
    /// no-op (`/help `) — leaves the cursor on the same line so the user
    /// can either submit or backspace it away.
    static let demoCustomID: UUID = UUID(uuidString: "DEAD1DEA-0000-0000-0000-000000000001")!

    static func defaultDemo() -> CustomButton {
        // No systemImage — `customQuickButton` renders icon OR label
        // (never both), so seeding an icon would hide the "/help"
        // label and the demo would look like an unmarked sparkle pill.
        // Letting the label render as text matches the visual style
        // of the built-in `/btw` slash pill and makes the demo's
        // purpose obvious without a tap.
        return CustomButton(
            id: demoCustomID,
            label: "/help",
            systemImage: nil,
            payload: .slash(text: "/help ", autoSubmit: false)
        )
    }
}

// MARK: - Settings Sheet

extension Notification.Name {
    /// Posted by the `quip://perms` deep-link handler so MainiOSView can pop
    /// the SettingsSheet. Carries no payload — the sheet always opens to the
    /// Mac Permissions section (it's at the top).
    static let quipShowSettings = Notification.Name("quip.showSettings")

    /// Posted by the `quip://pair` deep-link handler with a `PairingPayload`
    /// as its `object`, so MainiOSView can run `applyPairingPayload` (the same
    /// pairing+connect path the in-app QR scanner uses).
    static let quipApplyPairing = Notification.Name("quip.applyPairing")
}
