import RSKeeperApplication
import RSKeeperDesignSystem
import RSKeeperDomain
import SwiftUI
import UniformTypeIdentifiers

/// Tela de conexões (NST-03-01; SCR-CONN-01/02): sidebar à esquerda (fixadas, salvas, recentes, cada
/// uma com contador) e, à direita, o formulário ou as boas-vindas.
public struct ConnectionScreen: View {
    @Bindable private var model: ConnectionsModel

    public init(model: ConnectionsModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 0) {
            ConnectionSidebar(model: model)
                .frame(width: 260)
                .background(Color.rk(.surfaceSidebar))
            Divider()
            Group {
                if model.draft != nil {
                    ConnectionForm(model: model)
                } else {
                    welcome
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.rk(.surfaceContent))
        }
        .sheet(isPresented: $model.showsDriverPicker) { DriverPickerSheet(model: model) }
        .sheet(isPresented: $model.showsURLImport) { URLImportSheet(model: model) }
        // [CONFIRMADO, S2] arrastar um arquivo SQLite preenche o formulário (NST-03-03, crit. 4).
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await model.useFile(url) }
            }
            return true
        }
        .background {
            // ⌘N: nova conexão nesta tela [DECISÃO] (⌘⇧N reabre a janela de qualquer lugar).
            Button("") { model.newConnection() }.keyboardShortcut("n", modifiers: .command).hidden()
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    /// [CONFIRMADO CAP-01] boas-vindas com "Nova conexão" e "Importar de URL" (textos próprios).
    private var welcome: some View {
        RKEmptyState(String(localized: "Welcome to RSKeeper"),
                     message: String(localized: "Create a connection or paste a connection URL."),
                     systemImage: "cylinder.split.1x2",
                     hints: [(String(localized: "New connection"), ["⌘", "N"])]) {
            Button(String(localized: "New Connection")) { model.newConnection() }
                .buttonStyle(.rk(.primary))
                .accessibilityIdentifier("rk.connections.new")
            Button(String(localized: "Import from URL")) { model.showsURLImport = true }
                .buttonStyle(.rk(.secondary))
                .accessibilityIdentifier("rk.connections.importURL")
        }
        .accessibilityIdentifier("rk.connections.emptyState")
    }
}

/// Item da sidebar: a mesma conexão pode aparecer em mais de uma seção.
struct SidebarItem: Hashable {
    enum Section: Hashable { case pinned, saved, recent }
    let section: Section
    let id: ProfileID
}

struct ConnectionSidebar: View {
    @Bindable var model: ConnectionsModel
    @State private var selection: SidebarItem?

    var body: some View {
        VStack(alignment: .leading, spacing: RKSpacing.s2) {
            RKSearchField(String(localized: "Filter connections"), text: $model.filter)
                .padding(.horizontal, RKSpacing.s2)
                .padding(.top, RKSpacing.s2)
                .accessibilityIdentifier("rk.connections.filter")
            List(selection: $selection) {
                section(.pinned, String(localized: "Pinned"), model.filtered(model.sidebar.pinned))
                section(.saved, String(localized: "Saved"), model.filtered(model.sidebar.saved))
                section(.recent, String(localized: "Recent"), model.filtered(model.sidebar.recent))
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("rk.connections.list")
            // Teclado: setas na lista; Enter conecta (NST-03-01, crit. 5).
            .onKeyPress(.return) {
                guard model.selection != nil else { return .ignored }
                model.connect()
                return .handled
            }
            .onChange(of: selection) { _, item in model.select(item?.id) }
            Button {
                model.newConnection()
            } label: {
                Label(String(localized: "New Connection"), systemImage: "plus")
            }
            .buttonStyle(.rk(.ghost))
            .padding(RKSpacing.s2)
        }
    }

    @ViewBuilder
    private func section(_ kind: SidebarItem.Section, _ title: String, _ profiles: [ConnectionProfile]) -> some View {
        Section {
            ForEach(profiles) { profile in
                ConnectionRow(profile: profile)
                    .tag(SidebarItem(section: kind, id: profile.id))
                    .contextMenu {
                        let pinned = model.sidebar.pinned.contains { $0.id == profile.id }
                        Button(pinned ? String(localized: "Unpin") : String(localized: "Pin")) { model.togglePin(profile) }
                        Button(String(localized: "Connect")) { model.select(profile.id); model.connect() }
                        Divider()
                        Button(String(localized: "Delete"), role: .destructive) { model.delete(profile) }
                    }
            }
        } header: {
            HStack {
                Text(title.uppercased()).rkTypography(.section).foregroundStyle(.rk(.textSecondary))
                RKCounterBadge(profiles.count)
            }
        }
    }
}

/// Linha com a barra de cor do rótulo (docs/ui/04 §8.1); o nome sempre visível, a cor nunca sozinha.
struct ConnectionRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: RKSpacing.s2) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.rk(profile.labelColor.token))
                .frame(width: 3, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(profile.name).rkTypography(.body).foregroundStyle(.rk(.textPrimary)).lineLimit(1)
                Text(profile.subtitle).rkTypography(.caption).foregroundStyle(.rk(.textSecondary)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if profile.environment == .production {
                RKBadge(String(localized: "PROD"), tone: .danger, outlined: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("rk.connections.row.\(profile.name)")
    }
}

extension LabelColor {
    var token: RKColorToken {
        switch self {
        case .none: .labelNone
        case .slate: .labelSlate
        case .teal: .labelTeal
        case .blue: .labelBlue
        case .violet: .labelViolet
        case .green: .labelGreen
        case .amber: .labelAmber
        case .red: .labelRed
        }
    }
}

extension ConnectionProfile {
    /// Linha secundária: arquivo ou host, sem segredo.
    var subtitle: String {
        switch target {
        case .file(let grant, _): URL(fileURLWithPath: grant.displayPath).lastPathComponent
        case .server(let host, let port, let user, _): (user.map { "\($0)@" } ?? "") + "\(host):\(port)"
        }
    }
}
