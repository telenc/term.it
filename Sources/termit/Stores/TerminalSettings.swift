import SwiftUI
import AppKit

/// Un thème de terminal : couleurs de base + palette ANSI optionnelle.
struct TerminalTheme: Identifiable, Hashable {
    let id: String          // = name
    var name: String
    var background: String   // hex #RRGGBB
    var foreground: String
    var cursor: String
    var selection: String
    /// 16 couleurs ANSI (hex). Vide = palette par défaut de SwiftTerm.
    var ansi: [String]

    init(name: String, background: String, foreground: String, cursor: String,
         selection: String, ansi: [String] = []) {
        self.id = name
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
    }
}

enum TerminalThemes {
    static let all: [TerminalTheme] = [
        TerminalTheme(name: "Sombre", background: "#141414", foreground: "#EBEBEB",
                      cursor: "#EBEBEB", selection: "#3A3A3A"),
        TerminalTheme(name: "Nuit profonde", background: "#0B0F19", foreground: "#C8D3F5",
                      cursor: "#82AAFF", selection: "#2D3F76"),
        TerminalTheme(name: "Dracula", background: "#282A36", foreground: "#F8F8F2",
                      cursor: "#FF79C6", selection: "#44475A",
                      ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6",
                             "#8BE9FD", "#F8F8F2", "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
                             "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]),
        TerminalTheme(name: "Solarized Dark", background: "#002B36", foreground: "#839496",
                      cursor: "#93A1A1", selection: "#073642",
                      ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682",
                             "#2AA198", "#EEE8D5", "#002B36", "#CB4B16", "#586E75", "#657B83",
                             "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]),
        TerminalTheme(name: "Clair", background: "#FFFFFF", foreground: "#1E1E1E",
                      cursor: "#000000", selection: "#B4D8FD"),
    ]

    static func theme(named name: String) -> TerminalTheme {
        all.first { $0.name == name } ?? all[0]
    }
}

/// Réglages du terminal, persistés dans UserDefaults. Instance partagée.
@Observable
final class TerminalSettings {
    static let shared = TerminalSettings()

    var themeName: String { didSet { d.set(themeName, forKey: "themeName") } }
    var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    var fontName: String { didSet { d.set(fontName, forKey: "fontName") } }
    var paddingH: Double { didSet { d.set(paddingH, forKey: "paddingH") } }
    var paddingV: Double { didSet { d.set(paddingV, forKey: "paddingV") } }
    /// Synchronisation des connexions via iCloud Drive + iCloud Keychain.
    var iCloudSync: Bool { didSet { d.set(iCloudSync, forKey: "iCloudSync") } }
    /// Notifier (Dock + bannière) quand le terminal sonne (cloche/BEL).
    var notifyOnBell: Bool { didSet { d.set(notifyOnBell, forKey: "notifyOnBell") } }

    private let d = UserDefaults.standard

    private init() {
        themeName = d.string(forKey: "themeName") ?? "Sombre"
        fontSize = d.object(forKey: "fontSize") as? Double ?? 13
        fontName = d.string(forKey: "fontName") ?? "SF Mono"
        paddingH = d.object(forKey: "paddingH") as? Double ?? 14
        paddingV = d.object(forKey: "paddingV") as? Double ?? 12
        iCloudSync = d.object(forKey: "iCloudSync") as? Bool ?? true
        notifyOnBell = d.object(forKey: "notifyOnBell") as? Bool ?? true
    }

    var theme: TerminalTheme { TerminalThemes.theme(named: themeName) }

    /// Polices monospace proposées (filtrées sur celles installées).
    static var availableMonoFonts: [String] {
        let candidates = ["SF Mono", "Menlo", "Monaco", "JetBrains Mono", "Fira Code",
                          "Hack", "Source Code Pro", "Cascadia Code", "Courier New"]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return candidates.filter { installed.contains($0) || $0 == "SF Mono" }
    }
}

// MARK: - Conversion couleurs

extension NSColor {
    /// Crée une couleur sRGB depuis un hex "#RRGGBB".
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}
