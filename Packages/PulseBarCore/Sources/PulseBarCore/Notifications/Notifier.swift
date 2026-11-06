import Foundation
import UserNotifications

/// Sends local notifications. Protocol so tests can capture instead of posting.
@MainActor
public protocol Notifier: AnyObject {
    func requestAuthorization() async -> Bool
    func isAuthorized() async -> Bool
    func post(id: String, title: String, body: String) async
    /// Repeating daily notification at a local time (minutes since midnight).
    func scheduleDaily(id: String, minute: Int, title: String, body: String) async
    func cancel(id: String)
}

/// Local notifications via UserNotifications. No server, no push.
@MainActor
public final class SystemNotifier: Notifier {
    private var center: UNUserNotificationCenter { .current() }

    public init() {}

    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    public func post(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    public func scheduleDaily(id: String, minute: Int, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(hour: minute / 60, minute: minute % 60), repeats: true)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    public func cancel(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }
}
