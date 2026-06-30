import Foundation
import NIOCore

/// Gère l'activation des redirections de port. Chaque hôte a sa propre
/// connexion SSH dédiée aux tunnels (indépendante des terminaux).
@MainActor
@Observable
final class PortForwardManager {
    static let shared = PortForwardManager()

    /// IDs des règles actuellement actives.
    private(set) var active: Set<UUID> = []
    /// Dernière erreur (pour affichage).
    var errorMessage: String?

    private var connections: [UUID: SSHConnection] = [:]   // hostID → connexion
    private var channels: [UUID: Channel] = [:]            // forwardID → canal serveur

    func isActive(_ forwardID: UUID) -> Bool { active.contains(forwardID) }

    func toggle(_ forward: PortForward, host: Host) async {
        if active.contains(forward.id) {
            await stop(forward)
        } else {
            await start(forward, host: host)
        }
    }

    func start(_ forward: PortForward, host: Host) async {
        do {
            let connection = try await connection(for: host)
            let channel = try await connection.startLocalForward(
                localPort: forward.localPort,
                remoteHost: forward.remoteHost,
                remotePort: forward.remotePort)
            channels[forward.id] = channel
            active.insert(forward.id)
        } catch {
            errorMessage = "Tunnel \(forward.localPort) → \(forward.remoteHost):\(forward.remotePort) : "
                + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    func stop(_ forward: PortForward) async {
        if let channel = channels.removeValue(forKey: forward.id) {
            try? await channel.close()
        }
        active.remove(forward.id)
    }

    private func connection(for host: Host) async throws -> SSHConnection {
        if let existing = connections[host.id] { return existing }
        let connection = SSHConnection()
        try await connection.connect(CredentialResolver.makeConfig(for: host))
        connections[host.id] = connection
        return connection
    }
}
