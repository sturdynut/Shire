import AppKit
import Foundation
import ShireCore
import UserNotifications

/// Posts shire-agent's alerts as real macOS notifications from Shire. The agent writes every alert to alerts.jsonl;
/// this delivers the ones newer than the last it delivered. History from before the app first ran is not replayed.
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let defaultsKey = "lastDeliveredAlert"
    private var authorized = false
    var onOpenService: ((String?) -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
        if UserDefaults.standard.object(forKey: defaultsKey) == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: defaultsKey)
        }
    }

    func deliverNew(from paths: ShirePaths) {
        let last = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: defaultsKey))
        let fresh = AlertLog(url: paths.alertsFile).recent(20).filter { $0.time > last }
        guard let newest = fresh.map(\.time).max() else { return }
        UserDefaults.standard.set(newest.timeIntervalSince1970, forKey: defaultsKey)
        fresh.forEach(post)
    }

    func post(_ alert: AlertMessage) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = alert.kind == .problem ? .default : nil
        if let service = alert.service { content.userInfo = ["service": service] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show notifications even while the menu is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // Clicking a notification opens the service it's about.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let service = response.notification.request.content.userInfo["service"] as? String
        completionHandler()
        Task { @MainActor in
            self.onOpenService?(service)
        }
    }
}
