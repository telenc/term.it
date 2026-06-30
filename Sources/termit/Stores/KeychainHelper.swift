import Foundation
import Security

/// Stockage sécurisé des secrets (mots de passe, passphrases) dans le Keychain macOS.
/// Les secrets ne sont jamais persistés dans SwiftData en clair.
///
/// Les items sont marqués `kSecAttrSynchronizable` afin d'être synchronisés
/// (chiffrés) entre les Macs de l'utilisateur via iCloud Keychain.
enum KeychainHelper {
    private static let service = "com.termit.credentials"

    /// Active la synchronisation iCloud Keychain des nouveaux secrets.
    static var syncEnabled = true

    @discardableResult
    static func save(_ secret: String, account: String) -> Bool {
        let data = Data(secret.utf8)
        // Supprime l'entrée existante (locale et/ou synchronisée) avant d'écrire.
        delete(account: account)

        func add(synchronizable: Bool) -> OSStatus {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
            ]
            return SecItemAdd(query as CFDictionary, nil)
        }

        // Tente la synchro iCloud Keychain si demandée…
        if syncEnabled {
            if add(synchronizable: true) == errSecSuccess { return true }
            // …mais si l'environnement n'a pas les droits iCloud Keychain,
            // l'écriture échoue : on retombe sur une sauvegarde LOCALE garantie.
            delete(account: account)
        }
        return add(synchronizable: false) == errSecSuccess
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Cherche aussi bien les items locaux que synchronisés.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        return secret
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
