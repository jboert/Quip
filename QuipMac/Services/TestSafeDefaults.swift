import Foundation

/// The UserDefaults a store persists to: the owner's real domain in the app, a
/// throwaway named suite under XCTest.
///
/// The Mac suite is app-hosted. Its test host is a Quip.app with the real bundle
/// id (com.quip.mac), so `UserDefaults.standard` inside a test IS the owner's
/// live preferences domain: a test that registers a push token or clears a
/// migration flag through `.standard` edits the running app's settings. Stores
/// that persist owner state take their defaults from here, usually as a default
/// argument, so a test that forgets to pass its own suite still cannot reach the
/// owner's domain.
enum TestSafeDefaults {
    /// `.standard` in the app; under XCTest, the suite `com.quip.mac.tests.<name>`.
    static func store(_ name: String) -> UserDefaults {
        guard SingleInstanceGuard.isRunningTests else { return .standard }
        return suite(name)
    }

    /// The named test suite, whether or not XCTest is running.
    static func suite(_ name: String) -> UserDefaults {
        let suiteName = "com.quip.mac.tests.\(name)"
        // UserDefaults(suiteName:) is nil only for the app's own bundle id and
        // NSGlobalDomain, and a `com.quip.mac.tests.` name is neither. Falling
        // back to `.standard` here would quietly reopen the leak this type
        // exists to close, so a nil is treated as the programming error it is.
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName: \(suiteName)) returned nil")
        }
        return defaults
    }
}
