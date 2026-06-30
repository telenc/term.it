import SwiftUI
import SwiftTerm
import AppKit
import NIOCore

/// Échappe un chemin pour le shell (quotes simples si caractères spéciaux).
func shellEscapePath(_ path: String) -> String {
    let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "._-/~".contains($0) }
    if safe { return path }
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Vue SwiftUI qui héberge un `TerminalView` SwiftTerm et le pilote via une `SSHConnection`.
struct SSHTerminalView: NSViewRepresentable {
    let config: SSHConnectionConfig
    /// Apparence (thème + police). Passée en propriété pour que SwiftUI
    /// rappelle `updateNSView` quand elle change.
    var themeName: String
    var fontSize: Double
    var fontName: String
    /// Nom de l'hôte (pour les notifications de cloche).
    var hostName: String = ""
    /// Remonte les erreurs de connexion à l'UI.
    var onError: (String) -> Void = { _ in }
    /// Progression d'un upload (drop sur terminal) ; nil = aucun en cours.
    var onUpload: (UploadStatus?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(config: config, onError: onError)
    }

    func makeNSView(context: Context) -> LocalTerminalView {
        let terminal = LocalTerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.applyAppearance(theme: TerminalThemes.theme(named: themeName),
                                 fontSize: fontSize, fontName: fontName)
        terminal.setupFileDrop()
        // Déposer un fichier sur le terminal → upload vers /tmp puis colle le chemin distant.
        terminal.onDropFileURLs = { [weak coordinator = context.coordinator] urls in
            coordinator?.uploadAndPaste(urls)
        }
        context.coordinator.onUpload = onUpload
        context.coordinator.hostName = hostName
        context.coordinator.attach(terminal)
        return terminal
    }

    func updateNSView(_ nsView: LocalTerminalView, context: Context) {
        nsView.applyAppearance(theme: TerminalThemes.theme(named: themeName),
                               fontSize: fontSize, fontName: fontName)
    }

    static func dismantleNSView(_ nsView: LocalTerminalView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let connection = SSHConnection()
        private let config: SSHConnectionConfig
        private let onError: (String) -> Void
        private weak var terminal: TerminalView?
        private var started = false
        /// Nom d'hôte affiché dans les notifications de cloche.
        var hostName: String = ""

        init(config: SSHConnectionConfig, onError: @escaping (String) -> Void) {
            self.config = config
            self.onError = onError
        }

        private var scrollMonitor: Any?

        func attach(_ terminal: TerminalView) {
            self.terminal = terminal
            installScrollMonitor()
            // Le shell démarre au PREMIER `sizeChanged` (= taille réelle connue),
            // pour éviter de lancer une TUI (claude, vim…) à 0×0 puis redessiner.
            // Filet de sécurité si aucun sizeChanged n'arrive rapidement.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak terminal] in
                guard let self, let terminal, !self.started else { return }
                let t = terminal.getTerminal()
                self.startIfNeeded(cols: max(2, t.cols), rows: max(2, t.rows))
            }
        }

        private func startIfNeeded(cols: Int, rows: Int) {
            guard !started else { return }
            started = true
            Task { await self.run(cols: cols, rows: rows) }
        }

        /// Transmet la molette à l'appli distante quand elle a activé le mouse
        /// reporting (claude code, vim, htop…). Sinon, laisse SwiftTerm scroller
        /// l'historique local.
        private func installScrollMonitor() {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let term = self.terminal,
                      let window = term.window, event.window === window else { return event }
                // Le terminal doit être actif (focus) — évite de voler le scroll
                // de l'onglet Fichiers ou d'une autre session.
                let fr = window.firstResponder
                let terminalFocused = (fr === term) || (fr as? NSView)?.isDescendant(of: term) == true
                guard terminalFocused else { return event }

                let t = term.getTerminal()
                guard t.mouseMode != .off else { return event } // mode normal → SwiftTerm

                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
                guard delta != 0 else { return nil }

                let cols = max(1, t.cols), rows = max(1, t.rows)
                let cellW = term.bounds.width / CGFloat(cols)
                let cellH = term.bounds.height / CGFloat(rows)
                let local = term.convert(event.locationInWindow, from: nil)
                let col = min(cols - 1, max(0, Int(local.x / max(1, cellW))))
                let row = min(rows - 1, max(0, Int((term.bounds.height - local.y) / max(1, cellH))))

                let button = delta > 0 ? 64 : 65 // molette haut / bas (xterm)
                let count: Int
                if event.hasPreciseScrollingDeltas {
                    count = max(1, min(5, Int(abs(delta) / 16)))
                } else {
                    count = max(1, min(5, Int(abs(delta))))
                }
                for _ in 0..<count {
                    t.sendEvent(buttonFlags: button, x: col, y: row)
                }
                return nil // consommé
            }
        }

        private func run(cols: Int, rows: Int) async {
            do {
                try await connection.connect(config)
                try await connection.startShell(cols: cols, rows: rows, initialCommand: config.onConnectCommand) { [weak self] data in
                    Task { @MainActor in
                        self?.terminal?.feed(byteArray: ArraySlice(data))
                    }
                }
            } catch let channelError as ChannelError where Self.isCleanClose(channelError) {
                // Fin de session normale (le shell s'est fermé) : pas une erreur.
                await MainActor.run {
                    self.terminal?.feed(text: "\r\n\u{1b}[2m[Session terminée]\u{1b}[0m\r\n")
                }
            } catch {
                let message = Self.describe(error)
                await MainActor.run { self.onError(message) }
            }
        }

        /// Les fermetures de canal en fin de session ne sont pas des erreurs.
        private static func isCleanClose(_ error: ChannelError) -> Bool {
            switch error {
            case .inputClosed, .eof, .alreadyClosed, .ioOnClosedChannel:
                return true
            default:
                return false
            }
        }

        private static func describe(_ error: Error) -> String {
            if let localized = (error as? LocalizedError)?.errorDescription {
                return localized
            }
            if let channelError = error as? ChannelError {
                return "Connexion interrompue (\(channelError))."
            }
            return "\(error)"
        }

        func teardown() {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
            Task { await connection.disconnect() }
        }

        /// Envoie du texte au shell distant.
        func sendText(_ text: String) {
            Task { try? await connection.send(Data(text.utf8)) }
        }

        /// Notifie l'UI de la progression d'un upload (nil = terminé).
        var onUpload: ((UploadStatus?) -> Void)?

        /// Upload les fichiers déposés vers /tmp du serveur, puis colle leurs chemins distants.
        func uploadAndPaste(_ urls: [URL]) {
            Task {
                defer { Task { @MainActor in self.onUpload?(nil) } }
                var remotePaths: [String] = []
                for url in urls {
                    let name = url.lastPathComponent
                    await MainActor.run { self.onUpload?(UploadStatus(name: name, fraction: 0)) }
                    do {
                        let remote = try await connection.uploadToTmp(localURL: url) { frac in
                            Task { @MainActor in self.onUpload?(UploadStatus(name: name, fraction: frac)) }
                        }
                        remotePaths.append(shellEscapePath(remote))
                    } catch {
                        await MainActor.run {
                            self.terminal?.feed(text: "\r\n\u{1b}[31m[Échec upload \(name): \(error.localizedDescription)]\u{1b}[0m\r\n")
                        }
                    }
                }
                if !remotePaths.isEmpty {
                    sendText(remotePaths.joined(separator: " ") + " ")
                }
            }
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { try? await connection.send(bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 1, newRows > 1 else { return }
            if !started {
                // Première taille réelle → on lance le shell directement à la bonne taille.
                startIfNeeded(cols: newCols, rows: newRows)
            } else {
                Task { await connection.resize(cols: newCols, rows: newRows) }
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let str = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {
            let host = hostName
            let window = source.window
            Task { @MainActor in BellNotifier.handleBell(host: host, window: window) }
        }
        func iTermContent(source: TerminalView, _ content: ArraySlice<UInt8>) {}
    }
}

/// Sous-classe : applique le thème (couleurs + police) choisi dans les réglages.
final class LocalTerminalView: TerminalView {
    /// Appelé quand des fichiers sont déposés : reçoit les URLs locales.
    var onDropFileURLs: (([URL]) -> Void)?

    /// Active la réception de fichiers déposés depuis le Finder.
    func setupFileDrop() {
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
        else { return false }
        onDropFileURLs?(urls)
        return true
    }

    func applyAppearance(theme: TerminalTheme, fontSize: Double, fontName: String) {
        font = Self.makeFont(name: fontName, size: CGFloat(fontSize))
        nativeBackgroundColor = NSColor(hex: theme.background)
        nativeForegroundColor = NSColor(hex: theme.foreground)
        caretColor = NSColor(hex: theme.cursor)
        selectedTextBackgroundColor = NSColor(hex: theme.selection)
        if theme.ansi.count == 16 {
            installColors(theme.ansi.map { SwiftTerm.Color(hex: $0) })
        }
    }

    private static func makeFont(name: String, size: CGFloat) -> NSFont {
        if name == "SF Mono", let f = NSFont(name: "SFMono-Regular", size: size) { return f }
        if let f = NSFont(name: name, size: size) { return f }
        if let f = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension SwiftTerm.Color {
    /// Crée une couleur SwiftTerm (composantes 16 bits) depuis un hex "#RRGGBB".
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = UInt16((value & 0xFF0000) >> 16) * 257
        let g = UInt16((value & 0x00FF00) >> 8) * 257
        let b = UInt16(value & 0x0000FF) * 257
        self.init(red: r, green: g, blue: b)
    }
}
