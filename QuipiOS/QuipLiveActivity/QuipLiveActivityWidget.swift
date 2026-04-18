import ActivityKit
import WidgetKit
import SwiftUI

/// Renders the Live Activity in three shapes (PRD US-008):
///  - lock-screen banner (full): window name + state subtitle
///  - compact Dynamic Island: color dot (leading) + thinking/waiting icon (trailing)
///  - expanded Dynamic Island: leading color dot, center name, trailing state,
///    bottom "Open Quip" deep-link button
///  - minimal: color dot only (when another activity is also live)
///
/// The visual vocab is consistent with in-app attention state:
///  - thinking  →  soft cyan spinner icon
///  - waiting   →  pulsing yellow "↵" (carriage return) glyph
///
/// No animations are required — ActivityKit re-renders on each
/// activity.update() so we don't need explicit transitions.
struct QuipLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuipLiveActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Circle()
                        .fill(colorForState(context.state.state))
                        .frame(width: 12, height: 12)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.windowName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(stateLabel(context.state.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: iconForState(context.state.state))
                        .font(.system(size: 18))
                        .foregroundStyle(colorForState(context.state.state))
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Link(destination: URL(string: "quip://window/\(context.attributes.windowId)")!) {
                        Label("Open Quip", systemImage: "arrow.up.forward.app")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                }
            } compactLeading: {
                Circle()
                    .fill(colorForState(context.state.state))
                    .frame(width: 10, height: 10)
            } compactTrailing: {
                Image(systemName: iconForState(context.state.state))
                    .font(.system(size: 14))
                    .foregroundStyle(colorForState(context.state.state))
            } minimal: {
                Circle()
                    .fill(colorForState(context.state.state))
                    .frame(width: 10, height: 10)
            }
            .widgetURL(URL(string: "quip://window/\(context.attributes.windowId)"))
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<QuipLiveActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(colorForState(context.state.state))
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.windowName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(stateLabel(context.state.state))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Image(systemName: iconForState(context.state.state))
                .font(.title3)
                .foregroundStyle(colorForState(context.state.state))
        }
        .padding()
    }

    private func colorForState(_ s: String) -> Color {
        s == "waiting" ? .yellow : .cyan
    }

    private func iconForState(_ s: String) -> String {
        s == "waiting" ? "return" : "hourglass"
    }

    private func stateLabel(_ s: String) -> String {
        s == "waiting" ? "Waiting for input" : "Thinking…"
    }
}
