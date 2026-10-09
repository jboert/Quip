import Foundation

/// Decides whether a preferences backup may overwrite what is on the phone.
///
/// Every restore path (iCloud at launch, iCloud change notifications, the
/// desktop's copy on every authenticated connect) used to write straight into
/// UserDefaults, so whichever copy arrived last won, even when it was older
/// than the edit the user had just made. That is how a re-ordered quick row
/// came back in its old order after an app update.
enum PreferencesFreshness {
    /// `localModifiedAt` is the phone's last edit (unix seconds), nil when
    /// nothing was ever edited here (fresh install). `snapshotSavedAt` is the
    /// backup's stamp, nil for copies made before stamps existed.
    static func shouldApply(snapshotSavedAt: Double?, localModifiedAt: Double?) -> Bool {
        switch (snapshotSavedAt, localModifiedAt) {
        case (_, nil):
            // Never edited here: any backup beats defaults.
            return true
        case (nil, .some):
            // An unstamped copy against real edits: the edits win.
            return false
        case (.some(let saved), .some(let local)):
            return saved > local
        }
    }
}
