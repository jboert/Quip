import SwiftUI

/// Q-90 US-002: what to say when the active Mac has been unreachable for a
/// while, in plain words, with the one action that helps. Pure, so every row
/// is tested.
enum MacDownBanner {
    enum Action: Equatable {
        /// Quip is down but the Mac answers Screen Sharing: open it.
        case remoteIn
        /// Same, but this Mac has no Remote-in host yet.
        case setUpRemoteIn
        /// The Mac itself is unreachable: usually Tailscale on one side.
        case checkTailscale

        var title: String {
            switch self {
            case .remoteIn: "Remote in"
            case .setUpRemoteIn: "Set up Remote in"
            case .checkTailscale: "Check Tailscale"
            }
        }
    }

    struct Content: Equatable {
        let title: String
        let action: Action?
    }

    /// A blip shorter than this is a reconnect, not an outage.
    static let delay: TimeInterval = 15

    /// US-004: a Mac that will bring Quip back gets this long before the
    /// banner offers Remote in; by then the restart has failed.
    static let restartGrace: TimeInterval = 90

    static func content(kind: MacDown, downFor: TimeInterval, remoteInHostSet: Bool,
                        reliability: ReliabilityStatusMessage? = nil) -> Content? {
        guard downFor >= delay else { return nil }
        let remoteIn: Action = remoteInHostSet ? .remoteIn : .setUpRemoteIn
        switch kind {
        case .quipDown where reliability?.stopped == true:
            // Stop Quip… on the Mac: nothing will bring it back by itself.
            return Content(title: "Quip was stopped on your Mac", action: remoteIn)
        case .quipDown where reliability?.watching == true:
            return Content(title: "Quip on your Mac stopped. Restarting… usually under a minute",
                           action: downFor >= restartGrace ? remoteIn : nil)
        case .quipDown:
            return Content(title: "Quip isn't running on your Mac", action: remoteIn)
        case .offline:
            return Content(title: "Can't reach your Mac", action: .checkTailscale)
        case .unknown:
            return Content(title: "Can't reach your Mac", action: nil)
        }
    }

    /// phone.log gets a `mac_down` line only when the kind changes, not on
    /// every probe. Returns the line to log, if any.
    static func logLine(previous: MacDown?, next: MacDown, probeMs: Int) -> String? {
        previous == next ? nil : MacDown.logLine(next, probeMs: probeMs)
    }
}

struct MacDownBannerView: View {
    let content: MacDownBanner.Content
    let onAction: (MacDownBanner.Action) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(content.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 4)
            if let action = content.action {
                Button(action.title) { onAction(action) }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("macDownBanner")
    }
}
