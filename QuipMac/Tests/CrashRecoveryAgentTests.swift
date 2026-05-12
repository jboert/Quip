import XCTest
@testable import Quip

final class CrashRecoveryAgentTests: XCTestCase {
    func testLabelIsStable() {
        XCTAssertEqual(CrashRecoveryAgent.label, "com.quip.QuipMac.crash-recovery")
    }

    func testPlistURLLandsInUserLaunchAgents() {
        let url = CrashRecoveryAgent.plistURL
        XCTAssertTrue(
            url.path.hasSuffix("/Library/LaunchAgents/com.quip.QuipMac.crash-recovery.plist"),
            "plist must live in ~/Library/LaunchAgents — got \(url.path)"
        )
    }

    func testPlistContentLabelMatches() {
        let dict = CrashRecoveryAgent.plistContent(executablePath: "/Applications/Quip.app/Contents/MacOS/Quip")
        XCTAssertEqual(dict["Label"] as? String, "com.quip.QuipMac.crash-recovery")
    }

    func testPlistContentProgramArgumentsContainsExecutable() {
        let exec = "/Applications/Quip.app/Contents/MacOS/Quip"
        let dict = CrashRecoveryAgent.plistContent(executablePath: exec)
        let args = dict["ProgramArguments"] as? [String]
        XCTAssertEqual(args, [exec])
    }

    func testPlistContentRunAtLoadIsTrue() {
        let dict = CrashRecoveryAgent.plistContent(executablePath: "/x")
        XCTAssertEqual(dict["RunAtLoad"] as? Bool, true)
    }

    func testPlistContentKeepAliveOnlyOnCrash() {
        let dict = CrashRecoveryAgent.plistContent(executablePath: "/x")
        let keepAlive = dict["KeepAlive"] as? [String: Any]
        XCTAssertNotNil(keepAlive)
        XCTAssertEqual(keepAlive?["Crashed"] as? Bool, true,
                       "must restart on crash")
        XCTAssertEqual(keepAlive?["SuccessfulExit"] as? Bool, false,
                       "must NOT restart on user-initiated quit")
    }

    func testPlistContentThrottleIntervalGuardsCrashLoop() {
        let dict = CrashRecoveryAgent.plistContent(executablePath: "/x")
        XCTAssertEqual(dict["ThrottleInterval"] as? Int, 30,
                       "30s throttle prevents tight crash loop")
    }

    func testPlistContentProcessTypeInteractive() {
        let dict = CrashRecoveryAgent.plistContent(executablePath: "/x")
        XCTAssertEqual(dict["ProcessType"] as? String, "Interactive",
                       "Interactive lets the relaunched app draw windows / take focus")
    }

    func testPlistRoundTripsAsXML() throws {
        let dict = CrashRecoveryAgent.plistContent(executablePath: "/Applications/Quip.app/Contents/MacOS/Quip")
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
        let parsed = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["Label"] as? String, "com.quip.QuipMac.crash-recovery")
        XCTAssertEqual(parsed?["ThrottleInterval"] as? Int, 30)
        let parsedKA = parsed?["KeepAlive"] as? [String: Any]
        XCTAssertEqual(parsedKA?["Crashed"] as? Bool, true)
        XCTAssertEqual(parsedKA?["SuccessfulExit"] as? Bool, false)
    }

    func testPlistContentSurvivesUnusualPaths() {
        let weirdPath = "/Users/test user/Apps/Quip 2.app/Contents/MacOS/Quip"
        let dict = CrashRecoveryAgent.plistContent(executablePath: weirdPath)
        let args = dict["ProgramArguments"] as? [String]
        XCTAssertEqual(args, [weirdPath],
                       "spaces and version digits in path must round-trip verbatim")
    }
}
