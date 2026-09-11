import Foundation

/// Somewhere to send a notification. The real implementation lives in the app target,
/// because `UserNotifications` needs a bundle and this library must stay testable
/// without one.
public protocol Notifier: Sendable {
    func post(_ notification: PendingNotification) async
}

/// Applies the user's notification preferences.
///
/// Exists so preferences never reach `MountCoordinator`: the coordinator
/// knows it has a notifier, and nothing about what the user wants to hear about.
public struct PreferenceGatedNotifier: Notifier {
    private let wrapped: any Notifier
    private let preferences: any PreferencesStore

    public init(wrapping wrapped: any Notifier, preferences: any PreferencesStore) {
        self.wrapped = wrapped
        self.preferences = preferences
    }

    public func post(_ notification: PendingNotification) async {
        let allowed: Bool
        switch notification.kind {
        case .failure: allowed = await preferences.notifyOnFailure
        case .recovery: allowed = await preferences.notifyOnRecovery
        }
        guard allowed else { return }
        await wrapped.post(notification)
    }
}
