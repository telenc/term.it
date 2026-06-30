import AppKit
import UserNotifications

/// Gère la « cloche » du terminal (BEL) : rebond du Dock + notification macOS
/// quand l'app n'est pas au premier plan — comme un terminal local qui « saute ».
@MainActor
enum BellNotifier {
    /// À appeler au lancement pour demander l'autorisation des notifications.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func handleBell(host: String, window: NSWindow?) {
        guard TerminalSettings.shared.notifyOnBell else { return }

        let appActive = NSApp.isActive
        let windowFocused = window?.isKeyWindow ?? false

        if appActive && windowFocused {
            // Au premier plan et focus : simple bip discret.
            NSSound.beep()
            return
        }

        // En arrière-plan / fenêtre non focalisée : on attire l'attention.
        NSApp.requestUserAttention(.criticalRequest) // fait rebondir l'icône du Dock

        let content = UNMutableNotificationContent()
        content.title = "term.it"
        content.body = host.isEmpty ? "Activité terminée dans le terminal" : "Activité terminée — \(host)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
