import Foundation
import UserNotifications

@MainActor
protocol AutoResumeNotifying {
    func post(title: String, body: String)
}

@MainActor
struct SystemAutoResumeNotifier: AutoResumeNotifying {
    func post(title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            center.delegate = AutoResumeNotificationDelegate.shared
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                    return
                }
            } else if settings.authorizationStatus == .denied {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "codex-token-bar-auto-resume-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}

private final class AutoResumeNotificationDelegate: NSObject,
    UNUserNotificationCenterDelegate,
    @unchecked Sendable {
    static let shared = AutoResumeNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
