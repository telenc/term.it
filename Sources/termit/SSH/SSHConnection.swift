import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto

/// Paramètres nécessaires pour ouvrir une connexion (extraits d'un `Host` + secret du Keychain).
struct SSHConnectionConfig: Sendable {
    var hostname: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var password: String?
    var privateKeyContents: String?
    var privateKeyPassphrase: String?
    /// Commande exécutée automatiquement à l'ouverture du shell (snippet).
    var onConnectCommand: String?
}

/// État d'un transfert en cours, pour l'affichage d'une progression.
struct UploadStatus: Sendable, Equatable {
    var name: String
    var fraction: Double   // 0…1
}

enum SSHConnectionError: LocalizedError {
    case missingSecret
    case unsupportedKey
    case notConnected
    case hostKeyChanged(String)

    var errorDescription: String? {
        switch self {
        case .missingSecret: return "Aucun mot de passe ou clé trouvé pour cet hôte."
        case .unsupportedKey: return "Format de clé privée non supporté (utilise une clé OpenSSH ed25519 ou RSA)."
        case .notConnected: return "La connexion SSH n'est pas établie."
        case .hostKeyChanged(let fp):
            return "⚠️ La clé du serveur a CHANGÉ depuis la dernière connexion (\(fp)). "
                + "Cela peut indiquer une interception (man-in-the-middle). "
                + "Si ce changement est légitime, oublie la clé connue dans les réglages de l'hôte, puis reconnecte-toi."
        }
    }
}

/// Encapsule une connexion Citadel : shell interactif (PTY) + SFTP.
/// `actor` pour garantir un accès thread-safe au client.
actor SSHConnection {
    private var client: SSHClient?
    private var stdin: TTYStdinWriter?
    private var cachedSFTP: SFTPClient?

    /// Construit la méthode d'authentification Citadel à partir de la config.
    private static func makeAuth(_ config: SSHConnectionConfig) throws -> SSHAuthenticationMethod {
        switch config.authMethod {
        case .password:
            guard let password = config.password else { throw SSHConnectionError.missingSecret }
            return .passwordBased(username: config.username, password: password)

        case .privateKey:
            guard let pem = config.privateKeyContents else { throw SSHConnectionError.missingSecret }
            let decryptionKey = config.privateKeyPassphrase.map { Data($0.utf8) }

            // Essaie ed25519 puis RSA (formats OpenSSH les plus courants).
            if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: decryptionKey) {
                return .ed25519(username: config.username, privateKey: key)
            }
            if let key = try? Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: decryptionKey) {
                return .rsa(username: config.username, privateKey: key)
            }
            throw SSHConnectionError.unsupportedKey
        }
    }

    /// Établit la connexion TCP + handshake SSH.
    func connect(_ config: SSHConnectionConfig) async throws {
        let auth = try Self.makeAuth(config)
        // Validation TOFU des clés serveur (known_hosts).
        let validator = TOFUHostKeyValidator(host: config.hostname, port: config.port)
        do {
            let client = try await SSHClient.connect(
                host: config.hostname,
                port: config.port,
                authenticationMethod: auth,
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
            self.client = client
        } catch {
            // Si l'échec vient d'un changement de clé, message explicite.
            if validator.didMismatch {
                throw SSHConnectionError.hostKeyChanged(validator.fingerprint)
            }
            throw error
        }
    }

    /// Ouvre un shell interactif. `onOutput` reçoit les octets bruts du serveur,
    /// `cols`/`rows` la taille initiale du terminal. Bloque jusqu'à fermeture du shell.
    func startShell(
        cols: Int,
        rows: Int,
        initialCommand: String? = nil,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws {
        guard let client else { throw SSHConnectionError.notConnected }

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        try await client.withPTY(request) { [weak self] inbound, outbound in
            await self?.setStdin(outbound)
            // Exécute le snippet de démarrage une fois le shell prêt.
            if let cmd = initialCommand, !cmd.isEmpty {
                let line = cmd.hasSuffix("\n") ? cmd : cmd + "\n"
                try? await outbound.write(ByteBuffer(bytes: Data(line.utf8)))
            }
            for try await chunk in inbound {
                switch chunk {
                case .stdout(let buffer), .stderr(let buffer):
                    var buffer = buffer
                    if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                        onOutput(Data(bytes))
                    }
                }
            }
            await self?.setStdin(nil)
        }
    }

    private func setStdin(_ writer: TTYStdinWriter?) {
        self.stdin = writer
    }

    /// Envoie la saisie clavier de l'utilisateur vers le serveur.
    func send(_ data: Data) async throws {
        guard let stdin else { throw SSHConnectionError.notConnected }
        try await stdin.write(ByteBuffer(bytes: data))
    }

    /// Notifie le serveur d'un redimensionnement du terminal.
    func resize(cols: Int, rows: Int) async {
        try? await stdin?.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    /// Exécute une commande ponctuelle (one-shot) et renvoie sa sortie brute.
    /// Utilisé pour lister les dossiers via le shell (contourne le `realpath` du SFTP).
    func execute(_ command: String, maxResponseSize: Int = 8 * 1024 * 1024) async throws -> Data {
        guard let client else { throw SSHConnectionError.notConnected }
        let buffer = try await client.executeCommand(command, maxResponseSize: maxResponseSize)
        return Data(buffer.readableBytesView)
    }

    /// Ouvre une session SFTP sur la connexion existante.
    func openSFTP() async throws -> SFTPClient {
        guard let client else { throw SSHConnectionError.notConnected }
        return try await client.openSFTP()
    }

    /// Upload un fichier local vers `/tmp/<nom>` sur le serveur (canal SFTP mis en cache).
    /// Écrit par morceaux et rapporte la progression (0…1). Retourne le chemin distant.
    func uploadToTmp(localURL: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard let client else { throw SSHConnectionError.notConnected }
        if cachedSFTP == nil { cachedSFTP = try await client.openSFTP() }
        guard let sftp = cachedSFTP else { throw SSHConnectionError.notConnected }

        let data = try Data(contentsOf: localURL)
        let remotePath = "/tmp/" + localURL.lastPathComponent
        try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { handle in
            try await Self.writeChunked(data, to: handle, onProgress: onProgress)
        }
        return remotePath
    }

    /// Taille de morceau pour les transferts (compromis débit / granularité de progression).
    static let chunkSize = 32 * 1024

    /// Écrit des données dans un fichier SFTP par morceaux, en rapportant la progression.
    static func writeChunked(_ data: Data, to handle: SFTPFile,
                             onProgress: @Sendable (Double) -> Void) async throws {
        let total = data.count
        guard total > 0 else { onProgress(1); return }
        var offset = 0
        while offset < total {
            let end = Swift.min(offset + chunkSize, total)
            let slice = data[(data.startIndex + offset)..<(data.startIndex + end)]
            try await handle.write(ByteBuffer(bytes: slice), at: UInt64(offset))
            offset = end
            onProgress(Double(offset) / Double(total))
        }
    }

    func disconnect() async {
        try? await cachedSFTP?.close()
        cachedSFTP = nil
        try? await client?.close()
        client = nil
        stdin = nil
    }
}
