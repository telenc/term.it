import SwiftUI
import SwiftData

/// Identifiant de fenêtre détachée (une session dans sa propre fenêtre).
let detachedWindowID = "detached-session"

@main
struct TermitApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Host.self, HostGroup.self, PortForward.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Impossible de créer le ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouvel hôte…") {
                    NotificationCenter.default.post(name: .newHostRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        // Fenêtre détachée : une seule session, identifiée par l'hôte.
        WindowGroup(id: detachedWindowID, for: PersistentIdentifier.self) { $hostID in
            if let hostID {
                DetachedSessionView(hostID: hostID)
                    .frame(minWidth: 700, minHeight: 460)
            }
        }
        .modelContainer(sharedModelContainer)

        Settings {
            SettingsView()
        }
    }
}

extension Notification.Name {
    static let newHostRequested = Notification.Name("newHostRequested")
}
