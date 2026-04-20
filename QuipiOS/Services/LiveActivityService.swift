import Foundation
@preconcurrency import ActivityKit
import Observation

/// Starts, updates, and ends Live Activities for "Claude is thinking /
/// waiting for input." One activity per tracked windowId; we keep the
/// dictionary of handles so `update` can mutate an existing activity
/// instead of stacking duplicates in the Dynamic Island.
///
/// Updates happen locally via the WebSocket state-change stream — NOT
/// APNs Live Activity push tokens. That means the island stops updating
/// when Quip is killed (iOS doesn't wake an app just to update its own
/// activity). v1.5 will add the push-token path for background updates;
/// see PRD Open Questions.
@MainActor
@Observable
final class LiveActivityService {
    private var activities: [String: Activity<QuipLiveActivityAttributes>] = [:]
    /// Single global activity for the "Mac TCC perms degraded" alert.
    /// Distinct from per-window activities — there's only ever one Mac.
    private var macPermsActivity: Activity<QuipMacPermsActivityAttributes>?

    /// True if Live Activities are usable on this device. False on
    /// iPhones without Dynamic Island (iPhone 13 and earlier), when
    /// the user has disabled Live Activities in iOS Settings, or when
    /// the system refuses new activities (rare, e.g. low battery).
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Sync entry for callers that don't want to deal with async. Spawns
    /// a MainActor task so the actor-isolated async work happens on main.
    nonisolated func startOrUpdate(windowId: String, windowName: String, state: String) {
        Task { @MainActor in
            await self.startOrUpdateAsync(windowId: windowId, windowName: windowName, state: state)
        }
    }

    nonisolated func end(windowId: String) {
        Task { @MainActor in
            await self.endAsync(windowId: windowId)
        }
    }

    nonisolated func endAll() {
        Task { @MainActor in
            await self.endAllAsync()
        }
    }

    /// Start or update the Mac-perms degraded activity. Pass `deniedCount`
    /// (1-3) to refresh the badge; passing 0 ends the activity.
    nonisolated func startOrUpdateMacPerms(deniedCount: Int) {
        Task { @MainActor in
            await self.startOrUpdateMacPermsAsync(deniedCount: deniedCount)
        }
    }

    nonisolated func endMacPerms() {
        Task { @MainActor in
            await self.endMacPermsAsync()
        }
    }

    /// Start a new activity OR update an existing one for this window.
    /// Silently no-ops on unsupported devices so callers don't have to
    /// guard. Each caller passes the current state ("thinking" or
    /// "waiting").
    private func startOrUpdateAsync(windowId: String, windowName: String, state: String) async {
        guard areActivitiesEnabled else {
            print("[LiveActivity] skipped (activities not enabled on this device)")
            return
        }

        if let existing = activities[windowId] {
            let newContent = QuipLiveActivityAttributes.ContentState(state: state)
            await existing.update(ActivityContent(state: newContent, staleDate: nil))
            return
        }

        let attributes = QuipLiveActivityAttributes(windowId: windowId, windowName: windowName)
        let initialContent = ActivityContent(
            state: QuipLiveActivityAttributes.ContentState(state: state),
            staleDate: nil
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: initialContent,
                pushType: nil
            )
            activities[windowId] = activity
        } catch {
            print("[LiveActivity] start failed for \(windowId): \(error)")
        }
    }

    /// End the activity for this window and drop it from our handle map.
    private func endAsync(windowId: String) async {
        guard let activity = activities[windowId] else { return }
        activities.removeValue(forKey: windowId)
        await activity.end(
            ActivityContent(state: activity.content.state, staleDate: nil),
            dismissalPolicy: .immediate
        )
    }

    /// End every activity — used on sign-out / connection loss so the
    /// island doesn't show stale "waiting" state for a window the Mac
    /// no longer reports. Also tears down the Mac-perms alert because a
    /// disconnected phone has nothing useful to say about Mac state.
    private func endAllAsync() async {
        let all = activities
        activities.removeAll()
        for (_, activity) in all {
            await activity.end(
                ActivityContent(state: activity.content.state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
        await endMacPermsAsync()
    }

    private func startOrUpdateMacPermsAsync(deniedCount: Int) async {
        guard areActivitiesEnabled else {
            print("[LiveActivity] mac-perms skipped (activities not enabled)")
            return
        }
        guard deniedCount > 0 else {
            await endMacPermsAsync()
            return
        }
        let newContent = QuipMacPermsActivityAttributes.ContentState(deniedCount: deniedCount)
        if let existing = macPermsActivity {
            await existing.update(ActivityContent(state: newContent, staleDate: nil))
            return
        }
        do {
            macPermsActivity = try Activity.request(
                attributes: QuipMacPermsActivityAttributes(),
                content: ActivityContent(state: newContent, staleDate: nil),
                pushType: nil
            )
        } catch {
            print("[LiveActivity] mac-perms start failed: \(error)")
        }
    }

    private func endMacPermsAsync() async {
        guard let activity = macPermsActivity else { return }
        macPermsActivity = nil
        await activity.end(
            ActivityContent(state: activity.content.state, staleDate: nil),
            dismissalPolicy: .immediate
        )
    }
}
