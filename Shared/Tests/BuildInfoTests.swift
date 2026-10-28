import XCTest
@testable import Quip

/// An installed build always names its commit, so "still 1.5.6" cannot happen
/// twice: the marketing version is the same across installs, the stamp is not.
final class BuildInfoTests: XCTestCase {

    func test_stampedBuildShowsCommitAndTime() {
        let stamp = BuildInfo.stamp(from: [
            "CFBundleShortVersionString": "1.5.7", "CFBundleVersion": "1",
            "QuipBuildCommit": "a8f2308", "QuipBuildDate": "2026-10-08 08:30",
        ])
        XCTAssertEqual(BuildInfo.display(stamp), "1.5.7 (a8f2308, 2026-10-08 08:30)")
        XCTAssertEqual(BuildInfo.shortDisplay(stamp), "1.5.7 a8f2308")
    }

    func test_dirtyTreeIsVisibleInTheCommit() {
        let stamp = BuildInfo.stamp(from: [
            "CFBundleShortVersionString": "1.5.7", "CFBundleVersion": "1",
            "QuipBuildCommit": "a8f2308-dirty",
        ])
        XCTAssertEqual(BuildInfo.display(stamp), "1.5.7 (a8f2308-dirty)")
    }

    func test_unstampedBuildFallsBackToTheBuildNumber() {
        let stamp = BuildInfo.stamp(from: ["CFBundleShortVersionString": "1.5.7", "CFBundleVersion": "1"])
        XCTAssertEqual(BuildInfo.display(stamp), "1.5.7 (1)")
        XCTAssertEqual(BuildInfo.shortDisplay(stamp), "1.5.7")
        let same = BuildInfo.stamp(from: ["CFBundleShortVersionString": "1.5.7", "CFBundleVersion": "1.5.7"])
        XCTAssertEqual(BuildInfo.display(same), "1.5.7", "no doubled version when build equals short")
    }

    func test_buildNumberLeadsTheStamp() {
        let stamp = BuildInfo.stamp(from: [
            "CFBundleShortVersionString": "1.5.7", "CFBundleVersion": "1",
            "QuipBuildNumber": "1234", "QuipBuildCommit": "a8f2308", "QuipBuildDate": "2026-10-08 08:30",
        ])
        XCTAssertEqual(BuildInfo.display(stamp), "1.5.7 (1234, a8f2308, 2026-10-08 08:30)")
        XCTAssertEqual(BuildInfo.shortDisplay(stamp), "1.5.7 (1234) a8f2308")
    }

    func test_buildNumberWithoutACommitStillShows() {
        let stamp = BuildInfo.stamp(from: [
            "CFBundleShortVersionString": "1.5.7", "CFBundleVersion": "1", "QuipBuildNumber": "1234",
        ])
        XCTAssertEqual(BuildInfo.display(stamp), "1.5.7 (1234)")
        XCTAssertEqual(BuildInfo.shortDisplay(stamp), "1.5.7 (1234)")
    }

    func test_emptyStampKeysCountAsMissing() {
        let stamp = BuildInfo.stamp(from: [
            "CFBundleShortVersionString": "1.5.7", "CFBundleVersion": "1",
            "QuipBuildCommit": "", "QuipBuildDate": "", "QuipBuildNumber": "",
        ])
        XCTAssertNil(stamp.commit)
        XCTAssertNil(stamp.date)
        XCTAssertNil(stamp.number)
        XCTAssertEqual(BuildInfo.display(stamp), "1.5.7 (1)")
    }
}
