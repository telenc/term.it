import Foundation
import SwiftData

/// Une règle de redirection de port (tunnel local SSH, type `ssh -L`).
@Model
final class PortForward {
    var id: UUID
    /// Hôte (serveur SSH) auquel cette règle est rattachée.
    var hostID: UUID
    /// Port local sur ta machine.
    var localPort: Int
    /// Hôte cible vu depuis le serveur (souvent "localhost").
    var remoteHost: String
    /// Port cible.
    var remotePort: Int
    var label: String

    init(id: UUID = UUID(), hostID: UUID, localPort: Int,
         remoteHost: String = "localhost", remotePort: Int, label: String = "") {
        self.id = id
        self.hostID = hostID
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.label = label
    }
}
