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
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: currentSpeakingWindowId)
        }
    }

    private func ttsCard(window: WindowState, text: String) -> some View {
        let windowColor = Color(hex: window.color)
        let displayText = cleanForDisplay(text)

        return HStack(alignment: .top, spacing: 10) {
            // Window color accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(windowColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                // Window name header
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(windowColor.opacity(0.9))
                    Text(window.app)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("tap to view")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.white.opacity(0.25))
                }

                // Spoken text — collapsed (2 lines) or expanded (up to 10)
                if !displayText.isEmpty {
                    Text(displayText)
                        .font(.system(size: 13, weight: .regular, design: .default))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(expanded ? 10 : 2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
    private func cleanForDisplay(_ text: String) -> String {
        let decorSymbols = CharacterSet(charactersIn: "⏺●✻✳✢✔✓✗⚡⚠◆◇◈◉○◎◐◑◒◓⏵⏴▶◀►◄▲▼▸▹▾▿⟦⟧⌁⌂⌃⌄⌇✦✧✩✪✫✶✴✷✸✹✺✻★☆")
        let dropSymbols = CharacterSet(charactersIn: "⎿⊢⊣⊤⊥")
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            // Drop tool-result lines
            if let first = s.unicodeScalars.first, dropSymbols.contains(first) { continue }
            // Strip decoration symbols from start
            while let first = s.unicodeScalars.first, decorSymbols.contains(first) {
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if s.isEmpty { continue }
            // Skip tool calls like "Read(file.txt)"
            if s.range(of: #"^[A-Z][A-Za-z]*\("#, options: .regularExpression) != nil { continue }
            // Skip status lines with · and tokens/context
            let low = s.lowercased()
            if s.contains("·") && (low.contains("tokens") || low.contains("context") || low.contains("shortcuts")) { continue }
            // Skip file paths
            if s.range(of: #"^/?[\w./-]+\.\w+(:\d+)?$"#, options: .regularExpression) != nil { continue }
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
        if joined.count > 300 {
            return String(joined.prefix(300)) + "..."
        }
        return joined
    }
}
