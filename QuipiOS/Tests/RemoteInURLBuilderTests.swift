import XCTest
@testable import Quip

/// Q-88 US-010: Remote-in presets fill into links.
@MainActor
final class RemoteInURLBuilderTests: XCTestCase {
    private let magic = "studio.tail1234.ts.net"

    private func link(_ preset: RemoteInPreset, host: String = "", name: String = "") -> String? {
        try? RemoteInURLBuilder.build(preset.template!, host: host, name: name).get().absoluteString
    }

    // MARK: presets

    func test_eachPreset_withMagicDNSHost() {
        XCTAssertEqual(link(.vnc, host: magic), "vnc://studio.tail1234.ts.net")
        XCTAssertEqual(link(.screens, host: magic), "screens://studio.tail1234.ts.net")
        XCTAssertEqual(link(.jump, host: magic), "jump://?host=studio.tail1234.ts.net&protocol=vnc")
        XCTAssertEqual(link(.realvnc, host: magic), "com.realvnc.vncviewer.connect://studio.tail1234.ts.net")
        XCTAssertEqual(link(.berriscope, name: "Studio"), "berriscope://open?saved=Studio")
    }

    func test_ipv4TailscaleHost() {
        XCTAssertEqual(link(.vnc, host: "100.101.102.103"), "vnc://100.101.102.103")
    }

    func test_nameWithSpaces_isPercentEncoded() {
        XCTAssertEqual(link(.berriscope, name: "Mac Studio & Co"), "berriscope://open?saved=Mac%20Studio%20%26%20Co")
    }

    func test_custom_bothPlaceholders() {
        let url = RemoteInURLBuilder.build("myapp://x?h={host}&n={name}", host: magic, name: "My Mac")
        XCTAssertEqual(try url.get().absoluteString, "myapp://x?h=studio.tail1234.ts.net&n=My%20Mac")
    }

    // MARK: failures

    func test_unknownPlaceholder_isAnError() {
        XCTAssertEqual(RemoteInURLBuilder.check("myapp://{hots}"), .unknownPlaceholder("hots"))
        XCTAssertEqual(RemoteInURLBuilder.build("myapp://{hots}", host: magic, name: "n"),
                       .failure(.unknownPlaceholder("hots")))
    }

    func test_unparsable_isBadURL() {
        XCTAssertEqual(RemoteInURLBuilder.check("not a link {host}"), .badURL)
        XCTAssertEqual(RemoteInURLBuilder.check(""), .badURL)
        XCTAssertNil(RemoteInURLBuilder.check("vnc://{host}"))
    }

    func test_emptyHost_forHostPreset_isNoHost() {
        XCTAssertEqual(RemoteInURLBuilder.build("vnc://{host}", host: "  ", name: "Studio"), .failure(.noHost))
    }

    func test_emptyName_forBerriscope_isNoHost() {
        XCTAssertEqual(RemoteInURLBuilder.build(RemoteInPreset.berriscope.template!, host: magic, name: ""),
                       .failure(.noHost))
    }

    // MARK: default host

    func test_defaultHost_prefersMagicDNS_thenTailscaleIP_neverLAN() {
        XCTAssertEqual(RemoteInURLBuilder.defaultHost(urls: [
            "ws://192.168.1.5:8765", "ws://100.70.1.2:8765", "ws://\(magic):8765"]), magic)
        XCTAssertEqual(RemoteInURLBuilder.defaultHost(urls: ["ws://studio.local:8765", "ws://100.70.1.2:8765"]),
                       "100.70.1.2")
        XCTAssertNil(RemoteInURLBuilder.defaultHost(urls: ["ws://192.168.1.5:8765", "ws://100.20.1.2:8765"]))
    }

    // MARK: schemes and storage

    func test_querySchemes_listEveryPreset() {
        XCTAssertEqual(RemoteInPreset.querySchemes,
                       ["vnc", "berriscope", "screens", "jump", "com.realvnc.vncviewer.connect"])
    }

    /// canOpenURL is false for a scheme missing from the app's Info.plist.
    func test_appInfoPlist_listsEveryPresetScheme() {
        let listed = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        XCTAssertEqual(Set(RemoteInPreset.querySchemes).subtracting(listed), [])
    }

    func test_store_roundTripsPerBackend() {
        let d = UserDefaults(suiteName: "RemoteInURLBuilderTests")!
        d.removePersistentDomain(forName: "RemoteInURLBuilderTests")
        RemoteInStore.save(RemoteInSettings(preset: .screens, host: "h"), for: "A", in: d)
        RemoteInStore.save(RemoteInSettings(preset: .custom, customTemplate: "x://{name}"), for: "B", in: d)
        XCTAssertEqual(RemoteInStore.settings(for: "A", in: d).preset, .screens)
        XCTAssertEqual(RemoteInStore.settings(for: "B", in: d).template, "x://{name}")
        XCTAssertEqual(RemoteInStore.settings(for: "C", in: d), RemoteInSettings())
    }

    func test_unknownPresetFromANewerBuild_decodesAsDefault_keepsHost() {
        let map = RemoteInStore.decode(#"{"A":{"preset":"teleport","host":"h"}}"#)
        XCTAssertEqual(map?["A"], RemoteInSettings(preset: .vnc, host: "h"))
    }
}
