import Foundation
import Observation
import UIKit
@preconcurrency import UserNotifications

/// One answer given from a notification: a lock-screen button (`press_y`,
/// `select_2`) or the Reply field's text. (Q-57)
struct PushAnswer: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let windowId: String
    /// `quick_action` string for a button; nil for a typed reply.
    let action: String?
    /// Typed reply, sent as `send_text` + Return; nil for a button.
    let text: String?
    let promptFingerprint: String?
    let createdAt: Date

    init(windowId: String, action: String? = nil, text: String? = nil,
         promptFingerprint: String?, createdAt: Date = Date()) {
        self.id = UUID()
        self.windowId = windowId
        self.action = action
        self.text = text
        self.promptFingerprint = promptFingerprint
        self.createdAt = createdAt
    }

    var summary: String {
        if let action { return action }
        if let text { return "reply(\(text.count) chars)" }
        return "empty"
    }
}

/// Holds notification answers until a live, authenticated socket can carry
/// them. Before Q-57 a lock-screen tap went straight to `client.send`, which
/// drops silently when the app has been suspended long enough for the socket
/// to die. Now the answer is persisted, the app asks for a connection, and
/// the answer goes out when auth completes; if nothing reaches the Mac within
/// `reachDeadline` the phone posts a local alert so the user knows to open
/// the app. Answers older than `maxAge` are dropped: the prompt has moved on
/// and the Mac would reject them on fingerprint anyway.
@MainActor
@Observable
final class PushAnswerQueue {
    static let shared = PushAnswerQueue()

    static let maxAge: TimeInterval = 600
    static let reachDeadline: TimeInterval = 25

    private(set) var pending: [PushAnswer] = []
    /// When the last answer went out; `onPromptChanged` only fires for an
    /// error that follows a flush closely.
    private(set) var lastSentAt: Date?

    /// Sends one answer over a live, authenticated socket. Returns false when
    /// there is none; the answer stays queued.
    var deliver: ((PushAnswer) -> Bool)?
    /// Asks the app to (re)connect. Called when an answer cannot go out.
    var wake: (() -> Void)?
    /// Posts a user-visible notice. Replaced in tests.
    var notify: (_ title: String, _ body: String) -> Void = PushAnswerQueue.postLocalNotification

    private let storageKey: String
    private let defaults: UserDefaults
    private var deadlineTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(storageKey: String = "pushAnswerQueue.v1", defaults: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([PushAnswer].self, from: data) {
            pending = saved
        }
    }

    /// Queue an answer and try to send it at once.
    func enqueue(_ answer: PushAnswer, now: Date = Date()) {
        pending.append(answer)
        PhoneLog.log("push_answer queued window=\(answer.windowId) answer=\(answer.summary)")
        flush(now: now)
        guard !pending.isEmpty else { return }
        beginBackgroundTaskIfNeeded()
        wake?()
        armDeadline(for: answer)
    }

    /// Send everything that can be sent, oldest first, after dropping what is
    /// too old to matter. Call on auth and whenever the socket comes up.
    func flush(now: Date = Date()) {
        let (kept, dropped) = Self.pruned(pending, now: now)
        for old in dropped {
            PhoneLog.log("push_answer dropped window=\(old.windowId) answer=\(old.summary) age=\(Int(now.timeIntervalSince(old.createdAt)))s")
        }
        pending = kept
        while let next = pending.first {
            guard let deliver, deliver(next) else { break }
            pending.removeFirst()
            lastSentAt = now
            PhoneLog.log("push_answer sent window=\(next.windowId) answer=\(next.summary)")
        }
        persist()
        if pending.isEmpty {
            deadlineTask?.cancel()
            deadlineTask = nil
            endBackgroundTask()
        }
    }

    /// Drop everything still waiting (Settings → Notifications → Discard).
    func discardAll() {
        for a in pending {
            PhoneLog.log("push_answer discarded window=\(a.windowId) answer=\(a.summary)")
        }
        pending = []
        flush()
    }

    /// The Mac refused a just-sent answer because the prompt changed. From
    /// the lock screen the user never sees the in-app toast, so say it here.
    func promptChanged(_ reason: String, now: Date = Date(), appIsActive: Bool) {
        guard !appIsActive, let lastSentAt, now.timeIntervalSince(lastSentAt) < 10 else { return }
        notify("Answer not sent", "\(reason). Open Quip to answer.")
    }

    /// Pure: answers still worth sending, and the ones past `maxAge`.
    nonisolated static func pruned(_ answers: [PushAnswer], now: Date) -> (kept: [PushAnswer], dropped: [PushAnswer]) {
        var kept: [PushAnswer] = [], dropped: [PushAnswer] = []
        for a in answers {
            if now.timeIntervalSince(a.createdAt) > maxAge { dropped.append(a) } else { kept.append(a) }
        }
        return (kept, dropped)
    }

    // MARK: - Private

    private func persist() {
        if pending.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func armDeadline(for answer: PushAnswer) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.reachDeadline))
            guard let self, !Task.isCancelled, self.pending.contains(where: { $0.id == answer.id }) else { return }
            PhoneLog.log("push_answer unreachable window=\(answer.windowId) answer=\(answer.summary) after=\(Int(Self.reachDeadline))s")
            self.notify("Couldn't reach your Mac", "Open Quip to send your answer.")
            self.endBackgroundTask()
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "QuipPushAnswer") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private static func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "quip.push_answer.\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[PushAnswerQueue] local notification failed: \(error.localizedDescription)") }
        }
    }
}
