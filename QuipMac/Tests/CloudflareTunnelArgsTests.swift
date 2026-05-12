import XCTest
@testable import Quip

/// Locks the structure of `CloudflareTunnel.cloudflaredArguments(proxyPort:logPath:)`
/// so a future regression that wraps the invocation in `/bin/sh -c "..."` or
/// builds args by string concatenation gets caught.
/// See docs/security/2026-05-06-cloudflared-process-audit.md (GH #15).
final class CloudflareTunnelArgsTests: XCTestCase {

    func test_args_firstElement_isTunnelVerb_notShell() {
        let argv = CloudflareTunnel.cloudflaredArguments(proxyPort: 8766, logPath: "/tmp/x.log")
        XCTAssertEqual(argv.first, "tunnel",
                       "argv[0] must be the cloudflared subcommand, not a shell wrapper")
    }

    func test_args_length_isStable() {
        let argv = CloudflareTunnel.cloudflaredArguments(proxyPort: 8766, logPath: "/tmp/x.log")
        XCTAssertEqual(argv.count, 10,
                       "argv length is part of the security contract — adding/removing args without an audit update should fail this test")
    }

    func test_args_url_format_forCommonPort() {
        let argv = CloudflareTunnel.cloudflaredArguments(proxyPort: 8766, logPath: "/tmp/x.log")
        guard let urlIdx = argv.firstIndex(of: "--url"), urlIdx + 1 < argv.count else {
            XCTFail("--url flag missing")
            return
        }
        XCTAssertEqual(argv[urlIdx + 1], "http://localhost:8766")
    }

    func test_args_url_format_forBoundaryPorts() {
        for port: UInt16 in [0, 1, 8765, 65535] {
            let argv = CloudflareTunnel.cloudflaredArguments(proxyPort: port, logPath: "/tmp/x.log")
            guard let urlIdx = argv.firstIndex(of: "--url"), urlIdx + 1 < argv.count else {
                XCTFail("--url flag missing for port \(port)")
                continue
            }
            XCTAssertEqual(argv[urlIdx + 1], "http://localhost:\(port)")
            XCTAssertFalse(argv[urlIdx + 1].contains(";"), "UInt16 interpolation must not produce a semicolon")
            XCTAssertFalse(argv[urlIdx + 1].contains("&"), "UInt16 interpolation must not produce an ampersand")
            XCTAssertFalse(argv[urlIdx + 1].contains("$"), "UInt16 interpolation must not produce a dollar sign")
        }
    }

    func test_args_logfile_passedVerbatim_evenWithShellSpecialChars() {
        let evilPath = "/tmp/'; rm -rf / #"
        let argv = CloudflareTunnel.cloudflaredArguments(proxyPort: 8766, logPath: evilPath)
        guard let logIdx = argv.firstIndex(of: "--logfile"), logIdx + 1 < argv.count else {
            XCTFail("--logfile flag missing")
            return
        }
        XCTAssertEqual(argv[logIdx + 1], evilPath,
                       "logPath must be passed as one argv element, not concatenated/shell-interpreted")
    }

    func test_args_noElement_invokesShell() {
        let argv = CloudflareTunnel.cloudflaredArguments(proxyPort: 8766, logPath: "/tmp/x.log")
        for element in argv {
            XCTAssertNotEqual(element, "-c", "argv must not contain a `-c` flag (shell-eval)")
            XCTAssertFalse(element.hasPrefix("/bin/sh"), "argv must not point at /bin/sh")
            XCTAssertFalse(element.hasPrefix("/bin/bash"), "argv must not point at /bin/bash")
            XCTAssertFalse(element.contains("$(") || element.contains("`"),
                           "argv must not contain command-substitution syntax")
        }
    }

    func test_args_logFormat_isJson() {
        let argv = CloudflareTunnel.cloudflaredArguments(proxyPort: 8766, logPath: "/tmp/x.log")
        guard let fmtIdx = argv.firstIndex(of: "--log-format"), fmtIdx + 1 < argv.count else {
            XCTFail("--log-format flag missing")
            return
        }
        XCTAssertEqual(argv[fmtIdx + 1], "json",
                       "URL extraction relies on per-line JSON records; a format change must update extractTunnelURL")
    }
}
