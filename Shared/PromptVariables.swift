import Foundation

/// The values the Mac offers for `PromptTemplate` placeholders when it pastes
/// a prompt into a window (Q-34b). Pure apart from the `clipboard` closure, so
/// the rules are tested without a window or a pasteboard.
///
/// Only names the body actually uses are produced, so the pasteboard is read
/// only for a prompt that asks for `{{clipboard}}`. A value that is unknown or
/// empty is left out, so its placeholder stays literal rather than vanishing.
enum PromptVariables {
    /// Every name this builder can fill. The phone may show these as hints.
    static let supported = ["folder", "window", "agent", "cwd", "date", "clipboard"]

    static func values(
        for body: String,
        folder: String,
        windowName: String,
        agent: String,
        cwd: String?,
        now: Date,
        timeZone: TimeZone = .current,
        clipboard: () -> String?
    ) -> [String: String] {
        var out: [String: String] = [:]
        for name in PromptTemplate.variables(in: body) {
            let value: String?
            switch name {
            case "folder": value = folder
            case "window": value = windowName
            case "agent": value = agent
            case "cwd": value = cwd
            case "date": value = dateString(now, timeZone: timeZone)
            case "clipboard": value = clipboard()
            default: value = nil
            }
            if let value, !value.isEmpty { out[name] = value }
        }
        return out
    }

    private static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
