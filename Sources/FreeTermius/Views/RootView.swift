import SwiftUI
import SwiftData
import AppKit

/// Affiche le curseur « main » au survol (SwiftUI macOS ne le fait pas seul).
extension View {
    func pointerCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
        }
    }
}

/// Affiche l'icône d'un hôte : image personnalisée, sinon SF Symbol, sinon défaut.
struct HostIconView: View {
    let host: Host
    var size: CGFloat = 16

    var body: some View {
        if let data = host.iconImageData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size * 1.4, height: size * 1.4)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: host.iconName ?? "server.rack")
                .font(.system(size: size))
                .foregroundStyle(host.colorTag.flatMap(Color.init(tag:)) ?? .accentColor)
        }
    }
}

/// Duplique un hôte (champs + secret du trousseau) dans le contexte donné.
@MainActor
func duplicateHost(_ host: Host, in context: ModelContext) {
    let copy = Host(
        name: host.name + " copie",
        hostname: host.hostname,
        port: host.port,
        username: host.username,
        authMethod: host.authMethod,
        privateKeyPath: host.privateKeyPath,
        colorTag: host.colorTag
    )
    copy.iconName = host.iconName
    copy.iconImageData = host.iconImageData
    copy.onConnectCommand = host.onConnectCommand
    context.insert(copy)
    // Copie le secret associé dans le trousseau.
    if let secret = KeychainHelper.read(account: host.keychainAccount) {
        KeychainHelper.save(secret, account: copy.keychainAccount)
    }
    NotificationCenter.default.post(name: .hostsChanged, object: nil)
}

extension Notification.Name {
    /// Émise quand un hôte est créé/modifié/dupliqué → déclenche l'export iCloud.
    static let hostsChanged = Notification.Name("hostsChanged")
}

extension Color {
    /// Convertit un nom d'étiquette stocké en couleur d'accent.
    init?(tag: String) {
        switch tag {
        case "red": self = .red
        case "orange": self = .orange
        case "yellow": self = .yellow
        case "green": self = .green
        case "blue": self = .blue
        case "purple": self = .purple
        case "pink": self = .pink
        default: return nil
        }
    }
}

// MARK: - Modèle de sessions

enum SessionTab { case terminal, files }

/// Une connexion active (un onglet terminal/FTP vers un hôte).
@Observable
final class TermSession: Identifiable {
    let id = UUID()
    let host: Host
    var tab: SessionTab = .terminal
    init(host: Host) { self.host = host }
}

/// Gère l'ensemble des sessions ouvertes et la session active.
@Observable
@MainActor
final class SessionsStore {
    var sessions: [TermSession] = []
    var activeID: TermSession.ID?
    /// Affiche l'écran de sélection par-dessus une session active.
    var showLauncher = false

    var active: TermSession? { sessions.first { $0.id == activeID } }

    func open(_ host: Host) {
        // Réutilise une session existante vers le même hôte (évite les doublons).
        if let existing = sessions.first(where: { $0.host.id == host.id }) {
            activeID = existing.id
            showLauncher = false
            return
        }
        let session = TermSession(host: host)
        sessions.append(session)
        activeID = session.id
        showLauncher = false
    }

    func activate(_ id: TermSession.ID) {
        activeID = id
        showLauncher = false
    }

    func close(_ id: TermSession.ID) {
        sessions.removeAll { $0.id == id }
        if activeID == id { activeID = sessions.last?.id }
    }
}

// MARK: - Vue racine

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Host.name) private var hosts: [Host]

    @Environment(\.openWindow) private var openWindow
    private let settings = TerminalSettings.shared
    @State private var store = SessionsStore()
    @State private var hoverTop = false
    @State private var hoverLeft = false
    @State private var confirmDetach: TermSession?

    private var windowTitle: String {
        store.active?.host.name ?? "FreeTermius"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.07).ignoresSafeArea()
            WindowConfigurator(title: windowTitle)

            // Contenu : toutes les sessions montées, seule l'active est visible
            // (pour garder les connexions vivantes en changeant de session).
            ForEach(store.sessions) { session in
                SessionContent(session: session) { message in
                    // erreurs gérées dans SessionContent
                    _ = message
                }
                .opacity(session.id == store.activeID ? 1 : 0)
                .allowsHitTesting(session.id == store.activeID)
            }

            // Écran d'accueil : aucune session, ou bouton +.
            if store.sessions.isEmpty || store.showLauncher {
                LauncherView(
                    hosts: hosts,
                    canDismiss: !store.sessions.isEmpty,
                    onPick: { store.open($0) },
                    onDismiss: { store.showLauncher = false },
                    onAdd: { showAddHost = true },
                    onEdit: { editingHost = $0 },
                    onDelete: deleteHost,
                    onDuplicate: { duplicateHost($0, in: context) }
                )
                .transition(.opacity)
            }

            // Barres flottantes (seulement quand une session est visible).
            if store.active != nil && !store.showLauncher {
                topRevealBar
                leftRevealDock
            }
        }
        .animation(.easeInOut(duration: 0.18), value: hoverTop)
        .animation(.easeInOut(duration: 0.18), value: hoverLeft)
        .animation(.easeInOut(duration: 0.2), value: store.showLauncher)
        .animation(.easeInOut(duration: 0.2), value: store.sessions.count)
        .sheet(isPresented: $showAddHost) { HostFormView(host: nil) }
        .sheet(item: $editingHost) { HostFormView(host: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .newHostRequested)) { _ in
            if store.sessions.isEmpty { showAddHost = true }
            else { store.showLauncher = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hostsChanged)) { _ in
            HostSyncService.shared.exportNow()
        }
        .onAppear {
            // Démarre la synchronisation iCloud selon le réglage.
            KeychainHelper.syncEnabled = settings.iCloudSync
            HostSyncService.shared.configure(context: context)
            if settings.iCloudSync { HostSyncService.shared.start() }
        }
        .confirmationDialog(
            "Détacher cette connexion ?",
            isPresented: Binding(get: { confirmDetach != nil },
                                 set: { if !$0 { confirmDetach = nil } }),
            presenting: confirmDetach
        ) { session in
            Button("Détacher") { performDetach(session) }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("La connexion sera rouverte dans une nouvelle fenêtre (reconnexion au serveur).")
        }
    }

    private func performDetach(_ session: TermSession) {
        openWindow(id: detachedWindowID, value: session.host.persistentModelID)
        store.close(session.id)
    }

    @State private var showAddHost = false
    @State private var editingHost: Host?

    private func deleteHost(_ host: Host) {
        let id = host.id
        KeychainHelper.delete(account: host.keychainAccount)
        context.delete(host)
        HostSyncService.shared.markDeleted(id)
    }

    // MARK: Barre du haut (Terminal / FTP)

    private var topRevealBar: some View {
        VStack(spacing: 0) {
            // Conteneur de survol borné (64 px en haut). La barre vit DEDANS,
            // donc aller du vide aux boutons ne fait jamais sortir le curseur.
            ZStack(alignment: .top) {
                Color.clear
                if let session = store.active {
                    SessionTabsCapsule(session: session, showDetach: true) {
                        confirmDetach = session
                    }
                    .padding(.top, 8)
                    .opacity(hoverTop ? 1 : 0)
                    .offset(y: hoverTop ? 0 : -12)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .contentShape(Rectangle())
            .onHover { hoverTop = $0 }

            Spacer(minLength: 0)
        }
    }

    // MARK: Dock de gauche (sessions actives + )

    private var leftRevealDock: some View {
        HStack(spacing: 0) {
            // Conteneur de survol borné (74 px à gauche), dock inclus → pas de flicker.
            ZStack(alignment: .leading) {
                Color.clear
                VStack(spacing: 10) {
                    ForEach(store.sessions) { session in
                        dockButton(session)
                    }
                    Divider().frame(width: 28).overlay(.white.opacity(0.1))
                    Button {
                        store.showLauncher = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Nouvelle connexion")
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 3)
                .padding(.leading, 10)
                .opacity(hoverLeft ? 1 : 0)
                .offset(x: hoverLeft ? 0 : -20)
            }
            .frame(maxHeight: .infinity)
            .frame(width: 74)
            .contentShape(Rectangle())
            .onHover { hoverLeft = $0 }

            Spacer(minLength: 0)
        }
    }

    private func dockButton(_ session: TermSession) -> some View {
        let isActive = session.id == store.activeID
        return Button {
            store.activate(session.id)
        } label: {
            ZStack(alignment: .topTrailing) {
                HostIconView(host: session.host, size: 16)
                    .frame(width: 40, height: 40)
                    .background(
                        isActive ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .foregroundStyle(isActive ? .white : .secondary)
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(session.host.name)
        .contextMenu {
            Button("Modifier…") { editingHost = session.host }
            Button("Dupliquer") { duplicateHost(session.host, in: context) }
            Divider()
            Button("Fermer", role: .destructive) { store.close(session.id) }
        }
    }
}

// MARK: - Contenu d'une session (terminal + FTP empilés)

struct SessionContent: View {
    let session: TermSession
    var onError: (String) -> Void

    @State private var didLoadFiles = false
    @State private var errorMessage: String?
    @State private var uploading = false
    private let settings = TerminalSettings.shared

    var body: some View {
        ZStack {
            // Terminal : toujours monté tant que la session vit.
            // Padding + fond issus du thème (même couleur → pas de décalage).
            SSHTerminalView(
                config: CredentialResolver.makeConfig(for: session.host),
                themeName: settings.themeName,
                fontSize: settings.fontSize,
                fontName: settings.fontName,
                onError: { errorMessage = $0 },
                onUploading: { uploading = $0 }
            )
            .padding(.horizontal, settings.paddingH)
            .padding(.bottom, settings.paddingV)
            // Réserve l'espace en haut (boutons de fenêtre + barre au survol).
            .padding(.top, settings.paddingV + 28)
            .background(Color(hex: settings.theme.background))
            .opacity(session.tab == .terminal ? 1 : 0)
            .allowsHitTesting(session.tab == .terminal)

            // FTP : monté à la première utilisation, puis conservé.
            if didLoadFiles {
                SFTPBrowserView(host: session.host)
                    .opacity(session.tab == .files ? 1 : 0)
                    .allowsHitTesting(session.tab == .files)
            }
        }
        .overlay {
            if uploading {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Envoi du fichier…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: uploading)
        .background(Color(white: 0.07))
        .ignoresSafeArea()
        .onChange(of: session.tab) { _, newValue in
            if newValue == .files { didLoadFiles = true }
        }
        .alert("Erreur de connexion", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

// MARK: - Configuration de la fenêtre

/// Rend la barre de titre transparente (le terminal passe dessous) et y affiche
/// le nom de la connexion active, visible en permanence.
private struct WindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(hex: TerminalSettings.shared.theme.background)
        window.title = title
    }
}

// MARK: - Capsule d'onglets (Terminal / Fichiers + détacher)

struct SessionTabsCapsule: View {
    let session: TermSession
    var showDetach: Bool = false
    var onDetach: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            tab("terminal", "Terminal", session.tab == .terminal) { session.tab = .terminal }
            tab("folder", "Fichiers", session.tab == .files) { session.tab = .files }
            if showDetach {
                Divider().frame(height: 16).overlay(.white.opacity(0.15))
                Button(action: onDetach) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).pointerCursor()
                .help("Détacher dans une nouvelle fenêtre")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    private func tab(_ symbol: String, _ label: String, _ active: Bool,
                     _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(active ? Color.accentColor.opacity(0.9) : Color.clear, in: Capsule())
                .foregroundStyle(active ? .white : .secondary)
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

// MARK: - Fenêtre détachée (une seule session)

struct DetachedSessionView: View {
    let hostID: PersistentIdentifier
    @Environment(\.modelContext) private var context
    @State private var session: TermSession?
    @State private var hoverTop = false

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.07).ignoresSafeArea()
            if let session {
                WindowConfigurator(title: session.host.name)
                SessionContent(session: session) { _ in }
                topBar(session)
            }
        }
        .onAppear {
            if session == nil, let host = context.model(for: hostID) as? Host {
                session = TermSession(host: host)
            }
        }
    }

    private func topBar(_ session: TermSession) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.clear
                SessionTabsCapsule(session: session)
                    .padding(.top, 8)
                    .opacity(hoverTop ? 1 : 0)
                    .offset(y: hoverTop ? 0 : -12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .contentShape(Rectangle())
            .onHover { hoverTop = $0 }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.18), value: hoverTop)
    }
}
