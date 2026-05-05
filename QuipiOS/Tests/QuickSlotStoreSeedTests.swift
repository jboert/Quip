import XCTest
@testable import Quip

/// Pins the fresh-install seed contract for `QuickSlotStore.defaultSlots`
/// and `CustomButtonStore.defaultDemo`. The seed is what makes simulator
/// QA viable — a freshly-erased sim must show both built-in pills AND a
/// custom-button pill the moment Quip connects.
final class QuickSlotStoreSeedTests: XCTestCase {

    // MARK: - QuickSlotStore.defaultSlots

    func test_defaultSlots_includesCustomSlotAtPosition2() {
        let demo = CustomButtonStore.defaultDemo()
        let slots = QuickSlotStore.defaultSlots(demoCustomID: demo.id)

        guard slots.count >= 2 else { return XCTFail("expected ≥2 slots, got \(slots.count)") }
        guard case .custom(let id) = slots[1] else {
            return XCTFail("slot[1] should be .custom, got \(slots[1])")
        }
        XCTAssertEqual(id, demo.id)
    }

    func test_defaultSlots_containsBothCategoriesAndSpacers() {
        let demo = CustomButtonStore.defaultDemo()
        let slots = QuickSlotStore.defaultSlots(demoCustomID: demo.id)

        var hasBuiltin = false
        var hasCustom = false
        var hasSpacer = false
        for slot in slots {
            switch slot {
            case .builtin: hasBuiltin = true
            case .custom: hasCustom = true
            case .spacer: hasSpacer = true
            default: break
            }
        }
        XCTAssertTrue(hasBuiltin, "seed must include at least one built-in")
        XCTAssertTrue(hasCustom, "seed must include the demo custom slot")
        XCTAssertTrue(hasSpacer, "seed must use spacers to group categories")
    }

    func test_defaultSlots_roundTripsThroughCodable() {
        let demo = CustomButtonStore.defaultDemo()
        let slots = QuickSlotStore.defaultSlots(demoCustomID: demo.id)
        let encoded = QuickSlotStore.encode(slots)
        let decoded = QuickSlotStore.decode(encoded)
        XCTAssertEqual(slots.count, decoded.count)
        // ID equality verifies the .custom UUID, .builtin raw, and .spacer
        // UUIDs all survived encode/decode without being regenerated.
        XCTAssertEqual(slots.map(\.id), decoded.map(\.id))
    }

    // MARK: - CustomButtonStore.defaultDemo

    func test_defaultDemo_isStableAcrossCalls() {
        let a = CustomButtonStore.defaultDemo()
        let b = CustomButtonStore.defaultDemo()
        XCTAssertEqual(a.id, b.id, "demoCustomID must be stable so re-seeding doesn't dupe")
        XCTAssertEqual(a.label, b.label)
    }

    func test_defaultDemo_isSlashPayload() {
        let demo = CustomButtonStore.defaultDemo()
        guard case .slash(let text, let autoSubmit) = demo.payload else {
            return XCTFail("demo payload must be .slash, got \(demo.payload)")
        }
        XCTAssertTrue(text.hasPrefix("/"), "slash payload text must start with /")
        XCTAssertFalse(autoSubmit, "demo must NOT auto-submit so user can review before sending")
    }

    func test_defaultDemo_roundTripsThroughCodable() {
        let demo = CustomButtonStore.defaultDemo()
        let encoded = CustomButtonStore.encode([demo])
        let decoded = CustomButtonStore.decode(encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.id, demo.id)
        XCTAssertEqual(decoded.first?.label, demo.label)
    }

    // MARK: - End-to-end: seed → encode → decode → demo slot resolves

    func test_seedRoundTrip_demoSlotResolvesToDemoDef() {
        let demo = CustomButtonStore.defaultDemo()
        let slots = QuickSlotStore.defaultSlots(demoCustomID: demo.id)

        let slotsJSON = QuickSlotStore.encode(slots)
        let defsJSON = CustomButtonStore.encode([demo])

        let decodedSlots = QuickSlotStore.decode(slotsJSON)
        let decodedDefs = CustomButtonStore.decode(defsJSON)

        let customSlotIDs: [UUID] = decodedSlots.compactMap {
            if case .custom(let id) = $0 { return id } else { return nil }
        }
        XCTAssertEqual(customSlotIDs.count, 1)
        let validIDs = Set(decodedDefs.map(\.id))
        XCTAssertTrue(validIDs.contains(customSlotIDs[0]),
                      "the seeded .custom slot must point at a definition that exists in customButtonsJSON")
    }
}
