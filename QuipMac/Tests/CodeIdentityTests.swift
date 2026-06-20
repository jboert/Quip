import XCTest
@testable import Quip

/// Pins the compare/update contract of `CodeIdentity.didCodeIdentityChangeSinceLastLaunch`
/// (GH #33, US-001). Uses an injected in-memory store + an injected cdhash
/// provider so nothing here depends on the live `SecCode` read or the real
/// `UserDefaults.standard`.
final class CodeIdentityTests: XCTestCase {

    /// In-memory `CodeIdentityStore` double — records writes so a test can assert
    /// the side-effecting persistence happened (or didn't).
    private final class FakeStore: CodeIdentityStore {
        var values: [String: String] = [:]
        private(set) var writeCount = 0

        init(seed: String? = nil) {
            if let seed { values[CodeIdentity.lastLaunchCDHashKey] = seed }
        }

        func string(forKey defaultName: String) -> String? { values[defaultName] }

        func setString(_ value: String, forKey defaultName: String) {
            values[defaultName] = value
            writeCount += 1
        }
    }

    // MARK: - First run

    func test_firstRun_noStoredValue_isChanged_andPersists() {
        let store = FakeStore()  // nothing stored yet
        let changed = CodeIdentity.didCodeIdentityChangeSinceLastLaunch(
            store: store,
            currentHash: { "aabb" }
        )
        XCTAssertTrue(changed, "first run with no stored hash must read as changed")
        XCTAssertEqual(store.values[CodeIdentity.lastLaunchCDHashKey], "aabb",
                       "first run must persist the current hash as a side effect")
        XCTAssertEqual(store.writeCount, 1)
    }

    // MARK: - Steady state

    func test_unchanged_sameHash_isNotChanged_andDoesNotRewrite() {
        let store = FakeStore(seed: "aabb")
        let changed = CodeIdentity.didCodeIdentityChangeSinceLastLaunch(
            store: store,
            currentHash: { "aabb" }
        )
        XCTAssertFalse(changed, "identical hash must read as unchanged")
        XCTAssertEqual(store.values[CodeIdentity.lastLaunchCDHashKey], "aabb")
        XCTAssertEqual(store.writeCount, 0, "unchanged launch must not rewrite the store")
    }

    // MARK: - Rebuild

    func test_changed_differentHash_isChanged_andUpdatesStore() {
        let store = FakeStore(seed: "aabb")
        let changed = CodeIdentity.didCodeIdentityChangeSinceLastLaunch(
            store: store,
            currentHash: { "ccdd" }
        )
        XCTAssertTrue(changed, "different hash (rebuild) must read as changed")
        XCTAssertEqual(store.values[CodeIdentity.lastLaunchCDHashKey], "ccdd",
                       "changed launch must update the stored hash")
        XCTAssertEqual(store.writeCount, 1)
    }

    // MARK: - Degrade-safe nil read

    func test_nilRead_errsTowardChanged_andLeavesStoreUntouched() {
        let store = FakeStore(seed: "aabb")
        let changed = CodeIdentity.didCodeIdentityChangeSinceLastLaunch(
            store: store,
            currentHash: { nil }
        )
        XCTAssertTrue(changed, "a nil cdhash read must err toward changed (signal, not silence)")
        XCTAssertEqual(store.values[CodeIdentity.lastLaunchCDHashKey], "aabb",
                       "a nil read must not clobber a good stored value")
        XCTAssertEqual(store.writeCount, 0)
    }

    func test_nilRead_firstRun_isChanged_andStillNoWrite() {
        let store = FakeStore()  // nothing stored, and read fails
        let changed = CodeIdentity.didCodeIdentityChangeSinceLastLaunch(
            store: store,
            currentHash: { nil }
        )
        XCTAssertTrue(changed)
        XCTAssertNil(store.values[CodeIdentity.lastLaunchCDHashKey])
        XCTAssertEqual(store.writeCount, 0)
    }

    // MARK: - Side effect ⇒ next launch reads unchanged

    func test_sideEffect_nextLaunchReadsUnchanged() {
        let store = FakeStore()
        let first = CodeIdentity.didCodeIdentityChangeSinceLastLaunch(
            store: store, currentHash: { "aabb" })
        let second = CodeIdentity.didCodeIdentityChangeSinceLastLaunch(
            store: store, currentHash: { "aabb" })
        XCTAssertTrue(first, "first launch ever is changed")
        XCTAssertFalse(second, "second launch of the same binary is unchanged")
    }
}
