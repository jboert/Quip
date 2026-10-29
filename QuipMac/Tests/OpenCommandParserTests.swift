import XCTest
@testable import Quip

final class OpenCommandParserTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("OpenCommandParserTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir + "/sub dir", withIntermediateDirectories: true)
        for name in ["shot.png", "b.pdf", "notes.txt", "sub dir/two words.jpg", "g1.png", "g2.png"] {
            FileManager.default.createFile(atPath: dir + "/" + name, contents: Data([0]))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func paths(_ command: String) -> [String] {
        OpenCommandParser.parse(command, cwd: dir).paths.map { ($0 as NSString).lastPathComponent }
    }

    func test_plainOpen() {
        XCTAssertEqual(paths("open shot.png"), ["shot.png"])
    }

    func test_appOptionValueIsNotAFile() {
        XCTAssertEqual(paths("open -a Preview shot.png b.pdf"), ["shot.png", "b.pdf"])
    }

    func test_chainAfterScreenshot() {
        XCTAssertEqual(paths("xcrun simctl io booted screenshot shot.png && open shot.png"), ["shot.png"])
    }

    func test_quotedPathWithSpaces() {
        XCTAssertEqual(paths("open \"sub dir/two words.jpg\""), ["two words.jpg"])
        XCTAssertEqual(paths("open sub\\ dir/two\\ words.jpg"), ["two words.jpg"])
    }

    func test_absolutePath() {
        XCTAssertEqual(paths("open \(dir!)/shot.png"), ["shot.png"])
    }

    func test_globExpands() {
        XCTAssertEqual(paths("open g*.png"), ["g1.png", "g2.png"])
    }

    func test_quotedGlobIsLiteral() {
        XCTAssertEqual(paths("open 'g*.png'"), [])
    }

    func test_variableIsSkippedAndCounted() {
        let r = OpenCommandParser.parse("OUT=shot.png; open \"$OUT\"", cwd: dir)
        XCTAssertEqual(r.paths, [])
        XCTAssertEqual(r.skippedExpansion, 1)
    }

    func test_singleQuotedDollarIsLiteral() {
        let r = OpenCommandParser.parse("open '$OUT'", cwd: dir)
        XCTAssertEqual(r.skippedExpansion, 0)
        XCTAssertEqual(r.skippedOther, 1)
    }

    func test_urlIsDropped() {
        XCTAssertEqual(paths("open https://example.com/shot.png"), [])
    }

    func test_rtkPrefixesAreStripped() {
        XCTAssertEqual(paths("rtk open shot.png"), ["shot.png"])
        XCTAssertEqual(paths("rtk proxy open shot.png"), ["shot.png"])
    }

    func test_envAndAssignmentsAreStripped() {
        XCTAssertEqual(paths("env FOO=1 open shot.png"), ["shot.png"])
        XCTAssertEqual(paths("FOO=1 open shot.png"), ["shot.png"])
    }

    func test_openAsAnArgumentIsNotAnInvocation() {
        XCTAssertEqual(paths("echo open shot.png"), [])
        XCTAssertEqual(paths("echo \"x && open shot.png\""), [])
        XCTAssertEqual(paths("git commit -m 'open shot.png'"), [])
    }

    func test_nonPreviewableTypeIsDropped() {
        XCTAssertEqual(paths("open notes.txt"), [])
    }

    func test_missingFileIsDropped() {
        XCTAssertEqual(paths("open nope.png"), [])
    }

    func test_revealInFinderIsNotAPreview() {
        XCTAssertEqual(paths("open -R shot.png"), [])
    }

    func test_argsAfterDashDashArgsAreForTheApp() {
        XCTAssertEqual(paths("open -a Foo --args shot.png"), [])
    }

    func test_sameFileTwiceIsReportedOnce() {
        XCTAssertEqual(paths("open shot.png shot.png"), ["shot.png"])
    }

    func test_commentIsIgnored() {
        XCTAssertEqual(paths("ls # open shot.png"), [])
    }

    func test_fastPath() {
        XCTAssertFalse(OpenCommandParser.mightOpen("ls -la"))
        XCTAssertTrue(OpenCommandParser.mightOpen("open x.png"))
    }
}
