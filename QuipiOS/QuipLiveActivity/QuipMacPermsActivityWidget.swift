import ActivityKit
import WidgetKit
import SwiftUI

/// Live Activity / Dynamic Island surface for "Mac has TCC perms denied."
/// Visible from outside the Quip app so the user notices Mac is degraded
/// without having to open Quip and check the settings sheet.
///
/// Tap → deep links to `quip://perms` which pops the SettingsSheet open
/// directly on the Mac Permissions section.
struct QuipMacPermsActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuipMacPermsActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.red)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mac needs attention")
                            .font(.headline)
                        Text(subtitle(for: context.state.deniedCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.deniedCount)")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(.trailing, 12)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Link(destination: URL(string: "quip://perms")!) {
                        Label("Open Quip", systemImage: "arrow.up.forward.app")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                }
            } compactLeading: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
            } compactTrailing: {
                Text("\(context.state.deniedCount)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
            } minimal: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            .widgetURL(URL(string: "quip://perms"))
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<QuipMacPermsActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac needs attention")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle(for: context.state.deniedCount))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Text("\(context.state.deniedCount)")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.red)
        }
        .padding()
    }

    private func subtitle(for count: Int) -> String {
        count == 1 ? "1 permission denied — tap to grant" : "\(count) permissions denied — tap to grant"
    }
}
