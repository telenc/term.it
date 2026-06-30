import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Formulaire de création / édition d'un hôte, style feuille Réglages Apple.
struct HostFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// nil = création, sinon édition.
    let host: Host?

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: AuthMethod = .password
    @State private var secret = ""          // mot de passe OU passphrase
    @State private var privateKeyPath = ""
    @State private var colorTag = ""
    @State private var onConnectCommand = ""
    @State private var iconName = "server.rack"
    @State private var iconImageData: Data?

    /// Choix d'icônes SF Symbols proposés.
    private let symbolChoices = [
        // Machines & serveurs
        "server.rack", "desktopcomputer", "macbook", "laptopcomputer", "pc", "display",
        "display.2", "macmini", "macpro.gen3", "xserve", "tv", "appletv",
        "internaldrive", "externaldrive", "externaldrive.connected.to.line.below",
        "opticaldiscdrive", "cpu", "memorychip", "cpu.fill", "memorychip.fill",
        // Terminal & dev
        "terminal", "terminal.fill", "chevron.left.forwardslash.chevron.right",
        "curlybraces", "curlybraces.square", "hammer", "hammer.fill",
        "wrench.and.screwdriver", "wrench.and.screwdriver.fill", "ladybug", "ladybug.fill",
        "ant", "ant.fill", "gearshape", "gearshape.fill", "gearshape.2.fill",
        "play.circle.fill", "command", "puzzlepiece.fill", "shippingbox.fill", "cube.fill",
        // Réseau & cloud
        "network", "globe", "globe.americas.fill", "globe.europe.africa.fill", "wifi",
        "antenna.radiowaves.left.and.right", "dot.radiowaves.left.and.right",
        "cloud", "cloud.fill", "cloud.bolt.fill", "icloud.fill", "point.3.connected.trianglepath.dotted",
        "rectangle.connected.to.line.below", "cable.connector",
        // Sécurité
        "lock.fill", "lock.shield", "lock.shield.fill", "key.fill", "key.horizontal.fill",
        "shield.fill", "shield.lefthalf.filled", "checkmark.shield.fill", "eye.fill",
        // Données
        "cylinder.split.1x2.fill", "tablecells.fill", "chart.bar.fill", "chart.pie.fill",
        "folder.fill", "doc.fill", "archivebox.fill", "tray.full.fill",
        // Divers / fun
        "bolt.fill", "flame.fill", "leaf.fill", "drop.fill", "sparkles", "star.fill",
        "heart.fill", "bell.fill", "flag.fill", "tag.fill", "bookmark.fill",
        "house.fill", "building.2.fill", "building.columns.fill", "briefcase.fill",
        "gamecontroller.fill", "cart.fill", "creditcard.fill", "envelope.fill",
        "person.fill", "person.2.fill", "crown.fill", "moon.fill", "sun.max.fill",
        "paperplane.fill", "rocket", "brain.head.profile", "atom"
    ]

    /// Ne conserve que les SF Symbols réellement présents sur ce système.
    private var availableSymbols: [String] {
        symbolChoices.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    }

    private var isValid: Bool {
        !name.isEmpty && !hostname.isEmpty && !username.isEmpty && Int(port) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Général") {
                    TextField("Nom", text: $name, prompt: Text("Mon serveur"))
                    TextField("Adresse", text: $hostname, prompt: Text("exemple.com ou 192.168.1.10"))
                    TextField("Port", text: $port)
                    TextField("Utilisateur", text: $username, prompt: Text("root"))
                }

                Section("Authentification") {
                    Picker("Méthode", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch authMethod {
                    case .password:
                        SecureField("Mot de passe", text: $secret)
                    case .privateKey:
                        HStack {
                            TextField("Chemin de la clé", text: $privateKeyPath,
                                      prompt: Text("~/.ssh/id_ed25519"))
                            Button("Parcourir…") { chooseKeyFile() }
                        }
                        SecureField("Passphrase (optionnel)", text: $secret)
                    }
                }

                Section("Sécurité") {
                    Button("Oublier la clé du serveur connue") {
                        if let p = Int(port) {
                            KnownHostsStore.forget(host: hostname, port: p)
                        }
                    }
                    .disabled(hostname.isEmpty)
                    Text("À utiliser si la clé du serveur a légitimement changé (réinstallation, etc.). La prochaine connexion re-mémorisera la nouvelle clé.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Au démarrage") {
                    TextField("Commande (snippet)", text: $onConnectCommand,
                              prompt: Text("ex. cd /var/www && ls -la"))
                    Text("Exécutée automatiquement à chaque connexion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Étiquette") {
                    Picker("Couleur", selection: $colorTag) {
                        Text("Aucune").tag("")
                        Text("Rouge").tag("red")
                        Text("Orange").tag("orange")
                        Text("Vert").tag("green")
                        Text("Bleu").tag("blue")
                        Text("Violet").tag("purple")
                    }
                }

                Section("Icône") {
                    iconSection
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(host == nil ? "Ajouter" : "Enregistrer") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 460, height: 480)
        .onAppear(perform: load)
    }

    // MARK: - Section icône

    @ViewBuilder
    private var iconSection: some View {
        // Aperçu courant + import / réinitialisation d'image.
        HStack(spacing: 12) {
            Group {
                if let data = iconImageData, let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 22))
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Button("Importer une image…") { chooseImage() }
                if iconImageData != nil {
                    Button("Retirer l'image", role: .destructive) { iconImageData = nil }
                        .font(.caption)
                }
            }
            Spacer()
        }

        // Grille de SF Symbols (désactivée visuellement si une image est définie).
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
            ForEach(availableSymbols, id: \.self) { symbol in
                Button {
                    iconName = symbol
                    iconImageData = nil
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 16))
                        .frame(width: 30, height: 30)
                        .background(
                            (iconImageData == nil && iconName == symbol)
                                ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .foregroundStyle((iconImageData == nil && iconName == symbol) ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(iconImageData == nil ? 1 : 0.4)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .image]
        if panel.runModal() == .OK, let url = panel.url,
           let image = NSImage(contentsOf: url) {
            iconImageData = Self.pngData(from: image, maxSize: 128)
        }
    }

    /// Redimensionne et encode l'image en PNG (≤ maxSize px) pour limiter le poids.
    private static func pngData(from image: NSImage, maxSize: CGFloat) -> Data? {
        let side = min(maxSize, max(image.size.width, image.size.height))
        let target = NSImage(size: NSSize(width: side, height: side))
        target.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func load() {
        guard let host else { return }
        name = host.name
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        privateKeyPath = host.privateKeyPath ?? ""
        colorTag = host.colorTag ?? ""
        onConnectCommand = host.onConnectCommand ?? ""
        iconName = host.iconName ?? "server.rack"
        iconImageData = host.iconImageData
        secret = KeychainHelper.read(account: host.keychainAccount) ?? ""
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: ("~/.ssh" as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            privateKeyPath = url.path
        }
    }

    private func save() {
        let portValue = Int(port) ?? 22
        let target: Host
        if let host {
            target = host
        } else {
            target = Host(name: name, hostname: hostname, port: portValue, username: username)
            context.insert(target)
        }
        target.name = name
        target.hostname = hostname
        target.port = portValue
        target.username = username
        target.authMethod = authMethod
        target.privateKeyPath = authMethod == .privateKey ? privateKeyPath : nil
        target.colorTag = colorTag.isEmpty ? nil : colorTag
        target.onConnectCommand = onConnectCommand.isEmpty ? nil : onConnectCommand
        target.iconName = iconName
        target.iconImageData = iconImageData
        target.updatedAt = Date()

        // Secret (mot de passe ou passphrase) → Keychain uniquement.
        if secret.isEmpty {
            KeychainHelper.delete(account: target.keychainAccount)
        } else {
            KeychainHelper.save(secret, account: target.keychainAccount)
        }

        NotificationCenter.default.post(name: .hostsChanged, object: nil)
        dismiss()
    }
}
