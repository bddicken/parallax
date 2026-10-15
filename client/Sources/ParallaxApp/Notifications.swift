import AppKit
import OSLog
@preconcurrency import UserNotifications

private let log = Logger(subsystem: "com.bddicken.parallax", category: "notifications")

/// macOS notifications, for problems you'd miss while looking elsewhere.
/// They show even while Parallax is in front. macOS asks you to allow them
/// the first time one is posted; if they're off, the Dock icon bounces
/// instead.
@MainActor
final class Notifications: NSObject {
    static let shared = Notifications()

    /// What clicking each notification does, by its identifier.
    private var actions: [String: () -> Void] = [:]

    /// Posts a notification; clicking it runs `onClick`.
    func post(_ title: String, _ body: String, onClick: (() -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let id = UUID().uuidString
        if let onClick { actions[id] = onClick }
        Task {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    log.info("notifications are turned off for Parallax")
                    NSApp.requestUserAttention(.criticalRequest)
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                log.info("posted \(title, privacy: .public)")
            } catch {
                NSApp.requestUserAttention(.criticalRequest)
                log.error("couldn't post \(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension Notifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        await MainActor.run { actions.removeValue(forKey: id)?() }
    }
}
