// MotionPolicy.swift
// QuipMac — One rule for honouring System Settings → Accessibility → Reduce Motion

import SwiftUI

/// Every decorative animation in the Mac views goes through here, so "Reduce
/// Motion is on" means no motion everywhere rather than at whichever sites
/// remembered to check. Pair with `@Environment(\.accessibilityReduceMotion)`.
enum MotionPolicy {
    /// `nil` — no animation, the change lands at once — when Reduce Motion is
    /// on; otherwise `base` unchanged. Both `.animation(_:value:)` and
    /// `withAnimation(_:_:)` take an optional, so call sites pass this straight
    /// through.
    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}
