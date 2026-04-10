import SwiftUI

/// Compact notification banner shown while TTS audio is playing.
/// Pinned to the bottom — does not cover the rest of the screen.
/// Tap to open that window's content view; swipe down to stop TTS.
/// Expands to fit longer output (up to 6 lines).
struct TTSNotificationOverlay: View {
    let currentSpeakingWindowId: String?
    let windows: [WindowState]
    let ttsTexts: [String: String]
    var onTap: (String) -> Void     // tap → open content for windowId
    var onSwipeDismiss: () -> Void  // swipe away → stop TTS

    private var speakingWindow: WindowState? {
        guard let wid = currentSpeakingWindowId else { return nil }
        return windows.first { $0.id == wid }
    }

    @State private var dragOffset: CGFloat = 0
    @State private var expanded = false

    var body: some View {
        if let window = speakingWindow {
            let text = ttsTexts[window.id] ?? ""
            ttsCard(window: window, text: text)
                .offset(y: max(0, dragOffset))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = value.translation.height
                        }
                        .onEnded { value in
                            if value.translation.height > 40 {
                                onSwipeDismiss()
                            } else if value.translation.height < -30 {
                                withAnimation { expanded = true }
                            }
                            dragOffset = 0
                        }
                )
                .onTapGesture { onTap(window.id) }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: currentSpeakingWindowId)
        }
    }

    private func ttsCard(window: WindowState, text: String) -> some View {
        let windowColor = Color(hex: window.color)
        let displayText = cleanForDisplay(text)

        return HStack(alignment: .top, spacing: 12) {
            // Window color accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(windowColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                // Window name header
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(windowColor.opacity(0.9))
                    Text(window.app)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("tap to view")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.25))
                }

                // Spoken text — collapsed (6 lines) or expanded (up to 15)
                if !displayText.isEmpty {
                    Text(displayText)
                        .font(.system(size: 16, weight: .regular, design: .default))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(expanded ? 15 : 6)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(windowColor.opacity(0.2), lineWidth: 0.5)
        )
    }

    /// Strip terminal UI chrome to show clean prose matching TTS output.
    /// Mirrors the Python filter_text() logic in kokoro_tts.py.
    private func cleanForDisplay(_ text: String) -> String {
        let decorSymbols = CharacterSet(charactersIn: "⏺●✻✳✢✔✓✗⚡⚠◆◇◈◉○◎◐◑◒◓⏵⏴▶◀►◄▲▼▸▹▾▿⟦⟧⌁⌂⌃⌄⌇✦✧✩✪✫✶✴✷✸✹✺✻★☆")
        let dropSymbols = CharacterSet(charactersIn: "⎿⊢⊣⊤⊥")
        let toolVerbs: Set<String> = ["searched", "read", "edited", "wrote", "created", "deleted",
                                       "moved", "copied", "found", "listed", "ran", "executed",
                                       "updated", "modified", "fetched", "checked"]

        // Step 1: Find the LAST "⏺ <prose>" line (not a tool call or tool summary)
        // and take content from there onward — this is the key filter the Python uses.
        let rawLines = text.components(separatedBy: "\n")
        var lastResponseIdx: Int? = nil
        for (idx, line) in rawLines.enumerated() {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard stripped.hasPrefix("⏺") else { continue }
            let rest = String(stripped.dropFirst()).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { continue }
            if rest.range(of: #"^[A-Z][A-Za-z]*\("#, options: .regularExpression) != nil { continue }
            let firstWord = rest.split(separator: " ", maxSplits: 1).first.map { String($0).lowercased() } ?? ""
            if toolVerbs.contains(firstWord) { continue }
            lastResponseIdx = idx
        }
        let lines: [String]
        if let idx = lastResponseIdx {
            lines = Array(rawLines[idx...])
        } else {
            lines = rawLines
        }

        // Step 2: Filter individual lines
        var kept: [String] = []
        for line in lines {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            // Drop tool-result lines
            if let first = s.unicodeScalars.first, dropSymbols.contains(first) { continue }
            // Strip decoration symbols from start
            while let first = s.unicodeScalars.first, decorSymbols.contains(first) {
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if s.isEmpty { continue }
            // Skip tool calls
            if s.range(of: #"^[A-Z][A-Za-z]*\("#, options: .regularExpression) != nil { continue }
            let low = s.lowercased()
            // Skip status lines
            if s.contains("·") && (low.contains("tokens") || low.contains("context") || low.contains("shortcuts")) { continue }
            if low.contains("? for shortcuts") || low.contains("esc to interrupt") { continue }
            // Skip thinking indicators
            if s.range(of: #"\b\w{4,}(ed|ing)\s+for\s+\d+\s*[mhs]"#, options: .regularExpression) != nil { continue }
            // Skip shell prompts
            if s.hasPrefix("➜") || s.hasPrefix("❯") || s.hasPrefix("»") { continue }
            if s.range(of: #"^[\w.-]+@[\w.-]+[:\s]"#, options: .regularExpression) != nil { continue }
            // Skip diff lines
            if s.hasPrefix("+++ ") || s.hasPrefix("--- ") || s.hasPrefix("@@ ") { continue }
            if line.range(of: #"^\s*\d{1,5}\s+[+\-]?\s"#, options: .regularExpression) != nil { continue }
            // Skip file paths
            if s.range(of: #"^/?[\w./-]+\.\w+(:\d+)?$"#, options: .regularExpression) != nil { continue }
            // Skip lines with box-drawing characters
            if s.unicodeScalars.contains(where: { $0.value >= 0x2500 && $0.value <= 0x259F }) { continue }
            // Skip tmux/terminal bars with multiple separators
            if s.filter({ $0 == "│" }).count >= 2 || s.filter({ $0 == "|" }).count >= 3 { continue }
            // Skip progress bars
            if s.range(of: #"[█▓▒░▌▐]{2,}"#, options: .regularExpression) != nil { continue }
            // Skip indented code
            if (line.hasPrefix("    ") || line.hasPrefix("\t")) &&
               s.range(of: #"[{}()]|=>|->|import |def |fn |class |let |var |const |function"#, options: .regularExpression) != nil { continue }
            // Skip tool summaries
            if low.contains("ctrl+o to expand") || low.contains("ctrl+r to expand") || low.contains("to expand") { continue }
            let firstWord = low.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if toolVerbs.contains(firstWord) { continue }
            // Strip markdown
            s = s.replacingOccurrences(of: "**", with: "")
            s = s.replacingOccurrences(of: "`", with: "")
            // Strip numbered list prefixes
            if let r = s.range(of: #"^\d+\.\s+"#, options: .regularExpression) { s = String(s[r.upperBound...]) }
            // Replace symbols
            s = s.replacingOccurrences(of: "→", with: "to")
            s = s.replacingOccurrences(of: "—", with: ", ")
            if !s.isEmpty { kept.append(s) }
        }
        let joined = kept.joined(separator: "\n")
        if joined.count > 500 {
            return String(joined.prefix(500)) + "..."
        }
        return joined
    }
}
