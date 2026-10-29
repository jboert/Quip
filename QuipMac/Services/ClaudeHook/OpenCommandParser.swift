import Foundation

/// Finds the files a shell command opens with `open` (Q-87). Compiled into
/// both Quip and the `quip-claude-hook` helper, so it imports Foundation only.
///
/// It reads the command text Claude ran, nothing more: a file opened by a
/// script the command calls, or named through a variable, is not found. That
/// is deliberate. The only way onto the phone is a path the hook can see in
/// the command, so a Preview window Claude did not open never gets there.
enum OpenCommandParser {
    /// One argument to an `open` invocation, before it touches the disk.
    struct Argument: Equatable {
        /// Unquoted text, escapes removed.
        var text: String
        /// Contains `$` or a backtick outside single quotes, so the shell would
        /// have expanded it to something the hook cannot know.
        var needsExpansion: Bool
        /// Contains `*`, `?` or `[` outside quotes, so the shell would glob it.
        var isGlob: Bool
    }

    struct Result: Equatable {
        var paths: [String] = []
        /// Arguments dropped because they needed shell expansion.
        var skippedExpansion = 0
        /// Arguments that named no previewable file (missing, a directory,
        /// a URL, another file type).
        var skippedOther = 0
    }

    /// File types the phone can show.
    static let previewableExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "webp", "pdf",
    ]

    /// `open` options whose next word is their value, not a file.
    private static let valueOptions: Set<String> = [
        "-a", "-b", "-s", "-u", "--env", "--stdin", "--stdout", "--stderr",
    ]

    /// Cheap pre-check for the hook's fast path: false means the command
    /// cannot contain an `open` invocation, so nothing needs parsing.
    static func mightOpen(_ command: String) -> Bool {
        command.contains("open")
    }

    /// The arguments of every `open` invocation in `command`, in order.
    static func openArguments(in command: String) -> [Argument] {
        var out: [Argument] = []
        for segment in segments(of: command) {
            var words = segment[...]
            // Leading `VAR=value` assignments, `env`, and the owner's `rtk`
            // command rewriter (PreToolUse; `rtk proxy <cmd>` runs <cmd> raw)
            // don't change what runs.
            var afterRtk = false
            while let first = words.first {
                let isPrefix = first.text == "env" || first.text == "rtk"
                    || isAssignment(first.text) || (afterRtk && first.text == "proxy")
                guard isPrefix else { break }
                afterRtk = first.text == "rtk"
                words = words.dropFirst()
            }
            guard let command = words.first,
                  command.text == "open" || command.text == "/usr/bin/open" else { continue }
            var args: [Argument] = []
            var skipNext = false
            var reveal = false
            for word in words.dropFirst() {
                if skipNext { skipNext = false; continue }
                if word.text == "--args" { break }
                if word.text == "-R" || word.text == "--reveal" { reveal = true; continue }
                if valueOptions.contains(word.text) { skipNext = true; continue }
                if word.text.hasPrefix("-") && !word.needsExpansion { continue }
                args.append(word)
            }
            // `open -R` reveals in Finder; nothing is previewed.
            if !reveal { out.append(contentsOf: args) }
        }
        return out
    }

    /// The previewable files `command` opens, resolved against `cwd`.
    static func parse(_ command: String, cwd: String,
                      fileManager: FileManager = .default) -> Result {
        var result = Result()
        var seen = Set<String>()
        for arg in openArguments(in: command) {
            if arg.needsExpansion { result.skippedExpansion += 1; continue }
            let candidates = arg.isGlob ? glob(absolute(arg.text, cwd: cwd)) : [absolute(arg.text, cwd: cwd)]
            var found = false
            for path in candidates where isPreviewableFile(path, fileManager: fileManager) {
                found = true
                if seen.insert(path).inserted { result.paths.append(path) }
            }
            if !found { result.skippedOther += 1 }
        }
        return result
    }

    // MARK: - Paths

    static func absolute(_ text: String, cwd: String) -> String {
        var path = text
        if path == "~" {
            path = NSHomeDirectory()
        } else if path.hasPrefix("~/") {
            path = NSHomeDirectory() + String(path.dropFirst(1))
        } else if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            path = url.path
        }
        if !path.hasPrefix("/") {
            path = (cwd as NSString).appendingPathComponent(path)
        }
        return (path as NSString).standardizingPath
    }

    static func isPreviewableFile(_ path: String, fileManager: FileManager) -> Bool {
        guard previewableExtensions.contains((path as NSString).pathExtension.lowercased()) else { return false }
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    private static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_matchc)).compactMap { i in
            g.gl_pathv[i].flatMap { String(cString: $0) }
        }.sorted()
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        return word[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - Tokenizer

    /// Splits `command` into simple commands (on `&&`, `||`, `;`, `|`, `&`,
    /// newlines and parentheses outside quotes), each a list of words with
    /// quotes removed. A word that came from inside quotes is never an
    /// operator: `echo "a && open b"` is one command, and `open` inside a
    /// quoted string is an argument to `echo`, not an invocation.
    static func segments(of command: String) -> [[Argument]] {
        var segments: [[Argument]] = []
        var words: [Argument] = []
        var word = Argument(text: "", needsExpansion: false, isGlob: false)
        var inWord = false
        var quote: Character? = nil
        var escaped = false

        func endWord() {
            if inWord { words.append(word) }
            word = Argument(text: "", needsExpansion: false, isGlob: false)
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }

        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            defer { i += 1 }
            if escaped {
                word.text.append(c); inWord = true; escaped = false
                continue
            }
            if let q = quote {
                if c == q { quote = nil; continue }
                if q == "\"" && c == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                    escaped = true; continue
                }
                if q == "\"" && (c == "$" || c == "`") { word.needsExpansion = true }
                word.text.append(c)
                continue
            }
            switch c {
            case "\\":
                if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1; continue } // line continuation
                escaped = true; inWord = true
            case "'", "\"":
                quote = c; inWord = true
            case " ", "\t":
                endWord()
            case "\n", ";", "&", "|", "(", ")":
                endSegment()
            case "#" where !inWord:
                // Comment to end of line.
                while i + 1 < chars.count, chars[i + 1] != "\n" { i += 1 }
            default:
                if c == "$" || c == "`" { word.needsExpansion = true }
                if c == "*" || c == "?" || c == "[" { word.isGlob = true }
                word.text.append(c); inWord = true
            }
        }
        endSegment()
        return segments
    }
}
