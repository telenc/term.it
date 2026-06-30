import Foundation
import NIOCore
import NIOSSH
import Crypto

/// Mémorise les clés publiques des serveurs (known_hosts), pour détecter
/// un changement de clé (potentielle attaque man-in-the-middle).
/// Stockage simple et thread-safe dans UserDefaults.
enum KnownHostsStore {
    private static let defaultsKey = "knownHosts"
    private static let lock = NSLock()

    private static func load() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
    }
    private static func store(_ dict: [String: String]) {
        UserDefaults.standard.set(dict, forKey: defaultsKey)
    }

    static func key(for host: String, port: Int) -> String { "\(host):\(port)" }

    static func storedKey(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()[id]
    }

    static func save(_ publicKey: String, for id: String) {
        lock.lock(); defer { lock.unlock() }
        var d = load(); d[id] = publicKey; store(d)
    }

    /// Oublie la clé d'un hôte (pour re-faire confiance après un changement légitime).
    static func forget(host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        var d = load(); d[key(for: host, port: port)] = nil; store(d)
    }
}

/// Erreur levée quand la clé du serveur ne correspond pas à celle mémorisée.
struct HostKeyChangedError: Error {}

/// Valide la clé du serveur en mode TOFU :
/// - 1ʳᵉ connexion : mémorise la clé et accepte.
/// - ensuite : accepte si identique, refuse (et lève une erreur) si différente.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let id: String
    /// Renseignés pendant la validation (lecture après coup côté connexion).
    private(set) var didMismatch = false
    private(set) var fingerprint = ""

    init(host: String, port: Int) {
        self.id = KnownHostsStore.key(for: host, port: port)
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let bytes = Data(buffer.readableBytesView)
        fingerprint = Self.sha256Fingerprint(bytes)
        let presented = String(openSSHPublicKey: hostKey)

        if let known = KnownHostsStore.storedKey(for: id) {
            if known == presented {
                validationCompletePromise.succeed(())
            } else {
                didMismatch = true
                validationCompletePromise.fail(HostKeyChangedError())
            }
        } else {
            // Trust On First Use : on mémorise et on accepte.
            KnownHostsStore.save(presented, for: id)
            validationCompletePromise.succeed(())
        }
    }

    /// Empreinte au format OpenSSH : "SHA256:<base64 sans padding>".
    static func sha256Fingerprint(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + b64
    }
}
