import Foundation

/// Construit une `SSHConnectionConfig` prête à l'emploi à partir d'un `Host`,
/// en récupérant les secrets dans le Keychain et le contenu de la clé sur disque.
enum CredentialResolver {
    static func makeConfig(for host: Host) -> SSHConnectionConfig {
        var password: String?
        var keyContents: String?
        var passphrase: String?

        switch host.authMethod {
        case .password:
            password = KeychainHelper.read(account: host.keychainAccount)
        case .privateKey:
            if let path = host.privateKeyPath {
                let expanded = (path as NSString).expandingTildeInPath
                keyContents = try? String(contentsOfFile: expanded, encoding: .utf8)
            }
            // La passphrase éventuelle est stockée dans le Keychain.
            passphrase = KeychainHelper.read(account: host.keychainAccount)
        }

        return SSHConnectionConfig(
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            authMethod: host.authMethod,
            password: password,
            privateKeyContents: keyContents,
            privateKeyPassphrase: passphrase?.isEmpty == true ? nil : passphrase,
            onConnectCommand: host.onConnectCommand
        )
    }
}
