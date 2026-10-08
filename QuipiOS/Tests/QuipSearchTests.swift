import XCTest
@testable import Quip

/// PRD broadcast-and-search US-101: the phone's one search engine.
final class QuipSearchTests: XCTestCase {

    private struct Item: QuipSearchable {
        let id: String
        let label: String
        let body: String
        var tags: [String] = []

        var searchFields: [QuipSearchField] {
            [QuipSearchField(.name, label), QuipSearchField(.id, id)]
                + tags.map { QuipSearchField(.tag, $0) }
                + [QuipSearchField(.body, body)]
        }
    }

    private func ids(_ items: [Item], _ query: String) -> [String] {
        QuipSearch.search(items, query: query).map(\.item.id)
    }

    private let ship = Item(id: "ship-it", label: "Ship it", body: "Commit, then push the branch and open a PR.")
    private let commit = Item(id: "commit", label: "Commit", body: "Write a focused commit message.")
    private let cafe = Item(id: "cafe", label: "Café review", body: "Review the menu.")
    private let tagged = Item(id: "tagged", label: "Tagged one", body: "nothing here", tags: ["release"])
    private var library: [Item] { [ship, commit, cafe, tagged] }

    func test_wordsMatchInAnyOrderAcrossFields() {
        XCTAssertEqual(ids(library, "ship push"), ["ship-it"])
        XCTAssertEqual(ids(library, "push ship"), ["ship-it"])
    }

    func test_everyWordMustMatch() {
        XCTAssertTrue(ids(library, "ship banana").isEmpty)
    }

    func test_oneTypoIsForgivenInWordsOfFourOrMore() {
        let hits = QuipSearch.search(library, query: "comimt")
        XCTAssertEqual(hits.first?.item.id, "commit")
        XCTAssertEqual(hits.first?.explanation, "Close match: comimt → commit")
    }

    func test_noTypoBudgetBelowFourCharacters() {
        XCTAssertTrue(ids([Item(id: "x", label: "ab", body: "")], "ac").isEmpty)
        XCTAssertNil(QuipSearch.typoBudget("abc"))
        XCTAssertEqual(QuipSearch.typoBudget("abcd"), 1)
        XCTAssertEqual(QuipSearch.typoBudget("abcdefgh"), 2)
    }

    func test_caseAndAccentsAreIgnored() {
        XCTAssertEqual(ids(library, "cafe"), ["cafe"])
        XCTAssertEqual(ids(library, "CAFÉ"), ["cafe"])
    }

    func test_aNameHitOutranksABodyHit() {
        // "commit" is the name of one prompt and a body word of another.
        let hits = QuipSearch.search(library, query: "commit")
        XCTAssertEqual(hits.map(\.item.id), ["commit", "ship-it"])
        XCTAssertEqual(hits.first?.explanation, "Exact name")
    }

    func test_exactIdOutranksNamePrefix() {
        let byID = Item(id: "deploy", label: "Something", body: "")
        let byPrefix = Item(id: "zzz", label: "Deployment", body: "")
        XCTAssertEqual(ids([byPrefix, byID], "deploy"), ["deploy", "zzz"])
    }

    func test_equalScoresKeepInputOrder() {
        let first = Item(id: "t2", label: "alpha two", body: "")
        let second = Item(id: "t1", label: "alpha one", body: "")
        XCTAssertEqual(ids([first, second], "alpha"), ["t2", "t1"])
    }

    func test_aCallerRankBreaksTiesBeforeInputOrder() {
        let first = Item(id: "a", label: "alpha one", body: "")
        let second = Item(id: "b", label: "alpha two", body: "")
        XCTAssertEqual(QuipSearch.search([first, second], query: "alpha", rank: [1, 0]).map(\.item.id), ["b", "a"])
        // Rank never beats relevance: "two" matches only the second item.
        XCTAssertEqual(QuipSearch.search([first, second], query: "two", rank: [0, 1]).map(\.item.id), ["b"])
        // A rank of the wrong length is ignored rather than trusted.
        XCTAssertEqual(QuipSearch.search([first, second], query: "alpha", rank: [1]).map(\.item.id), ["a", "b"])
    }

    func test_anEmptyQueryFollowsTheCallerRank() {
        XCTAssertEqual(QuipSearch.search(library, query: "", rank: [3, 2, 1, 0]).map(\.item.id),
                       library.reversed().map(\.id))
    }

    func test_closeMatchIsSetOnlyForATypo() {
        XCTAssertEqual(QuipSearch.search(library, query: "comimt").first?.closeMatch, "Close match: comimt → commit")
        XCTAssertNil(QuipSearch.search(library, query: "commit").first?.closeMatch)
    }

    func test_anEmptyOrPunctuationOnlyQueryReturnsEverythingInOrder() {
        XCTAssertEqual(ids(library, "   "), library.map(\.id))
        XCTAssertEqual(ids(library, " - / "), library.map(\.id))
        XCTAssertNil(QuipSearch.search(library, query: "").first?.explanation)
    }

    func test_tagsAreSearched() {
        let hits = QuipSearch.search(library, query: "release")
        XCTAssertEqual(hits.map(\.item.id), ["tagged"])
        XCTAssertEqual(hits.first?.explanation, "In tags")
    }

    func test_slashCommandsMatchWithoutTheSlash() {
        XCTAssertEqual(ids([Item(id: "compact", label: "/compact", body: "")], "/comp"), ["compact"])
    }

    func test_aWordWithInnerPunctuationMatchesTheIdAsWritten() {
        XCTAssertEqual(ids(library, "ship-it"), ["ship-it"])
    }

    func test_weakestWordDecidesTheOrder() {
        // One strong hit ("Ship" is the name) must not carry a second word
        // that only appears deep in the body.
        let strongAndWeak = Item(id: "s1", label: "Ship", body: "nothing about the other word here except release")
        let bothInName = Item(id: "s2", label: "release ship notes", body: "")
        XCTAssertEqual(ids([strongAndWeak, bothInName], "ship release").first, "s2")
    }

    func test_bodyOnlyMatchGivesAnExcerptWord() {
        let deep = Item(id: "deep", label: "Deep body",
                        body: String(repeating: "lorem ipsum dolor ", count: 100) + "zebra crossing")
        let hit = QuipSearch.search([deep], query: "zebra").first
        XCTAssertEqual(hit?.excerptWord, "zebra")
        XCTAssertNil(QuipSearch.search([deep], query: "deep").first?.excerptWord,
                     "a name match needs no excerpt")
    }

    func test_excerptCentresOnTheMatchAndStaysShort() throws {
        let body = String(repeating: "lorem ipsum dolor ", count: 100) + "zebra crossing"
        let excerpt = try XCTUnwrap(QuipSearch.excerpt(of: body, around: "zebra"))
        XCTAssertTrue(excerpt.contains("zebra"))
        XCTAssertTrue(excerpt.hasPrefix("…"))
        XCTAssertLessThan(excerpt.count, 70)
        XCTAssertNil(QuipSearch.excerpt(of: body, around: "giraffe"))
    }

    func test_excerptFlattensNewlines() throws {
        let excerpt = try XCTUnwrap(QuipSearch.excerpt(of: "line one\nline two\n\nzebra", around: "zebra"))
        XCTAssertFalse(excerpt.contains("\n"))
    }

    func test_editDistance() {
        XCTAssertEqual(QuipSearch.editDistance("comimt", "commit", limit: 1), 1, "a swap is one edit")
        XCTAssertEqual(QuipSearch.editDistance("abcd", "abcd", limit: 1), 0)
        XCTAssertNil(QuipSearch.editDistance("kitten", "sitting", limit: 2))
    }

    func test_wordsSplitAtNonASCIIPunctuation() {
        let item = Item(id: "dash", label: "Dashes", body: "alpha—beta…gamma → delta “quoted”")
        for word in ["beta", "gamma", "delta", "quoted"] {
            XCTAssertEqual(ids([item], word), ["dash"], word)
        }
    }

    func test_wordsInScriptsWithoutSpacesAreSearchable() {
        XCTAssertEqual(ids([Item(id: "jp", label: "日本語のテスト", body: "")], "日本語"), ["jp"])
    }

    func test_equalScoresNameTheShorterWord() {
        // "depl" starts both body words equally well; the word reported for
        // the excerpt must not depend on the order the index stores words in.
        let item = Item(id: "d", label: "Something", body: "deployment then deploy")
        XCTAssertEqual(QuipSearch.search([item], query: "depl").first?.excerptWord, "deploy")
    }

    func test_aLargeLibraryStaysFastEnoughToSearchPerKeystroke() {
        // 500 prompts of about 2 KB over 15,000 distinct words: several
        // times the size of a real library. Measured on the Mac in a debug
        // build: the slowest query takes about 3 ms. Each query's best of
        // three runs is kept, so a busy machine does not fail the test.
        var generator = SeededGenerator(seed: 42)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let vocabulary: [String] = (0..<15_000).map { _ in
            String((0..<Int.random(in: 3...11, using: &generator)).map { _ in
                letters.randomElement(using: &generator)!
            })
        }
        let items: [Item] = (0..<500).map { i in
            var body = ""
            while body.utf8.count < 2048 { body += vocabulary.randomElement(using: &generator)! + " " }
            return Item(id: "p\(i)", label: "Prompt \(i) \(vocabulary[i])", body: body)
        }
        let index = QuipSearch.Index(items)
        var slowest: TimeInterval = 0
        for query in ["dep", "commit review", "relese", "zzzzzzzz", "prompt 42", "a", "abcdefgh ijk"] {
            var best = TimeInterval.infinity
            for _ in 0..<3 {
                let start = Date()
                _ = index.search(query)
                best = min(best, Date().timeIntervalSince(start))
            }
            slowest = max(slowest, best)
        }
        XCTAssertLessThan(slowest, 0.05, "slowest query took \(Int(slowest * 1000)) ms")
    }
}

/// Deterministic generator so the performance test is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
