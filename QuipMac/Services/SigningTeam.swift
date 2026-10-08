import Foundation
import Security

/// The Apple Developer team that signed this app, read from its own code
/// signature. The APNs key a Quip user uploads belongs to the team that
/// ships their iOS app, which is the team that signed this Mac app too, so
/// it is the right default for an empty Team ID field: the field was wiped
/// once (test suite, 2026-09) and push stayed dark for weeks because nothing
/// could fill it back in.
enum SigningTeam {
    /// nil when the binary is unsigned or ad hoc (no team).
    static let identifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team
    }()
}
