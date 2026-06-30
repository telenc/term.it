import Foundation
import SwiftData

// MARK: - Format du fichier de synchronisation

/// Représentation sérialisable d'un hôte (sans secret : ceux-ci passent par iCloud Keychain).
struct HostDTO: Codable {
    var id: UUID
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var authMethodRaw: String
    var privateKeyPath: String?
    var colorTag: String?
    var iconName: String?
    var iconImageBase64: String?
    var onConnectCommand: String?
    var createdAt: Date
    var lastConnectedAt: Date?
    var updatedAt: Date
}

struct SyncFile: Codable {
    var hosts: [HostDTO] = []
    /// id d'hôte supprimé → date de suppression (pour propager les suppressions).
    var tombstones: [String: Date] = [:]
}

// MARK: - Service

/// Synchronise les hôtes via un fichier JSON dans iCloud Drive.
/// L'app n'étant pas sandboxée, elle écrit directement dans le dossier CloudDocs
/// que macOS synchronise tout seul — aucun entitlement requis.
@MainActor
final class HostSyncService {
    static let shared = HostSyncService()

    private var context: ModelContext?
    private var timer: Timer?
    private var lastSeenModification: Date?
    private var isApplying = false

    var enabled = false

    /// Dossier iCloud Drive de l'app (existe si iCloud Drive est activé).
    private var folderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/FreeTermius", isDirectory: true)
    }
    private var fileURL: URL { folderURL.appendingPathComponent("hosts.json") }

    /// iCloud Drive est-il disponible sur ce Mac ?
    var iCloudAvailable: Bool {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: cloudDocs.path)
    }

    func configure(context: ModelContext) {
        self.context = context
    }

    /// Démarre la synchronisation : import initial, export, puis surveillance.
    func start() {
        guard iCloudAvailable, context != nil else { return }
        enabled = true
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        importNow()
        exportNow()
        startWatching()
    }

    func stop() {
        enabled = false
        timer?.invalidate()
        timer = nil
    }

    private func startWatching() {
        timer?.invalidate()
        // Sondage léger : iCloud met le fichier à jour, on réimporte au changement.
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.importIfChanged() }
        }
    }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    private func importIfChanged() {
        guard enabled, let mtime = modificationDate() else { return }
        if lastSeenModification == nil || mtime > lastSeenModification! {
            importNow()
        }
    }

    // MARK: Export

    func exportNow() {
        guard enabled, let context else { return }
        do {
            let hosts = try context.fetch(FetchDescriptor<Host>())
            // Conserve les tombstones déjà présentes dans le fichier.
            var file = readFile() ?? SyncFile()
            file.hosts = hosts.map(Self.dto(from:))
            // Nettoie les tombstones d'hôtes qui réexistent.
            let liveIDs = Set(hosts.map { $0.id.uuidString })
            file.tombstones = file.tombstones.filter { !liveIDs.contains($0.key) }
            try writeFile(file)
        } catch {
            NSLog("HostSync export error: \(error)")
        }
    }

    /// Enregistre une suppression (tombstone) puis exporte.
    func markDeleted(_ id: UUID) {
        guard enabled else { return }
        var file = readFile() ?? SyncFile()
        file.tombstones[id.uuidString] = Date()
        try? writeFile(file)
    }

    // MARK: Import

    func importNow() {
        guard enabled, let context, let file = readFile() else { return }
        isApplying = true
        defer { isApplying = false }

        do {
            let existing = try context.fetch(FetchDescriptor<Host>())
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

            // Upsert (last-writer-wins via updatedAt).
            for dto in file.hosts {
                if let local = byID[dto.id] {
                    if dto.updatedAt > local.updatedAt { Self.apply(dto, to: local) }
                } else {
                    let host = Host(id: dto.id, name: dto.name, hostname: dto.hostname,
                                    port: dto.port, username: dto.username)
                    Self.apply(dto, to: host)
                    context.insert(host)
                    byID[dto.id] = host
                }
            }

            // Suppressions : applique les tombstones plus récentes que l'hôte local.
            for (key, date) in file.tombstones {
                guard let uuid = UUID(uuidString: key), let local = byID[uuid] else { continue }
                if date > local.updatedAt {
                    KeychainHelper.delete(account: local.keychainAccount)
                    context.delete(local)
                }
            }

            try context.save()
            lastSeenModification = modificationDate()
        } catch {
            NSLog("HostSync import error: \(error)")
        }
    }

    // MARK: Fichier

    private func readFile() -> SyncFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.iso.decode(SyncFile.self, from: data)
    }

    private func writeFile(_ file: SyncFile) throws {
        let data = try JSONEncoder.iso.encode(file)
        try data.write(to: fileURL, options: .atomic)
        lastSeenModification = modificationDate()
    }

    // MARK: Conversion DTO

    private static func dto(from host: Host) -> HostDTO {
        HostDTO(
            id: host.id, name: host.name, hostname: host.hostname, port: host.port,
            username: host.username, authMethodRaw: host.authMethodRaw,
            privateKeyPath: host.privateKeyPath, colorTag: host.colorTag,
            iconName: host.iconName,
            iconImageBase64: host.iconImageData?.base64EncodedString(),
            onConnectCommand: host.onConnectCommand,
            createdAt: host.createdAt, lastConnectedAt: host.lastConnectedAt,
            updatedAt: host.updatedAt
        )
    }

    private static func apply(_ dto: HostDTO, to host: Host) {
        host.name = dto.name
        host.hostname = dto.hostname
        host.port = dto.port
        host.username = dto.username
        host.authMethodRaw = dto.authMethodRaw
        host.privateKeyPath = dto.privateKeyPath
        host.colorTag = dto.colorTag
        host.iconName = dto.iconName
        host.iconImageData = dto.iconImageBase64.flatMap { Data(base64Encoded: $0) }
        host.onConnectCommand = dto.onConnectCommand
        host.lastConnectedAt = dto.lastConnectedAt
        host.updatedAt = dto.updatedAt
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
private extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
