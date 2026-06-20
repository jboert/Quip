// CodeIdentity.swift
// QuipMac — read the running app's own code-signing cdhash and detect whether it
// changed since the previous launch.
//
// Why this exists (GH #33): every `QuipMac/` rebuild bumps the binary's cdhash,
// and macOS TCC revokes Accessibility / Screen Recording / Automation on a cdhash
// change even with our stable signing. The old launch code (QuipMacApp.swift
// ~589) reacted by yanking the user into System Settings on EVERY launch a probe
// came back false — including steady-state launches that just lost a grant to a
// beta-OS hiccup. This helper lets the launch path tell a "you just rebuilt"
// transition apart from a steady-state launch, so the re-grant nudge fires only
// when the binary actually changed.

import Foundation
import Security

/// Minimal key/value seam so `didCodeIdentityChangeSinceLastLaunch` can be unit
/// tested with an injected in-memory store instead of touching the live
/// `UserDefaults.standard`. `UserDefaults` already supplies `string(forKey:)`;
/// `setString` wraps its `Any?` setter so the protocol stays String-typed (and
/// avoids a non-Sendable `Any?` in the protocol surface under Swift 6).
protocol CodeIdentityStore: AnyObject {
    func string(forKey defaultName: String) -> String?
    func setString(_ value: String, forKey defaultName: String)
}

extension UserDefaults: CodeIdentityStore {
    func setString(_ value: String, forKey defaultName: String) {
        set(value, forKey: defaultName)
    }
}

enum CodeIdentity {

    /// UserDefaults key under which the last-seen cdhash hex is persisted.
    static let lastLaunchCDHashKey = "lastLaunchCDHash"

    /// Reads the running app's own cdhash via the Security framework, rendered to
    /// a lowercase hex string. Walks SecCodeCopySelf → SecCodeCopyStaticCode →
    /// SecCodeCopySigningInformation(kSecCodeInfoUnique). Returns nil
    /// (degrade-safe) if any step fails so callers can decide how to react to an
    /// unknown identity rather than crashing.
    static func currentCDHash() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &codeRef) == errSecSuccess,
              let code = codeRef else { return nil }

        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticRef) == errSecSuccess,
              let staticCode = staticRef else { return nil }

        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }

        guard let unique = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// True on the first run ever (no stored value) OR when the current cdhash
    /// differs from the stored one; updates the stored value as a side effect so
    /// the next launch reads "unchanged".
    ///
    /// On a nil cdhash read this errs toward "changed" (returns true) — a failed
    /// read signals rather than goes silent — and leaves the stored value
    /// untouched, so a transient read failure can't overwrite a good value and
    /// mask a later genuine change.
    ///
    /// `store` and `currentHash` are injectable for unit testing; production
    /// callers use the live `UserDefaults.standard` + `currentCDHash` defaults.
    @discardableResult
    static func didCodeIdentityChangeSinceLastLaunch(
        store: CodeIdentityStore = UserDefaults.standard,
        currentHash: () -> String? = currentCDHash
    ) -> Bool {
        let previous = store.string(forKey: lastLaunchCDHashKey)
        guard let current = currentHash() else { return true }
        let changed = previous != current  // nil previous (first run) ⇒ changed
        if changed {
            store.setString(current, forKey: lastLaunchCDHashKey)
        }
        return changed
    }
}
