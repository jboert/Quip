import UserNotifications

/// Q-60: retitles the lock-screen buttons with the prompt's own answers.
///
/// A category's button titles are fixed when it is registered, so the static
/// set can only say "1 / 2 / 3". The Mac marks a numbered prompt's alert
/// `mutable-content` and sends `quip_option_labels`; this extension registers
/// a category for that label set and points the alert at it before display.
/// When anything is missing or late, the alert goes out unchanged on the
/// static category it already names, so the digit buttons still work.
final class NotificationService: UNNotificationServiceExtension {

    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        handler = contentHandler
        content = mutable
        let info = request.content.userInfo
        guard let category = WaitingNotificationCategory.dynamicCategory(
            options: WaitingNotificationCategory.options(from: info),
            labels: WaitingNotificationCategory.labels(from: info)) else {
            deliver()
            return
        }
        WaitingNotificationCategory.register(adding: category) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.content?.categoryIdentifier = category.identifier
                self.deliver()
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        deliver()
    }

    /// Hands the alert over once; later calls (expiry after success) are no-ops.
    private func deliver() {
        guard let handler, let content else { return }
        self.handler = nil
        handler(content)
    }
}
