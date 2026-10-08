import Foundation

/// A piece of text an item can be found by, and what kind of text it is. The
/// kind sets what a match is worth: a word in a prompt's name says more than
/// the same word deep in its body.
struct QuipSearchField: Equatable, Sendable {
    enum Kind: Int, CaseIterable, Sendable {
        case name, id, tag, agent, description, body

        /// Lower is better. A whole-word hit in the body (70) still loses to a
        /// typo-tolerant hit in the name (10 + 40).
        var baseScore: Int {
            switch self {
            case .name: return 10
            case .id: return 40
            case .tag: return 42
            case .agent: return 44
            case .description: return 60
            case .body: return 70
            }
        }
    }

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Anything the phone lists for the user to pick from: prompts, quick
/// buttons, slash commands.
protocol QuipSearchable {
    var searchFields: [QuipSearchField] { get }
}

/// The phone's one search engine (PRD broadcast-and-search, US-101).
///
/// Every word of the query must match some field of an item (AND), in any
/// order, ignoring case and accents. Per word the best of four match kinds
/// wins: whole word, start of a word, anywhere in a word, or a close match
/// (one edit for words of 4–7 characters, two for 8 or more, none below 4; a
/// close match in body text must also share the first letter). Results are
/// ordered by a phrase tier (exact name, exact id, name starts with the query),
/// then by the weakest word's score, so one strong hit cannot carry an
/// unrelated second word, then by total score, then by input order — callers
/// pass items already in their preferred order (frecency for prompts).
///
/// Modelled on VibeCut's launcher matcher and reimplemented here; no VibeCut
/// code is copied.
enum QuipSearch {
    enum MatchKind: Int, Comparable, Sendable {
        case wholeWord, prefix, substring, fuzzy

        var offset: Int {
            switch self {
            case .wholeWord: return 0
            case .prefix: return 10
            case .substring: return 20
            case .fuzzy: return 40
            }
        }

        static func < (lhs: MatchKind, rhs: MatchKind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How one query word matched one item.
    struct WordMatch: Equatable, Sendable {
        /// The query word, folded.
        let token: String
        let field: QuipSearchField.Kind
        let kind: MatchKind
        /// The item's word that matched, folded.
        let matchedWord: String
        let score: Int
    }

    struct Hit<Item> {
        let item: Item
        /// Position in the input, the final tie-break.
        let index: Int
        /// The caller's order for equally good matches (frecency for
        /// prompts); lower first. The input position when none was given.
        let rank: Int
        /// 0 exact name, 1 exact id, 2 name starts with the query, 3 otherwise.
        let phraseTier: Int
        let matches: [WordMatch]
        let weakestScore: Int
        let totalScore: Int

        init(item: Item, index: Int, rank: Int, phraseTier: Int, matches: [WordMatch]) {
            self.item = item
            self.index = index
            self.rank = rank
            self.phraseTier = phraseTier
            self.matches = matches
            weakestScore = matches.map(\.score).max() ?? 0
            totalScore = matches.reduce(0) { $0 + $1.score }
        }

        /// A short reason for the row, or nil when there is no query.
        var explanation: String? {
            guard !matches.isEmpty else { return nil }
            switch phraseTier {
            case 0: return "Exact name"
            case 1: return "Exact id"
            case 2: return "Name starts with"
            default: break
            }
            if let closeMatch { return closeMatch }
            let weakest = matches.max { $0.score < $1.score }!
            switch weakest.field {
            case .name: return "In name"
            case .id: return "In id"
            case .tag: return "In tags"
            case .agent: return "Agent"
            case .description: return "In description"
            case .body: return "In prompt text"
            }
        }

        /// "Close match: comimt → commit" when a query word was found only with
        /// a typo, else nil.
        var closeMatch: String? {
            matches.first { $0.kind == .fuzzy }.map { "Close match: \($0.token) → \($0.matchedWord)" }
        }

        /// The word to centre a body excerpt on: set only when nothing matched
        /// in the name, so the row's usual preview would not show why it is here.
        var excerptWord: String? {
            guard !matches.contains(where: { $0.field == .name }) else { return nil }
            return matches.first(where: { $0.field == .body })?.matchedWord
        }
    }

    /// The items plus every distinct word across them, each with the items
    /// and fields it occurs in. A keystroke scans the distinct words (a few
    /// thousand) instead of every word of every prompt body. Build the index
    /// when the list changes, not on every query.
    struct Index<Item: QuipSearchable> {
        let items: [Item]
        fileprivate let fields: [[PreparedField]]
        fileprivate let vocabulary: Vocabulary

        init(_ items: [Item]) {
            self.items = items
            var fields: [[PreparedField]] = []
            fields.reserveCapacity(items.count)
            var postings: [String: [Posting]] = [:]
            for (itemIndex, item) in items.enumerated() {
                var prepared: [PreparedField] = []
                for field in item.searchFields {
                    let folded = QuipSearch.fold(field.text)
                    let words = QuipSearch.words(folded)
                    let posting = Posting(item: itemIndex, kind: field.kind)
                    for word in words {
                        // A word repeated in one field is listed once: this
                        // field's posting is always the latest one appended.
                        postings[word, default: []].appendUnlessLast(posting)
                    }
                    prepared.append(PreparedField(kind: field.kind, folded: folded, words: words))
                }
                fields.append(prepared)
            }
            self.fields = fields
            self.vocabulary = Vocabulary(postings)
        }

        /// Matching items, best first. `rank` gives the caller's order for
        /// equally good matches, one value per item, lower first; without it,
        /// or for a missing value, the input order decides.
        func search(_ query: String, rank: [Int]? = nil) -> [Hit<Item>] {
            func rankOf(_ index: Int) -> Int {
                guard let rank, rank.indices.contains(index) else { return index }
                return rank[index]
            }
            let tokens = QuipSearch.tokens(query)
            guard !tokens.isEmpty else {
                let all = items.enumerated().map { Hit(item: $1, index: $0, rank: rankOf($0), phraseTier: 3, matches: []) }
                guard rank != nil else { return all }
                return all.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
            }
            let perToken = tokens.map(bestMatches)
            let phrase = QuipSearch.Phrase(tokens)
            var hits: [Hit<Item>] = []
            itemLoop: for index in items.indices {
                var matches: [WordMatch] = []
                matches.reserveCapacity(tokens.count)
                for best in perToken {
                    guard let match = best[index] else { continue itemLoop }
                    matches.append(match)
                }
                hits.append(Hit(item: items[index], index: index, rank: rankOf(index),
                                phraseTier: phrase.tier(fields[index]), matches: matches))
            }
            hits.sort { a, b in
                if a.phraseTier != b.phraseTier { return a.phraseTier < b.phraseTier }
                if a.weakestScore != b.weakestScore { return a.weakestScore < b.weakestScore }
                if a.totalScore != b.totalScore { return a.totalScore < b.totalScore }
                if a.rank != b.rank { return a.rank < b.rank }
                return a.index < b.index
            }
            return hits
        }

        /// The best match of one query word in each item, nil where it has none.
        private func bestMatches(for token: String) -> [WordMatch?] {
            var best = [WordMatch?](repeating: nil, count: items.count)
            // Items already matched without a typo; the close-match pass
            // leaves them alone and is skipped once every item is one.
            var exact = [Bool](repeating: false, count: items.count)
            var exactCount = 0
            func offer(_ item: Int, _ field: QuipSearchField.Kind, _ kind: MatchKind, _ word: String, extra: Int = 0) {
                if kind != .fuzzy, !exact[item] {
                    exact[item] = true
                    exactCount += 1
                }
                let score = field.baseScore + kind.offset + extra
                if let current = best[item] {
                    if current.score < score { return }
                    // Equal scores: the shorter word, then the alphabetically
                    // first, so the word an excerpt or explanation names does
                    // not depend on dictionary order.
                    if current.score == score {
                        let shorter = word.utf8.count < current.matchedWord.utf8.count
                        let sameLength = word.utf8.count == current.matchedWord.utf8.count
                        guard shorter || (sameLength && word < current.matchedWord) else { return }
                    }
                }
                best[item] = WordMatch(token: token, field: field, kind: kind, matchedWord: word, score: score)
            }

            let query = QuipSearch.scalars(token)
            let vocabulary = self.vocabulary

            // Whole word, start of a word, inside a word. A one-letter query
            // only matches whole words and word starts; "a" inside every word
            // is noise.
            vocabulary.forEachMatch(of: query, allowInside: query.count >= 2) { entry, kind in
                let word = vocabulary.words[entry]
                for posting in vocabulary.postings[entry] {
                    offer(posting.item, posting.kind, kind, word)
                }
            }

            // A query word with punctuation inside ("ship-it") never equals one
            // of the split words; look for it as written in the short fields.
            if token.unicodeScalars.contains(where: { !QuipSearch.isWordScalar($0) }) {
                for (itemIndex, prepared) in fields.enumerated() {
                    for field in prepared where field.kind != .body && field.folded.contains(token) {
                        offer(itemIndex, field.kind, .substring, token)
                    }
                }
            }

            // Close matches, only for items where the word was not found at
            // all, and in body text only when the first letter agrees.
            guard exactCount < items.count, let budget = QuipSearch.typoBudget(token) else { return best }
            var distances = EditDistance(query, limit: budget)
            vocabulary.forEachCloseCandidate(of: query, budget: budget) { entry, scalars, sameFirst in
                var distance: Int??
                for posting in vocabulary.postings[entry] {
                    if exact[posting.item] { continue }
                    if posting.kind == .body, !sameFirst { continue }
                    if distance == nil {
                        distance = .some(distances.distance(to: scalars))
                    }
                    guard let found = distance ?? nil else { break }
                    offer(posting.item, posting.kind, .fuzzy, vocabulary.words[entry], extra: found - 1)
                }
            }
            return best
        }
    }

    fileprivate struct Posting: Equatable {
        let item: Int
        let kind: QuipSearchField.Kind
    }

    /// Every distinct word, its Unicode scalars stored back to back in one
    /// buffer. Matching compares integers through a pointer, which keeps a
    /// keystroke fast even in a debug build, where `String` and `Character`
    /// comparisons cost far more.
    fileprivate struct Vocabulary {
        private(set) var words: [String] = []
        private(set) var postings: [[Posting]] = []
        /// True when a word occurs only in body text, where a close match
        /// must share the first letter.
        private var onlyInBody: [Bool] = []
        private var scalars: [UInt32] = []
        /// Word `i` is `scalars[starts[i]..<starts[i + 1]]`.
        private var starts: [Int] = [0]

        var count: Int { words.count }

        init(_ table: [String: [Posting]]) {
            words.reserveCapacity(table.count)
            postings.reserveCapacity(table.count)
            onlyInBody.reserveCapacity(table.count)
            starts.reserveCapacity(table.count + 1)
            for (word, list) in table {
                words.append(word)
                postings.append(list)
                onlyInBody.append(list.allSatisfy { $0.kind == .body })
                scalars.append(contentsOf: word.unicodeScalars.lazy.map(\.value))
                starts.append(scalars.count)
            }
        }

        /// Calls `body` with every word that contains `query`, and how: the
        /// whole word, its start, or (when `allowInside`) anywhere inside it.
        func forEachMatch(of query: [UInt32], allowInside: Bool, _ body: (_ entry: Int, _ kind: MatchKind) -> Void) {
            scalars.withUnsafeBufferPointer { all in
                starts.withUnsafeBufferPointer { starts in
                    query.withUnsafeBufferPointer { q in
                        let wanted = q.count
                        var entry = 0
                        while entry < starts.count - 1 {
                            defer { entry += 1 }
                            let start = starts[entry], end = starts[entry + 1]
                            let length = end - start
                            guard wanted <= length else { continue }
                            var i = 0
                            while i < wanted, all[start + i] == q[i] { i += 1 }
                            if i == wanted {
                                body(entry, length == wanted ? .wholeWord : .prefix)
                                continue
                            }
                            guard allowInside else { continue }
                            var offset = start + 1
                            while offset <= end - wanted {
                                if all[offset] == q[0] {
                                    var j = 1
                                    while j < wanted, all[offset + j] == q[j] { j += 1 }
                                    if j == wanted {
                                        body(entry, .substring)
                                        break
                                    }
                                }
                                offset += 1
                            }
                        }
                    }
                }
            }
        }

        /// Calls `body` with every word that could be within `budget` edits of
        /// `query`, after the cheap tests: its length, and its first letter
        /// when it occurs only in body text. `sameFirst` tells the caller
        /// whether body postings of a mixed word qualify.
        func forEachCloseCandidate(of query: [UInt32], budget: Int,
                                   _ body: (_ entry: Int, _ scalars: UnsafeBufferPointer<UInt32>, _ sameFirst: Bool) -> Void) {
            let first = query[0]
            scalars.withUnsafeBufferPointer { all in
                starts.withUnsafeBufferPointer { starts in
                    onlyInBody.withUnsafeBufferPointer { onlyInBody in
                        var entry = 0
                        while entry < starts.count - 1 {
                            defer { entry += 1 }
                            let start = starts[entry], end = starts[entry + 1]
                            let difference = end - start - query.count
                            guard difference <= budget, -difference <= budget else { continue }
                            let sameFirst = all[start] == first
                            guard sameFirst || !onlyInBody[entry] else { continue }
                            body(entry, UnsafeBufferPointer(rebasing: all[start..<end]), sameFirst)
                        }
                    }
                }
            }
        }
    }

    /// Optimal-string-alignment distance (insert, delete, substitute, swap two
    /// neighbours) from one query word to many candidates, reusing its rows.
    fileprivate struct EditDistance {
        private let query: [UInt32]
        private let limit: Int
        private var rows: [Int]

        init(_ query: [UInt32], limit: Int) {
            self.query = query
            self.limit = limit
            rows = [Int](repeating: 0, count: 3 * (query.count + 1))
        }

        /// The distance, or nil once it must exceed the limit.
        mutating func distance(to word: UnsafeBufferPointer<UInt32>) -> Int? {
            let limit = self.limit
            return query.withUnsafeBufferPointer { q in
                rows.withUnsafeMutableBufferPointer { rows in
                    QuipSearch.osaDistance(word, q, limit: limit, rows: rows)
                }
            }
        }
    }

    /// `a` runs down the rows and `b` across them; `rows` holds three rows of
    /// `b.count + 1` cells.
    fileprivate static func osaDistance(_ a: UnsafeBufferPointer<UInt32>, _ b: UnsafeBufferPointer<UInt32>,
                                        limit: Int, rows: UnsafeMutableBufferPointer<Int>) -> Int? {
        let difference = a.count > b.count ? a.count - b.count : b.count - a.count
        if difference > limit { return nil }
        if a.isEmpty || b.isEmpty { return difference }
        let width = b.count + 1
        var beforePrevious = 0, previous = width, current = 2 * width
        var j = 0
        while j < width { rows[previous + j] = j; j += 1 }
        var i = 1
        while i <= a.count {
            rows[current] = i
            var rowMinimum = i
            let ai = a[i - 1]
            j = 1
            while j < width {
                let bj = b[j - 1]
                var value = rows[previous + j - 1] + (ai == bj ? 0 : 1)
                let deletion = rows[previous + j] + 1
                if deletion < value { value = deletion }
                let insertion = rows[current + j - 1] + 1
                if insertion < value { value = insertion }
                if i > 1, j > 1, ai == b[j - 2], a[i - 2] == bj {
                    let swap = rows[beforePrevious + j - 2] + 1
                    if swap < value { value = swap }
                }
                rows[current + j] = value
                if value < rowMinimum { rowMinimum = value }
                j += 1
            }
            if rowMinimum > limit { return nil }
            (beforePrevious, previous, current) = (previous, current, beforePrevious)
            i += 1
        }
        let distance = rows[previous + b.count]
        return distance <= limit ? distance : nil
    }

    /// Edit distance between two words, or nil once it must exceed `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int? {
        let a = scalars(a), b = scalars(b)
        var rows = [Int](repeating: 0, count: 3 * (b.count + 1))
        return a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                rows.withUnsafeMutableBufferPointer { osaDistance(a, b, limit: limit, rows: $0) }
            }
        }
    }

    /// One-shot search for short lists; build an `Index` for long ones.
    static func search<Item: QuipSearchable>(_ items: [Item], query: String, rank: [Int]? = nil) -> [Hit<Item>] {
        Index(items).search(query, rank: rank)
    }

    // MARK: - Text handling

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    /// Query words, folded, with punctuation trimmed from their ends, so
    /// "/compact" searches for "compact" and "ship-it" stays one word.
    static func tokens(_ query: String) -> [String] {
        let trim = CharacterSet.punctuationCharacters.union(.symbols)
        return fold(query)
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: trim) }
            .filter { !$0.isEmpty }
    }

    fileprivate static func scalars(_ text: String) -> [UInt32] {
        text.unicodeScalars.map(\.value)
    }

    /// Letters, digits and the marks that belong to them; everything else
    /// separates words.
    fileprivate static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 {
            return (value >= 0x61 && value <= 0x7A) || (value >= 0x30 && value <= 0x39)
                || (value >= 0x41 && value <= 0x5A)
        }
        let properties = scalar.properties
        if properties.isAlphabetic || properties.numericType != nil { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// The words of folded text. Reads UTF-8 directly and decodes a scalar
    /// only for non-ASCII bytes, since nearly all prompt text is ASCII.
    fileprivate static func words(_ folded: String) -> [String] {
        var text = folded
        return text.withUTF8 { bytes in
            var words: [String] = []
            var wordStart = -1
            var i = 0
            while i < bytes.count {
                let byte = bytes[i]
                var width = 1
                let isWord: Bool
                if byte < 0x80 {
                    isWord = (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                        || (byte >= 0x41 && byte <= 0x5A)
                } else {
                    width = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                    var decoder = UTF8()
                    var iterator = UnsafeBufferPointer(rebasing: bytes[i..<min(i + width, bytes.count)]).makeIterator()
                    if case .scalarValue(let scalar) = decoder.decode(&iterator) {
                        isWord = isWordScalar(scalar)
                    } else {
                        isWord = false
                    }
                }
                if isWord {
                    if wordStart < 0 { wordStart = i }
                } else if wordStart >= 0 {
                    words.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[wordStart..<i]), as: UTF8.self))
                    wordStart = -1
                }
                i += width
            }
            if wordStart >= 0 {
                words.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[wordStart...]), as: UTF8.self))
            }
            return words
        }
    }

    fileprivate struct PreparedField {
        let kind: QuipSearchField.Kind
        /// Folded text, kept for short fields only: the punctuation pass and
        /// the phrase tier never look at the body.
        let folded: String
        /// The field's words joined by single spaces, for the phrase tier.
        let phrase: String

        init(kind: QuipSearchField.Kind, folded: String, words: [String]) {
            self.kind = kind
            let short = kind != .body
            self.folded = short ? folded : ""
            self.phrase = short ? words.joined(separator: " ") : ""
        }
    }

    /// The query as the phrase tier compares it: its words joined by single
    /// spaces, and as typed (folded) for an id with punctuation inside.
    fileprivate struct Phrase {
        let typed: String
        let words: String

        init(_ tokens: [String]) {
            typed = tokens.joined(separator: " ")
            words = QuipSearch.words(typed).joined(separator: " ")
        }

        /// 0 exact name, 1 exact id, 2 name starts with the query, 3 otherwise.
        func tier(_ fields: [PreparedField]) -> Int {
            guard !words.isEmpty else { return 3 }
            if fields.contains(where: { $0.kind == .name && $0.phrase == words }) { return 0 }
            if fields.contains(where: { $0.kind == .id && ($0.folded == typed || $0.phrase == words) }) { return 1 }
            if fields.contains(where: { $0.kind == .name && $0.phrase.hasPrefix(words) }) { return 2 }
            return 3
        }
    }

    /// Edits allowed for a query word, or nil when it is too short to guess at.
    static func typoBudget(_ token: String) -> Int? {
        switch token.unicodeScalars.count {
        case ..<4: return nil
        case 4...7: return 1
        default: return 2
        }
    }

    // MARK: - Excerpts

    /// About `width` characters of `text` around the first occurrence of
    /// `word` (matched ignoring case and accents), on one line, with "…" where
    /// it was cut. Nil when the word is not in the text.
    static func excerpt(of text: String, around word: String, width: Int = 64) -> String? {
        guard !word.isEmpty,
              let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let radius = max(8, (width - word.count) / 2)
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let flat = text[start..<end]
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + flat + (end < text.endIndex ? "…" : "")
    }
}

private extension Array where Element: Equatable {
    mutating func appendUnlessLast(_ element: Element) {
        if last != element { append(element) }
    }
}
