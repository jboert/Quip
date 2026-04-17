import WidgetKit
import SwiftUI

/// Widget extension entry point. Single ActivityConfiguration — no
/// traditional home-screen widgets — because the only surface we use
/// for push notifications is the Dynamic Island / Live Activity.
@main
struct QuipLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        QuipLiveActivityWidget()
    }
}
