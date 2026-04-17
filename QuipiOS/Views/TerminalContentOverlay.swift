import SwiftUI

/// Deprecated. Landscape now uses the same inline split layout as portrait
/// (see `landscapeContentSection` in QuipApp.swift) instead of this dismissable
/// overlay. Kept as an empty stub so the Xcode project file still resolves
/// until we formally remove it from the target membership.
struct TerminalContentOverlay: View {
    var body: some View { EmptyView() }
}
