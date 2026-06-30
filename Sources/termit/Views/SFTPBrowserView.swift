import SwiftUI
import Citadel
import NIOCore
import UniformTypeIdentifiers

/// Élément affiché dans le navigateur SFTP.
struct RemoteFile: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let permissions: String
}

/// Modèle observable qui gère la connexion SFTP et l'état du navigateur.
@MainActor
@Observable
final class SFTPModel {
    var path = "."
    var files: [RemoteFile] = []
    var isLoading = false
    var errorMessage: String?
    /// Message de retour transitoire (transfert réussi, etc.).
    var statusMessage: String?
    /// Progression d'un upload en cours (nil = aucun).
    var upload: UploadStatus?

    private let connection = SSHConnection()
    private var sftp: SFTPClient?
    private let config: SSHConnectionConfig
    private var connected = false

    init(config: SSHConnectionConfig) {
        self.config = config
    }

    func connectIfNeeded() async {
        guard !connected else { return }
        isLoading = true
        defer { isLoading = false }
        var step = "connexion SSH"
        do {
            try await connection.connect(config)
            step = "ouverture du canal SFTP"
            let sftp = try await connection.openSFTP()
            self.sftp = sftp
            connected = true
            // Résout le répertoire home via le shell (pwd), pas via realpath SFTP.
            step = "résolution du répertoire home"
            if let home = try? await connection.execute("pwd") {
                let p = String(decoding: home, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if p.hasPrefix("/") { self.path = p }
            }
            await reload()
        } catch {
            errorMessage = "Échec (\(step)) : \(describe(error))"
        }
    }

    @discardableResult
    func reload() async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            // Listing via le shell (ls), pour voir tout ce que l'utilisateur voit,
            // y compris les dossiers protégés macOS que le realpath SFTP refuse.
            // `|| true` : ls renvoie un code ≠ 0 dès qu'un seul élément est illisible
            //  (ex. lien symbolique cassé) même s'il a listé tout le reste — on ne
            //  veut pas perdre cette sortie valide. `2>&1` capture aussi les erreurs.
            // On capture le code retour de `ls` via un sentinel : la commande globale
            // se termine par `echo` (exit 0), donc executeCommand ne lève jamais.
            // stderr est fusionné (2>&1) mais ne parse pas comme un fichier.
            let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let output = try await connection.execute("ls -lAp -- \(quoted) 2>&1; echo \"__FT_RC__$?\"")
            let text = String(decoding: output, as: UTF8.self)

            var rc = 0
            if let range = text.range(of: "__FT_RC__") {
                rc = Int(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
            let parsed = Self.parseLS(text)
                .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }

            // rc ≠ 0 ET aucune entrée → vrai échec (et non un dossier vide accessible
            // ou un simple lien cassé qui aurait quand même listé le reste).
            if rc != 0 && parsed.isEmpty {
                let lower = text.lowercased()
                if lower.contains("permitted") || lower.contains("denied") {
                    errorMessage = "Accès refusé par macOS sur ce dossier. Sur le Mac serveur : Réglages Système › Confidentialité et sécurité › Accès complet au disque → active « Connexion à distance »."
                } else if lower.contains("no such") {
                    errorMessage = "Dossier introuvable : \(path)"
                } else {
                    errorMessage = "Impossible de lister \(path)."
                }
                return false
            }
            files = parsed
            return true
        } catch {
            errorMessage = "Échec (listing de \(path)) : \(describe(error))"
            return false
        }
    }

    /// Parse une sortie `ls -lAp` (compatible macOS BSD et Linux GNU).
    /// Format : `drwxr-xr-x  5 user group  160 Jun 30 12:00 nom/`
    nonisolated static func parseLS(_ text: String) -> [RemoteFile] {
        var result: [RemoteFile] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            // Ignore la ligne "total N".
            if line.hasPrefix("total ") { continue }
            guard let first = line.first, "dl-bcps".contains(first) else { continue }
            // Découpe les 8 premiers champs ; le nom est tout le reste.
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            let perms = String(parts[0])
            let size = UInt64(parts[4]) ?? 0
            var name = String(parts[8])
            // Retire la cible des liens symboliques : "lien -> cible".
            if let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            // `-p` ajoute un / final aux dossiers ; on l'utilise puis on le retire.
            let trailingSlash = name.hasSuffix("/")
            if trailingSlash { name.removeLast() }
            let isDir = first == "d" || trailingSlash
            if name == "." || name == ".." || name.isEmpty { continue }
            result.append(RemoteFile(
                name: name,
                isDirectory: isDir,
                size: size,
                permissions: String(perms.prefix(10))
            ))
        }
        return result
    }

    /// Navigue vers un chemin ; revient au précédent si le listing échoue.
    private func navigate(to target: String) async {
        let previous = path
        path = target
        if await reload() == false {
            path = previous
            await reload()
        }
    }

    func open(_ file: RemoteFile) async {
        guard file.isDirectory else { return }
        await navigate(to: normalized(path + "/" + file.name))
    }

    func goUp() async {
        guard path != "/" else { return }
        var parent = normalized((path as NSString).deletingLastPathComponent)
        if parent.isEmpty { parent = "/" }
        await navigate(to: parent)
    }

    func download(_ file: RemoteFile, to destination: URL) async {
        guard let sftp, !file.isDirectory else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let remotePath = normalized(path + "/" + file.name)
            let buffer = try await sftp.withFile(filePath: remotePath, flags: .read) { handle in
                try await handle.readAll()
            }
            let data = Data(buffer.readableBytesView)
            try data.write(to: destination)
            statusMessage = "Téléchargé : \(file.name) → \(destination.path)"
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Télécharge un fichier vers un emplacement temporaire (pour le glisser-vers-Finder).
    /// Retourne l'URL locale, ou nil en cas d'échec.
    func downloadToTemp(_ file: RemoteFile) async -> URL? {
        guard let sftp, !file.isDirectory else { return nil }
        do {
            let remotePath = normalized(path + "/" + file.name)
            let buffer = try await sftp.withFile(filePath: remotePath, flags: .read) { handle in
                try await handle.readAll()
            }
            let data = Data(buffer.readableBytesView)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ft-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(file.name)
            try data.write(to: url)
            return url
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    /// Télécharge un fichier directement dans le dossier Téléchargements de l'utilisateur.
    func downloadToDownloads(_ file: RemoteFile) async {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        await download(file, to: downloads.appendingPathComponent(file.name))
    }

    /// Supprime un ensemble d'éléments (fichiers ou dossiers).
    func delete(_ items: [RemoteFile]) async {
        guard let sftp else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            for item in items {
                let remotePath = normalized(path + "/" + item.name)
                if item.isDirectory {
                    try await sftp.rmdir(at: remotePath)
                } else {
                    try await sftp.remove(at: remotePath)
                }
            }
            await reload()
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Crée un nouveau dossier dans le répertoire courant.
    func createDirectory(named name: String) async {
        guard let sftp, !name.isEmpty else { return }
        do {
            try await sftp.createDirectory(atPath: normalized(path + "/" + name))
            await reload()
        } catch {
            errorMessage = describe(error)
        }
    }

    func upload(localURL: URL) async {
        guard let sftp else { return }
        let name = localURL.lastPathComponent
        upload = UploadStatus(name: name, fraction: 0)
        defer { upload = nil }
        do {
            let data = try Data(contentsOf: localURL)
            let remotePath = normalized(path + "/" + name)
            try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { handle in
                try await SSHConnection.writeChunked(data, to: handle) { frac in
                    Task { @MainActor in self.upload = UploadStatus(name: name, fraction: frac) }
                }
            }
            statusMessage = "Envoyé : \(name)"
            await reload()
        } catch {
            errorMessage = describe(error)
        }
    }

    func disconnect() async {
        try? await sftp?.close()
        await connection.disconnect()
        connected = false
    }

    private func normalized(_ p: String) -> String {
        let parts = p.split(separator: "/").reduce(into: [String]()) { acc, part in
            if part == ".." { _ = acc.popLast() }
            else if part != "." { acc.append(String(part)) }
        }
        return "/" + parts.joined(separator: "/")
    }

    private func describe(_ error: Error) -> String {
        if let channelError = error as? ChannelError {
            switch channelError {
            case .inputClosed, .eof, .alreadyClosed, .ioOnClosedChannel:
                return "le serveur a fermé le canal SFTP. Le sous-système SFTP est-il activé sur ce serveur (sshd_config: Subsystem sftp …) ?"
            default:
                return "erreur de canal réseau : \(channelError)"
            }
        }
        // Traduit les codes d'erreur SFTP standards en messages clairs.
        let raw = "\(error)"
        if raw.contains("PERMISSION_DENIED") {
            return "permission refusée — ton utilisateur n'a pas accès à cet emplacement sur le serveur."
        }
        if raw.contains("NO_SUCH_FILE") {
            return "fichier ou dossier introuvable sur le serveur."
        }
        if raw.contains("FAILURE") {
            return "le serveur a refusé l'opération."
        }
        return (error as? LocalizedError)?.errorDescription ?? raw
    }
}

/// Navigateur de fichiers distant style Finder.
struct SFTPBrowserView: View {
    let host: Host
    @State private var model: SFTPModel

    init(host: Host) {
        self.host = host
        _model = State(initialValue: SFTPModel(config: CredentialResolver.makeConfig(for: host)))
    }

    /// Sélection courante (IDs des fichiers).
    @State private var selection = Set<RemoteFile.ID>()
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var dropTargeted = false

    private var selectedFiles: [RemoteFile] {
        model.files.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            fileList
            Divider()
            statusBar
        }
        .overlay {
            if let up = model.upload {
                VStack(spacing: 12) {
                    ProgressView(value: up.fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                    Text("Envoi de « \(up.name) » — \(Int(up.fraction * 100)) %")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.upload)
        .task { await model.connectIfNeeded() }
        .onDisappear { Task { await model.disconnect() } }
        .alert("Erreur SFTP", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Nouveau dossier", isPresented: $showingNewFolder) {
            TextField("Nom du dossier", text: $newFolderName)
            Button("Créer") {
                Task { await model.createDirectory(named: newFolderName); newFolderName = "" }
            }
            Button("Annuler", role: .cancel) { newFolderName = "" }
        }
    }

    // MARK: - Barre de chemin + actions

    private var pathBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.goUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(model.path == "/")
            .help("Dossier parent")

            Text(model.path)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.head)

            if model.isLoading {
                ProgressView().controlSize(.small)
            }

            Spacer()

            Button {
                downloadSelection()
            } label: {
                Label("Télécharger", systemImage: "arrow.down.circle")
            }
            .disabled(selectedFiles.isEmpty || selectedFiles.allSatisfy(\.isDirectory))
            .help("Télécharger la sélection sur ton Mac")

            Button {
                uploadFile()
            } label: {
                Label("Envoyer", systemImage: "arrow.up.circle")
            }
            .help("Envoyer un fichier depuis ton Mac")

            Button {
                showingNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("Nouveau dossier")

            Button {
                deleteSelection()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selectedFiles.isEmpty)
            .help("Supprimer la sélection")

            Button {
                Task { await model.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Actualiser")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        // Réserve l'espace en haut (boutons de fenêtre + barre au survol).
        .padding(.top, 34)
    }

    // MARK: - Liste de fichiers (sélectionnable)

    private var fileList: some View {
        List(model.files, selection: $selection) { file in
            HStack(spacing: 10) {
                Image(systemName: file.isDirectory ? "folder.fill" : iconName(for: file.name))
                    .foregroundStyle(file.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 20)
                Text(file.name)
                Spacer()
                if !file.isDirectory {
                    Text(byteString(file.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(file.permissions)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            // Glisser un fichier vers le Finder → téléchargement à la demande.
            .onDrag { dragProvider(for: file) }
            // simultaneousGesture : le double-clic agit SANS bloquer
            // la sélection simple-clic native de la List.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if file.isDirectory {
                    selection.removeAll()
                    Task { await model.open(file) }
                } else {
                    downloadFile(file)
                }
            })
            .contextMenu {
                if file.isDirectory {
                    Button("Ouvrir") { Task { await model.open(file) } }
                } else {
                    Button("Télécharger dans « Téléchargements »") {
                        Task { await model.downloadToDownloads(file) }
                    }
                    Button("Télécharger sous…") { downloadFile(file) }
                }
                Divider()
                Button("Supprimer", role: .destructive) {
                    Task { await model.delete([file]) }
                }
            }
            .tag(file.id)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if model.files.isEmpty && !model.isLoading {
                ContentUnavailableView("Dossier vide", systemImage: "folder")
            }
        }
        // Déposer des fichiers depuis le Finder → upload dans le dossier courant.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter {
                ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) == false
            }
            guard !files.isEmpty else { return false }
            Task { for url in files { await model.upload(localURL: url) } }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        Label("Déposer pour envoyer ici", systemImage: "arrow.down.doc.fill")
                            .font(.headline)
                            .foregroundStyle(.tint)
                    }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Fournit un fichier au Finder en le téléchargeant à la demande (file promise).
    private func dragProvider(for file: RemoteFile) -> NSItemProvider {
        let provider = NSItemProvider()
        guard !file.isDirectory else { return provider }
        provider.suggestedName = file.name
        let type = UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(for: type, visibility: .all) { completion in
            Task { @MainActor in
                if let url = await model.downloadToTemp(file) {
                    completion(url, false, nil)
                } else {
                    completion(nil, false, NSError(domain: "term.it", code: 1))
                }
            }
            return nil
        }
        return provider
    }

    // MARK: - Barre de statut

    private var statusBar: some View {
        HStack {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("Astuce : double-clic pour ouvrir un dossier / télécharger un fichier")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        if let status = model.statusMessage { return status }
        let count = model.files.count
        let selected = selection.count
        if selected > 0 { return "\(selected) sélectionné(s) sur \(count)" }
        return "\(count) élément(s)"
    }

    // MARK: - Actions

    private func byteString(_ size: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func iconName(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        case "zip", "gz", "tar", "tgz", "rar", "7z": return "doc.zipper"
        case "pdf": return "doc.richtext"
        case "sh", "bash", "zsh": return "terminal"
        case "json", "yml", "yaml", "xml", "conf", "cfg", "ini": return "gearshape"
        case "js", "ts", "py", "rb", "go", "rs", "swift", "c", "cpp", "java", "php": return "chevron.left.forwardslash.chevron.right"
        case "txt", "md", "log": return "doc.text"
        default: return "doc"
        }
    }

    /// Télécharge un fichier unique via panneau d'enregistrement.
    private func downloadFile(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.download(file, to: url) }
        }
    }

    /// Télécharge la sélection (fichiers) dans un dossier choisi.
    private func downloadSelection() {
        let files = selectedFiles.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        if files.count == 1 {
            downloadFile(files[0])
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Télécharger ici"
        panel.message = "Choisis le dossier de destination"
        if panel.runModal() == .OK, let dir = panel.url {
            Task {
                for file in files {
                    await model.download(file, to: dir.appendingPathComponent(file.name))
                }
            }
        }
    }

    private func deleteSelection() {
        let files = selectedFiles
        guard !files.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Supprimer \(files.count) élément(s) ?"
        alert.informativeText = "Cette action est irréversible."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Supprimer")
        alert.addButton(withTitle: "Annuler")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await model.delete(files); selection.removeAll() }
        }
    }

    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            Task { for url in panel.urls { await model.upload(localURL: url) } }
        }
    }
}
