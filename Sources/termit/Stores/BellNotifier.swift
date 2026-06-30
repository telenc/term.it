import AppKit
import UserNotifications

/// Gère la « cloche » du terminal (BEL) : rebond du Dock + notification macOS
/// quand l'app n'est pas au premier plan — comme un terminal local qui « saute ».
@MainActor
enum BellNotifier {
    /// Délégué retenu : permet d'afficher les bannières même app au premier plan.
    private static let delegate = NotificationDelegate()

    /// À appeler au lancement : configure le délégué et demande l'autorisation.
    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func handleBell(host: String, window: NSWindow?) {
        guard TerminalSettings.shared.notifyOnBell else { return }

        let appActive = NSApp.isActive
        let windowFocused = window?.isKeyWindow ?? false

        if appActive && windowFocused {
            NSSound.beep()
            return
        }

        NSApp.requestUserAttention(.criticalRequest) // rebond du Dock
        post(title: "term.it",
             body: host.isEmpty ? "Activité terminée dans le terminal" : "Activité terminée — \(host)")
    }

    /// Notification de test (toujours affichée), pour vérifier la configuration.
    static func test() {
        NSApp.requestUserAttention(.informationalRequest)
        post(title: "term.it", body: "Ceci est une notification de test 🔔")
    }

    private static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}

/// Affiche les notifications même quand l'app est au premier plan.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
