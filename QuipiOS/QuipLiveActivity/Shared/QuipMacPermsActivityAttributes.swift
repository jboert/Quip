import Foundation
import ActivityKit

/// Attributes + dynamic state for the "Mac TCC permission needs attention"
/// Live Activity. Distinct from `QuipLiveActivityAttributes` (which is per-
/// window thinking/waiting) because the concerns are different — this one is
/// global to the Mac, not tied to any iTerm window.
///
/// One activity at a time: started when the phone receives a Mac permissions
/// snapshot with any denied perm, ended when all three are green.
struct QuipMacPermsActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        /// How many of the three TCC perms are currently denied (0-3). Drives
        /// the badge count + lockscreen subtitle. ContentState carries no
        /// per-perm detail — the in-app strip is the source of truth there.
        public var deniedCount: Int

        public init(deniedCount: Int) {
            self.deniedCount = deniedCount
        }
    }

    public init() {}
}
