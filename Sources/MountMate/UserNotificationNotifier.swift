import Foundation
import UserNotifications
import MountMateCore

/// Posts through `UNUserNotificationCenter`.
///
/// Lives in the app target because `UserNotifications` needs a bundle identifier, and
/// `MountMateCore` must stay testable without one.
struct UserNotificationNotifier: Notifier {
    /// Asks once, on a user-initiated action. Never called from a background sweep —
    /// an unattended authorization prompt is the class of bug this project exists to
    /// remove.
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])
        } catch {
            return false
        }
    }

    func post(_ notification: PendingNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        // A failure here is not worth propagating: an unsigned development build may
        // have no authorization, and a missed notification must never disturb a
        // mount attempt.
        try? await UNUserNotificationCenter.current().add(request)
    }
}
