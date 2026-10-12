import AppKit
import UserNotifications

// User-visible banners report our own policy decisions. UserNotifications is
// NOT a source of screenshot/recording events and cannot detect a hidden recorder.
@MainActor final class SecurityNotices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SecurityNotices()
    private var lastPosted: [String: Date] = [:]
    func start() { UNUserNotificationCenter.current().delegate = self }
    func enable() {
        Task {
            if (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) == true {
                post("Security notifications enabled.")
            }
        }
    }
    func post(_ message: String) {
        if let last = lastPosted[message], Date().timeIntervalSince(last) < 60 { return }
        lastPosted[message] = Date()
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "MedPrep Security"; content.body = message
            // No account name, device UUID, token or course data on the lock screen.
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
