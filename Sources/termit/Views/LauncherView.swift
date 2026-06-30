import SwiftUI
import AppKit

/// Écran d'accueil : sélection d'une connexion à ouvrir.
/// Esthétique sombre type lanceur de terminal.
struct LauncherView: View {
    let hosts: [Host]
    var canDismiss: Bool
    var onPick: (Host) -> Void
    var onDismiss: () -> Void
    var onAdd: () -> Void
    var onEdit: (Host) -> Void
    var onDelete: (Host) -> Void
    var onDuplicate: (Host) -> Void

    @State private var search = ""
    @State private var hoveredID: Host.ID?

    private var filtered: [Host] {
        guard !search.isEmpty else { return hosts }
        return hosts.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.hostname.localizedCaseInsensitiveContains(search) ||
            $0.username.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ZStack {
            // Fond sombre dégradé.
            LinearGradient(
                colors: [Color(white: 0.10), Color(white: 0.05)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .onTapGesture { if canDismiss { onDismiss() } }

            VStack(spacing: 18) {
                header

                if hosts.isEmpty {
                    emptyState
                } else {
                    searchField
                    hostList
                }
            }
            .frame(maxWidth: 460)
            .padding(40)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.tint)
            Text("term.it")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("Choisis une connexion")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Rechercher un hôte…", text: $search)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
    }

    private var hostList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(filtered) { host in
                    hostRow(host)
                }
                addButton
            }
        }
        .frame(maxHeight: 420)
    }

    private func hostRow(_ host: Host) -> some View {
        Button {
            onPick(host)
        } label: {
            HStack(spacing: 12) {
                HostIconView(host: host, size: 16)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.system(size: 14, weight: .medium))
                    Text("\(host.username)@\(host.hostname):\(host.port)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.tint)
                    .opacity(hoveredID == host.id ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                (hoveredID == host.id ? Color.white.opacity(0.08) : Color.white.opacity(0.03)),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredID = inside ? host.id : (hoveredID == host.id ? nil : hoveredID)
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .contextMenu {
            Button("Modifier…") { onEdit(host) }
            Button("Dupliquer") { onDuplicate(host) }
            Divider()
            Button("Supprimer", role: .destructive) { onDelete(host) }
        }
    }

    private var addButton: some View {
        Button(action: onAdd) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                Text("Nouvel hôte")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("Aucun hôte enregistré")
                .foregroundStyle(.secondary)
            Button(action: onAdd) {
                Label("Ajouter ton premier serveur", systemImage: "plus")
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 20)
    }
}
