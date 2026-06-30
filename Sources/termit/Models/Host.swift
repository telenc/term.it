import Foundation
import SwiftData

/// Méthode d'authentification d'un hôte.
enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .password: return "Mot de passe"
        case .privateKey: return "Clé privée"
        }
    }
}

/// Un serveur SSH/SFTP enregistré.
@Model
final class Host {
    var id: UUID
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var authMethodRaw: String
    /// Chemin du fichier de clé privée (si auth par clé).
    var privateKeyPath: String?
    /// Couleur d'étiquette (nom d'un accent système), optionnelle.
    var colorTag: String?
    /// Nom d'un SF Symbol pour l'icône (si pas d'image personnalisée).
    var iconName: String?
    /// Image d'icône personnalisée (uploadée), stockée hors base.
    @Attribute(.externalStorage) var iconImageData: Data?
    /// Commande (snippet) exécutée automatiquement à l'ouverture du shell.
    var onConnectCommand: String?
    var group: HostGroup?
    var createdAt: Date
    var lastConnectedAt: Date?
    /// Date de dernière modification (résolution de conflits pour la sync iCloud).
    var updatedAt: Date = Date()

    var authMethod: AuthMethod {
        get { AuthMethod(rawValue: authMethodRaw) ?? .password }
        set { authMethodRaw = newValue.rawValue }
    }

    /// Identifiant logique pour stocker/retrouver le secret dans le Keychain.
    var keychainAccount: String { "host-\(id.uuidString)" }

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .password,
        privateKeyPath: String? = nil,
        colorTag: String? = nil,
        group: HostGroup? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethodRaw = authMethod.rawValue
        self.privateKeyPath = privateKeyPath
        self.colorTag = colorTag
        self.group = group
        self.createdAt = Date()
        self.lastConnectedAt = nil
        self.updatedAt = Date()
    }
}

/// Groupe pour organiser les hôtes dans la sidebar (style dossiers Finder).
@Model
final class HostGroup {
    var id: UUID
    var name: String
    var sortIndex: Int
    @Relationship(deleteRule: .nullify, inverse: \Host.group)
    var hosts: [Host]

    init(id: UUID = UUID(), name: String, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.hosts = []
    }
}
