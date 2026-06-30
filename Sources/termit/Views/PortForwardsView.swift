import SwiftUI
import SwiftData

/// Feuille de gestion des redirections de port (tunnels) d'un hôte.
struct PortForwardsView: View {
    let host: Host
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allForwards: [PortForward]

    private var manager = PortForwardManager.shared

    init(host: Host) {
        self.host = host
        let hostID = host.id
        _allForwards = Query(filter: #Predicate { $0.hostID == hostID })
    }

    // Champs du nouveau tunnel.
    @State private var localPort = ""
    @State private var remoteHost = "localhost"
    @State private var remotePort = ""
    @State private var label = ""

    private var canAdd: Bool {
        Int(localPort) != nil && Int(remotePort) != nil && !remoteHost.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                Section("Tunnels") {
                    if allForwards.isEmpty {
                        Text("Aucun tunnel. Ajoute-en un ci-dessous.")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    ForEach(allForwards) { fwd in
                        forwardRow(fwd)
                    }
                }
                Section("Nouveau tunnel local") {
                    HStack {
                        TextField("Port local", text: $localPort).frame(width: 90)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Hôte cible", text: $remoteHost)
                        Text(":").foregroundStyle(.secondary)
                        TextField("Port", text: $remotePort).frame(width: 70)
                    }
                    TextField("Étiquette (optionnel)", text: $label)
                    Button("Ajouter le tunnel") { add() }
                        .disabled(!canAdd)
                    Text("Exemple : port local 8080 → localhost:80 rend le port 80 du serveur accessible sur localhost:8080 de ton Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 460)
        .alert("Erreur de tunnel", isPresented: .init(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(manager.errorMessage ?? "") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Redirections de port").font(.headline)
                Text(host.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private func forwardRow(_ fwd: PortForward) -> some View {
        let running = manager.isActive(fwd.id)
        return HStack(spacing: 12) {
            Circle().fill(running ? .green : .secondary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(fwd.label.isEmpty ? "Tunnel" : fwd.label)
                    .font(.body)
                Text("127.0.0.1:\(fwd.localPort)  →  \(fwd.remoteHost):\(fwd.remotePort)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(running ? "Arrêter" : "Démarrer") {
                Task { await manager.toggle(fwd, host: host) }
            }
            .buttonStyle(.bordered)
            Button(role: .destructive) {
                Task { await manager.stop(fwd); context.delete(fwd) }
            } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func add() {
        guard let lp = Int(localPort), let rp = Int(remotePort) else { return }
        let fwd = PortForward(hostID: host.id, localPort: lp, remoteHost: remoteHost,
                              remotePort: rp, label: label)
        context.insert(fwd)
        localPort = ""; remotePort = ""; label = ""; remoteHost = "localhost"
    }
}
