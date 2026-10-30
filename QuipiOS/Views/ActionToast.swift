import SwiftUI

/// A short message with one action ("Order: Manual — Use Recent"), gone
/// after `lifetime`. Q-88 US-004 first; US-009 and US-011 reuse it.
@MainActor
@Observable
final class ActionToastModel {
    struct Toast: Equatable {
        let id: Int
        let text: String
        let actionTitle: String
    }

    static let lifetime: TimeInterval = 4

    private(set) var current: Toast?
    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var nextId = 0
    @ObservationIgnored private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, fire in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(fire) }
    }) {
        self.schedule = schedule
    }

    /// Replaces any toast on screen. Its timer starts now; an older toast's
    /// timer firing later leaves this one alone.
    func show(_ text: String, actionTitle: String, action: @escaping () -> Void) {
        nextId += 1
        let toast = Toast(id: nextId, text: text, actionTitle: actionTitle)
        current = toast
        self.action = action
        schedule(Self.lifetime) { [weak self] in
            guard let self, self.current?.id == toast.id else { return }
            self.dismiss()
        }
    }

    func performAction() {
        let run = action
        dismiss()
        run?()
    }

    func dismiss() {
        current = nil
        action = nil
    }
}

/// The capsule for `ActionToastModel.current`: text, then the action as a
/// button. VoiceOver reads them as one element ("Order: Manual, Use Recent")
/// whose activation runs the action.
struct ActionToastView: View {
    let model: ActionToastModel

    var body: some View {
        if let toast = model.current {
            HStack(spacing: 12) {
                Text(toast.text)
                Button(toast.actionTitle) { model.performAction() }
                    .fontWeight(.semibold)
                    .foregroundStyle(.yellow)
                    .buttonStyle(.plain)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.78))
            .clipShape(Capsule())
            .accessibilityElement(children: .combine)
            .id(toast.id)
        }
    }
}
