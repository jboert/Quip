import Foundation

/// The default look of every keyboard-row button (Q-50, PRD key-styles,
/// US-201/202/206): an SF Symbol and a color chosen from what the button
/// says and does, so the row reads at a glance the way the purple prompt
/// pill always has. Nothing here is stored: styles are computed from the
/// button each time, and a color or symbol the user picked always wins.
///
/// Colors carry one meaning everywhere: green go, red stop, orange
/// interrupt or build, blue plan or answer, teal review or test, indigo
/// mode or question, pink design, gray editing keys. Purple is for prompts
/// only, so they keep standing out.
enum KeyHue: String, CaseIterable {
    case green, red, orange, blue, teal, indigo, pink, gray, purple

    /// Solid fill in light mode. White text reads on each at 4.5:1 or
    /// better. Nil for purple: prompt pills keep their own fill.
    var lightHex: String? {
        switch self {
        case .green: return "#17803A"
        case .red: return "#C62828"
        case .orange: return "#A84F00"
        case .blue: return "#1565C0"
        case .teal: return "#00796B"
        case .indigo: return "#3F51B5"
        case .pink: return "#C2185B"
        case .gray: return "#616161"
        case .purple: return nil
        }
    }

    /// Solid fill in dark mode, close to each system color at 0.55 opacity
    /// over black so it sits beside the prompt pill without looking louder.
    var darkHex: String? {
        switch self {
        case .green: return "#1A7330"
        case .red: return "#8C2620"
        case .orange: return "#8C5806"
        case .blue: return "#06498C"
        case .teal: return "#236E7B"
        case .indigo: return "#34337F"
        case .pink: return "#8C1E34"
        case .gray: return "#4E4E51"
        case .purple: return nil
        }
    }

    /// The name the color sheet shows ("Use automatic color (green)").
    var name: String { rawValue }
}

struct KeyStyle: Equatable {
    let symbol: String
    let hue: KeyHue
    /// Icon and label, or icon only. Answers and keystrokes are icon only so
    /// those pills stay narrow.
    let showsLabel: Bool
}

enum KeyStyles {
    static func builtin(_ button: QuickButton) -> KeyStyle {
        switch button {
        case .slash: return KeyStyle(symbol: "slash.circle", hue: .gray, showsLabel: false)
        case .plan: return KeyStyle(symbol: "list.bullet.clipboard", hue: .blue, showsLabel: true)
        case .btw: return KeyStyle(symbol: "text.bubble", hue: .indigo, showsLabel: true)
        case .compact: return KeyStyle(symbol: "arrow.down.right.and.arrow.up.left", hue: .orange, showsLabel: true)
        case .clearContext: return KeyStyle(symbol: "eraser", hue: .red, showsLabel: true)
        case .prd: return KeyStyle(symbol: "doc.richtext", hue: .blue, showsLabel: true)
        case .commitPushPr: return KeyStyle(symbol: "paperplane.fill", hue: .green, showsLabel: true)
        case .caveman: return KeyStyle(symbol: "flame.fill", hue: .orange, showsLabel: true)
        case .ultraReview: return KeyStyle(symbol: "sparkle.magnifyingglass", hue: .teal, showsLabel: true)
        case .brainstorm: return KeyStyle(symbol: "lightbulb", hue: .orange, showsLabel: true)
        case .writePlan: return KeyStyle(symbol: "square.and.pencil", hue: .blue, showsLabel: true)
        case .executePlan: return KeyStyle(symbol: "play.fill", hue: .green, showsLabel: true)
        case .resume: return KeyStyle(symbol: "clock.arrow.circlepath", hue: .indigo, showsLabel: true)
        case .model: return KeyStyle(symbol: "cpu", hue: .indigo, showsLabel: true)
        case .context: return KeyStyle(symbol: "gauge.with.dots.needle.33percent", hue: .teal, showsLabel: true)
        case .yes: return KeyStyle(symbol: "checkmark", hue: .green, showsLabel: false)
        case .no: return KeyStyle(symbol: "xmark", hue: .red, showsLabel: false)
        case .one: return KeyStyle(symbol: "1.circle", hue: .blue, showsLabel: false)
        case .two: return KeyStyle(symbol: "2.circle", hue: .blue, showsLabel: false)
        case .three: return KeyStyle(symbol: "3.circle", hue: .blue, showsLabel: false)
        case .esc: return KeyStyle(symbol: "escape", hue: .orange, showsLabel: false)
        case .ctrlC: return KeyStyle(symbol: "xmark.octagon", hue: .red, showsLabel: false)
        case .ctrlD: return KeyStyle(symbol: "eject", hue: .red, showsLabel: false)
        case .tab: return KeyStyle(symbol: "arrow.right.to.line", hue: .gray, showsLabel: false)
        case .backspace: return KeyStyle(symbol: "delete.left", hue: .gray, showsLabel: false)
        case .clearInput: return KeyStyle(symbol: "delete.left.fill", hue: .gray, showsLabel: false)
        case .shiftTab: return KeyStyle(symbol: "arrow.left.to.line", hue: .indigo, showsLabel: false)
        case .acceptAutocomplete: return KeyStyle(symbol: "text.append", hue: .teal, showsLabel: false)
        case .broadcast: return KeyStyle(symbol: "dot.radiowaves.left.and.right", hue: .blue, showsLabel: false)
        }
    }

    static let promptsPicker = KeyStyle(symbol: "doc.text.magnifyingglass", hue: .purple, showsLabel: true)
    static let slashGroup = KeyStyle(symbol: "slash.circle", hue: .gray, showsLabel: true)

    /// A custom button's style: the first label word in the keyword table,
    /// else the first payload word, else a plain default for its kind. A
    /// button that sends exactly what a built-in sends looks like that
    /// built-in, so an edited copy of one (Q-67) keeps its look.
    static func custom(label: String, payload: CustomPayload) -> KeyStyle {
        if case .keystroke(let action) = payload {
            if let builtin = keystrokeStyle(action) { return builtin }
            if let hit = match(label) { return KeyStyle(symbol: hit.symbol, hue: hit.hue, showsLabel: false) }
            return KeyStyle(symbol: "keyboard", hue: .gray, showsLabel: false)
        }
        let (payloadText, pressReturn, fallback): (String, Bool, String) = switch payload {
        case .slash(let text, let auto): (text, auto, "slash.circle")
        case .rawText(let text, let auto): (text, auto, "text.cursor")
        case .keystroke: ("", false, "keyboard")
        }
        if let button = QuickButton.allCases.first(where: {
            if case .sendText(let text, let sendsReturn) = $0.action { return text == payloadText && sendsReturn == pressReturn }
            return false
        }) {
            return builtin(button)
        }
        if let hit = match(label) ?? match(payloadText) {
            return KeyStyle(symbol: hit.symbol, hue: hit.hue, showsLabel: true)
        }
        return KeyStyle(symbol: fallback, hue: .gray, showsLabel: true)
    }

    /// A prompt keeps purple; only its icon comes from its name.
    static func prompt(label: String) -> KeyStyle {
        KeyStyle(symbol: match(label)?.symbol ?? "doc.text", hue: .purple, showsLabel: true)
    }

    /// Keys a custom keystroke button can send, styled as the built-in that
    /// sends the same key. The number keys and Return are listed here
    /// because the built-in 1/2/3 send text, and no built-in sends Return.
    private static func keystrokeStyle(_ action: String) -> KeyStyle? {
        switch action {
        case "press_1": return builtin(.one)
        case "press_2": return builtin(.two)
        case "press_3": return builtin(.three)
        case "press_return": return KeyStyle(symbol: "return", hue: .green, showsLabel: false)
        default: break
        }
        guard let button = QuickButton.allCases.first(where: {
            if case .quickAction(let name) = $0.action { return name == action }
            return false
        }) else { return nil }
        return builtin(button)
    }

    // MARK: - Words

    struct Entry {
        let keywords: [String]
        let symbol: String
        let hue: KeyHue
    }

    /// No keyword appears in two rows (a unit test holds this).
    static let table: [Entry] = [
        Entry(keywords: ["ship", "deploy", "release", "publish", "push"], symbol: "paperplane.fill", hue: .green),
        Entry(keywords: ["commit"], symbol: "checkmark.seal", hue: .green),
        Entry(keywords: ["run", "start", "launch", "go"], symbol: "play.fill", hue: .green),
        Entry(keywords: ["yes", "approve", "accept", "ok", "confirm"], symbol: "checkmark", hue: .green),
        Entry(keywords: ["continue", "next", "proceed"], symbol: "arrow.right.circle", hue: .green),
        Entry(keywords: ["stop", "cancel", "abort", "kill", "halt", "interrupt"], symbol: "stop.fill", hue: .red),
        Entry(keywords: ["clear", "reset", "clean", "wipe", "delete", "remove"], symbol: "trash", hue: .red),
        Entry(keywords: ["no", "deny", "reject"], symbol: "xmark", hue: .red),
        Entry(keywords: ["security", "secure", "auth", "password", "secret"], symbol: "lock.shield", hue: .red),
        Entry(keywords: ["fix", "bug", "debug", "error", "crash"], symbol: "ladybug", hue: .orange),
        Entry(keywords: ["build", "compile", "make"], symbol: "hammer", hue: .orange),
        Entry(keywords: ["merge", "branch", "rebase", "git", "pr"], symbol: "arrow.triangle.branch", hue: .orange),
        Entry(keywords: ["undo", "revert", "rollback"], symbol: "arrow.uturn.backward", hue: .orange),
        Entry(keywords: ["summary", "summarize", "compact", "recap", "tldr"],
              symbol: "arrow.down.right.and.arrow.up.left", hue: .orange),
        Entry(keywords: ["idea", "ideas", "brainstorm", "think"], symbol: "lightbulb", hue: .orange),
        Entry(keywords: ["perf", "performance", "speed", "fast"], symbol: "speedometer", hue: .orange),
        Entry(keywords: ["plan", "spec", "prd", "roadmap", "outline"], symbol: "list.bullet.clipboard", hue: .blue),
        Entry(keywords: ["doc", "docs", "document", "readme", "write", "notes"], symbol: "doc.text", hue: .blue),
        Entry(keywords: ["save"], symbol: "square.and.arrow.down", hue: .blue),
        Entry(keywords: ["install", "download"], symbol: "arrow.down.circle", hue: .blue),
        Entry(keywords: ["calendar", "week", "meeting", "schedule"], symbol: "calendar", hue: .blue),
        Entry(keywords: ["mail", "email", "message", "reply"], symbol: "envelope", hue: .blue),
        Entry(keywords: ["api", "network", "http", "server"], symbol: "network", hue: .blue),
        Entry(keywords: ["review", "audit", "inspect", "check"], symbol: "magnifyingglass", hue: .teal),
        Entry(keywords: ["search", "find", "grep", "lookup"], symbol: "magnifyingglass", hue: .teal),
        Entry(keywords: ["test", "tests", "qa", "verify"], symbol: "checklist", hue: .teal),
        Entry(keywords: ["agent", "agents", "spawn", "swarm", "team"], symbol: "person.3", hue: .teal),
        Entry(keywords: ["explain", "why", "help", "question", "ask"], symbol: "questionmark.circle", hue: .indigo),
        Entry(keywords: ["ui", "ux", "design", "mockup", "style", "redesign", "color", "colors"],
              symbol: "paintbrush", hue: .pink),
        Entry(keywords: ["refactor", "simplify", "cleanup"], symbol: "wand.and.stars", hue: .pink),
        Entry(keywords: ["log", "logs", "trace"], symbol: "list.bullet.rectangle", hue: .gray),
        Entry(keywords: ["data", "database", "db", "sql"], symbol: "cylinder", hue: .gray),
    ]

    private static let exact: [String: Entry] = {
        var map: [String: Entry] = [:]
        for entry in table { for word in entry.keywords { map[word] = entry } }
        return map
    }()

    /// Keywords a longer word may start with ("deploying" is deploy),
    /// longest first so the most specific one wins.
    private static let prefixes: [(String, Entry)] = table
        .flatMap { entry in entry.keywords.filter { $0.count >= 4 }.map { ($0, entry) } }
        .sorted { $0.0.count > $1.0.count }

    /// The first word of `text` that names a style, after the case and
    /// accent folding search uses. Word by word: an exact keyword, then a
    /// keyword of four or more letters the word starts with, so "Cleanup"
    /// is refactor (exact) and not clear ("clean" prefix).
    static func match(_ text: String) -> Entry? {
        for word in QuipSearch.words(QuipSearch.fold(text)) {
            if let entry = exact[word] { return entry }
            if let hit = prefixes.first(where: { word.hasPrefix($0.0) }) { return hit.1 }
        }
        return nil
    }
}

/// What one keyboard-row pill draws, decided from the button, the user's
/// color for it, and the "Automatic button style" switch (US-206). Off gives
/// the look the row had before Q-50, except that a misspelled symbol on a
/// custom button now shows its label instead of an empty pill.
struct KeyPillSpec: Equatable {
    enum Content: Equatable {
        case icon(String)
        case text(String)
        case iconAndLabel(symbol: String, label: String)
    }

    enum Fill: Equatable {
        /// A color the user picked, `#RRGGBB`.
        case user(String)
        case hue(KeyHue)
        /// The plain chip the row used before Q-50.
        case neutral
        /// The prompt pill's purple.
        case prompt
    }

    let content: Content
    let fill: Fill
    /// Prompt pills keep their own metrics and gray out when they cannot fire.
    let isPrompt: Bool

    static let autoStyleKey = "autoKeyStyle"

    static func builtin(_ button: QuickButton, auto: Bool, userColor: String?) -> KeyPillSpec {
        guard auto else {
            let content: Content = button.systemImage.map { .icon($0) } ?? .text(button.label)
            return KeyPillSpec(content: content, fill: fill(userColor, otherwise: .neutral), isPrompt: false)
        }
        let style = KeyStyles.builtin(button)
        return KeyPillSpec(content: content(style, label: button.label), fill: fill(userColor, otherwise: .hue(style.hue)),
                           isPrompt: false)
    }

    /// `symbolExists` says whether iOS knows a symbol name; the view passes
    /// `UIImage(systemName:)`.
    static func custom(_ button: CustomButton, auto: Bool, userColor: String?,
                       symbolExists: (String) -> Bool) -> KeyPillSpec {
        let typed = button.systemImage?.trimmingCharacters(in: .whitespaces) ?? ""
        let userSymbol = !typed.isEmpty && symbolExists(typed) ? typed : nil
        guard auto else {
            let content: Content = userSymbol.map { .icon($0) } ?? .text(button.label)
            return KeyPillSpec(content: content, fill: fill(userColor, otherwise: .neutral), isPrompt: false)
        }
        let style = KeyStyles.custom(label: button.label, payload: button.payload)
        let content: Content = userSymbol.map { .icon($0) } ?? self.content(style, label: button.label)
        return KeyPillSpec(content: content, fill: fill(userColor, otherwise: .hue(style.hue)), isPrompt: false)
    }

    static func prompt(label: String, auto: Bool, userColor: String?) -> KeyPillSpec {
        let symbol = auto ? KeyStyles.prompt(label: label).symbol : "doc.text"
        return KeyPillSpec(content: .iconAndLabel(symbol: symbol, label: label),
                           fill: fill(userColor, otherwise: .prompt), isPrompt: true)
    }

    static func promptsPicker(userColor: String?) -> KeyPillSpec {
        KeyPillSpec(content: .iconAndLabel(symbol: KeyStyles.promptsPicker.symbol, label: "Prompts"),
                    fill: fill(userColor, otherwise: .prompt), isPrompt: true)
    }

    /// The `/x…` pill that groups slash buttons sharing a first letter.
    static func slashGroup(letter: Character, auto: Bool) -> KeyPillSpec {
        let label = "/\(letter)…"
        guard auto else { return KeyPillSpec(content: .text(label), fill: .neutral, isPrompt: false) }
        return KeyPillSpec(content: .iconAndLabel(symbol: KeyStyles.slashGroup.symbol, label: label),
                           fill: .hue(KeyStyles.slashGroup.hue), isPrompt: false)
    }

    /// The pill for any slot of the row; nil for a spacer or a custom button
    /// that no longer exists.
    static func slot(_ slot: QuickSlot, auto: Bool, userColor: String?, customs: [UUID: CustomButton],
                     promptLabel: (String) -> String, symbolExists: (String) -> Bool) -> KeyPillSpec? {
        switch slot {
        case .builtin(let b): return builtin(b, auto: auto, userColor: userColor)
        case .custom(let id):
            return customs[id].map { custom($0, auto: auto, userColor: userColor, symbolExists: symbolExists) }
        case .prompt(let pid): return prompt(label: promptLabel(pid), auto: auto, userColor: userColor)
        case .promptsPicker: return promptsPicker(userColor: userColor)
        case .spacer: return nil
        }
    }

    /// The color sheet's reset button (US-204): it names the color the
    /// button goes back to, given the button's look with no color of its own.
    static func colorResetLabel(automatic spec: KeyPillSpec?, auto: Bool) -> String {
        guard auto, let spec else { return "Reset to default" }
        switch spec.fill {
        case .hue(let hue): return "Use automatic color (\(hue.name))"
        case .prompt: return "Use automatic color (\(KeyHue.purple.name))"
        case .user, .neutral: return "Reset to default"
        }
    }

    private static func content(_ style: KeyStyle, label: String) -> Content {
        style.showsLabel && !label.isEmpty ? .iconAndLabel(symbol: style.symbol, label: label) : .icon(style.symbol)
    }

    private static func fill(_ userColor: String?, otherwise fallback: Fill) -> Fill {
        if let hex = userColor.flatMap(WindowColor.normalized) { return .user(hex) }
        if case .hue(.purple) = fallback { return .prompt }
        return fallback
    }
}
