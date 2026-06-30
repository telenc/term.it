import SwiftUI

/// Fenêtre Réglages (⌘,) : apparence du terminal.
struct SettingsView: View {
    @Bindable private var settings = TerminalSettings.shared

    var body: some View {
        TabView {
            appearanceTab
                .tabItem { Label("Apparence", systemImage: "paintbrush") }
            syncTab
                .tabItem { Label("Synchronisation", systemImage: "icloud") }
        }
        .frame(width: 480, height: 460)
    }

    private var syncTab: some View {
        Form {
            Section("iCloud") {
                Toggle("Synchroniser via iCloud", isOn: $settings.iCloudSync)
                Text("Synchronise tes connexions entre tes Macs via iCloud Drive, et les mots de passe / clés via iCloud Keychain. Aucun serveur, chiffré par Apple.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Image(systemName: HostSyncService.shared.iCloudAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(HostSyncService.shared.iCloudAvailable ? .green : .orange)
                    Text(HostSyncService.shared.iCloudAvailable
                         ? "iCloud Drive est disponible."
                         : "iCloud Drive n'est pas activé sur ce Mac (Réglages Système › identifiant Apple › iCloud).")
                        .font(.caption)
                }
            }

            Section {
                Text("Note : la synchronisation des mots de passe nécessite que « Trousseau iCloud » soit activé dans tes Réglages Système.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.iCloudSync) { _, enabled in
            KeychainHelper.syncEnabled = enabled
            if enabled { HostSyncService.shared.start() }
            else { HostSyncService.shared.stop() }
        }
    }

    private var appearanceTab: some View {
        Form {
            Section("Thème") {
                Picker("Thème", selection: $settings.themeName) {
                    ForEach(TerminalThemes.all) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
                .pickerStyle(.menu)

                themePreview
            }

            Section("Police") {
                Picker("Police", selection: $settings.fontName) {
                    ForEach(TerminalSettings.availableMonoFonts, id: \.self) { font in
                        Text(font).tag(font)
                    }
                }
                HStack {
                    Text("Taille")
                    Slider(value: $settings.fontSize, in: 9...22, step: 1)
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section("Marges") {
                HStack {
                    Text("Horizontale")
                    Slider(value: $settings.paddingH, in: 0...40, step: 1)
                    Text("\(Int(settings.paddingH))")
                        .monospacedDigit().frame(width: 30, alignment: .trailing)
                }
                HStack {
                    Text("Verticale")
                    Slider(value: $settings.paddingV, in: 0...40, step: 1)
                    Text("\(Int(settings.paddingV))")
                        .monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Aperçu en direct du thème sélectionné.
    private var themePreview: some View {
        let theme = settings.theme
        return VStack(alignment: .leading, spacing: 4) {
            Text("user@serveur ~ %")
                .foregroundStyle(Color(hex: theme.foreground))
            HStack(spacing: 0) {
                Text("$ ").foregroundStyle(Color(hex: theme.cursor))
                Text("ls -la")
                    .foregroundStyle(Color(hex: theme.foreground))
                Text("  ▋").foregroundStyle(Color(hex: theme.cursor))
            }
        }
        .font(.system(size: CGFloat(settings.fontSize), design: .monospaced))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: theme.background), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.1)))
    }
}
