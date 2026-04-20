import WidgetKit
import SwiftUI

/// Widget extension entry point. Two ActivityConfigurations — no traditional
/// home-screen widgets — covering the two distinct alert surfaces:
///   - QuipLiveActivityWidget: per-window thinking/waiting state
///   - QuipMacPermsActivityWidget: Mac TCC perm needs attention
@main
struct QuipLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        QuipLiveActivityWidget()
        QuipMacPermsActivityWidget()
    }
}
