import XCTest
@testable import Quip

final class LogRedactorTests: XCTestCase {

    // MARK: - IPv4

    func test_redactIPv4_lanAddress_masksLastTwoOctets() {
        let input = "Connection state: failed for 192.168.4.34:52001"
        XCTAssertEqual(LogRedactor.redactIPv4(input),
                       "Connection state: failed for 192.168.x.x:52001")
    }

    func test_redactIPv4_tailscaleCgnat_masksLastTwoOctets() {
        let input = "peer endpoint 100.96.27.4 reachable"
        XCTAssertEqual(LogRedactor.redactIPv4(input),
                       "peer endpoint 100.96.x.x reachable")
    }

    func test_redactIPv4_publicAddress_masksLastTwoOctets() {
        let input = "outbound 8.8.8.8 ttl 64"
        XCTAssertEqual(LogRedactor.redactIPv4(input),
                       "outbound 8.8.x.x ttl 64")
    }

    func test_redactIPv4_multipleIpsInOneLine_allMasked() {
        let input = "10.0.0.5 -> 192.168.1.1 via 100.64.0.1"
        XCTAssertEqual(LogRedactor.redactIPv4(input),
                       "10.0.x.x -> 192.168.x.x via 100.64.x.x")
    }

    func test_redactIPv4_invalidOctet_leftAlone() {
        // 999 isn't a valid octet — must not be masked.
        let input = "version 1.2.999.4"
        XCTAssertEqual(LogRedactor.redactIPv4(input), "version 1.2.999.4")
    }

    func test_redactIPv4_noIpv4_unchanged() {
        let input = "[2026-05-05T19:06:47Z] Connection ready (pending auth)"
        XCTAssertEqual(LogRedactor.redactIPv4(input), input)
    }

    func test_redactIPv4_idempotent() {
        let once = LogRedactor.redactIPv4("from 10.0.0.5")
        let twice = LogRedactor.redactIPv4(once)
        XCTAssertEqual(once, twice)
    }

    // MARK: - Hostname

    func test_redactHostname_replacesCaseInsensitive() {
        let input = "Host: erick-mbp generated this report on Erick-MBP"
        XCTAssertEqual(LogRedactor.redactHostname(input, hostname: "erick-mbp"),
                       "Host: <host> generated this report on <host>")
    }

    func test_redactHostname_emptyOrShort_noOp() {
        let input = "abcde fghij"
        XCTAssertEqual(LogRedactor.redactHostname(input, hostname: ""), input)
        XCTAssertEqual(LogRedactor.redactHostname(input, hostname: "ab"), input)
    }

    func test_redactHostname_noMatch_unchanged() {
        let input = "no host name here"
        XCTAssertEqual(LogRedactor.redactHostname(input, hostname: "missing-host"), input)
    }

    // MARK: - Combined

    func test_redactAll_runsBothPasses() {
        let input = "erick-mbp connected from 192.168.4.34"
        XCTAssertEqual(LogRedactor.redactAll(input, hostname: "erick-mbp"),
                       "<host> connected from 192.168.x.x")
    }
}
