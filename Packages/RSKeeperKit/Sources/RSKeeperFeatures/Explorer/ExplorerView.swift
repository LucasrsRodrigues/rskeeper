import AppKit
import RSKeeperApplication
import RSKeeperDesignSystem
import SwiftUI

/// Explorador (NST-05-02; SCR-WS-02; CAP-04/04B/09): seletor de database, atualizar, filtro, cabeçalho
/// "ENTIDADES" com contador e árvore por schema em `NSOutlineView` (ADR-N10).
public struct ExplorerView: View {
    @Bindable private var model: ExplorerModel

    public init(model: ExplorerModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: RKSpacing.s2) {
            HStack(spacing: RKSpacing.s1) {
                Image(systemName: "cylinder").foregroundStyle(.rk(.textSecondary)).accessibilityHidden(true)
                Text(model.database ?? "—").rkTypography(.bodyEmphasis).lineLimit(1)
                    .accessibilityIdentifier("rk.explorer.database")
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.rk(.ghost))
                .help(String(localized: "Refresh"))
                .accessibilityLabel(Text(String(localized: "Refresh")))
                .accessibilityIdentifier("rk.explorer.refresh")
            }
            RKSearchField(String(localized: "Filter entities"), text: $model.filter)
                .accessibilityIdentifier("rk.explorer.filter")
            HStack {
                Text(String(localized: "ENTITIES")).rkTypography(.section).foregroundStyle(.rk(.textSecondary))
                RKCounterBadge(model.entityCount)
                if model.isLoading { RKProgress() }
            }
            if let error = model.error {
                RKInlineBanner(.error, message: error)
            }
            ExplorerOutline(model: model)
                .accessibilityIdentifier("rk.explorer.tree")
        }
        .padding(RKSpacing.s2)
        .task { if model.database == nil { await model.load() } }
    }
}

/// Nós da árvore (classes: `NSOutlineView` identifica itens por referência).
final class ExplorerNode: NSObject {
    enum Kind { case schema(String), entity(ExplorerEntity), column(ExplorerColumn) }
    let kind: Kind
    var children: [ExplorerNode]?
    init(_ kind: Kind) { self.kind = kind }
}

struct ExplorerOutline: NSViewRepresentable {
    let model: ExplorerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ExplorerOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        column.resizingMask = .autoresizingMask
        outline.rowSizeStyle = .small
        outline.allowsTypeSelect = true
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.openSelected)
        outline.onOpen = { [weak coordinator = context.coordinator] in coordinator?.openSelected() }
        outline.menu = context.coordinator.contextMenu
        outline.setAccessibilityLabel(String(localized: "Entities"))
        context.coordinator.outline = outline
        let scroll = NSScrollView()
        scroll.documentView = outline
        outline.sizeLastColumnToFit()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.reloadIfNeeded(revision: model.revision, filter: model.filter)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let model: ExplorerModel
        weak var outline: NSOutlineView?
        private var roots: [ExplorerNode] = []
        private var lastRevision = -1
        private var lastFilter = ""

        init(model: ExplorerModel) { self.model = model }

        func reloadIfNeeded(revision: Int, filter: String) {
            guard revision != lastRevision || filter != lastFilter else { return }
            let expanded = Set(roots.filter { outline?.isItemExpanded($0) == true }.compactMap { node -> String? in
                if case .schema(let name) = node.kind { return name }
                return nil
            })
            lastRevision = revision
            lastFilter = filter
            roots = model.visibleSchemas.map { ExplorerNode(.schema($0)) }
            outline?.reloadData()
            for node in roots {
                guard case .schema(let name) = node.kind else { continue }
                let userSchema = !ExplorerModel.systemSchemas.contains(name)
                if expanded.contains(name) || (userSchema && lastRevision > 0) || !filter.isEmpty {
                    outline?.expandItem(node)
                }
            }
        }

        private func children(of node: ExplorerNode?) -> [ExplorerNode] {
            guard let node else { return roots }
            if let children = node.children { return children }
            switch node.kind {
            case .schema(let schema):
                guard model.entities[schema] != nil else { return [] }
                node.children = model.visibleEntities(schema).map { ExplorerNode(.entity($0)) }
            case .entity(let entity):
                guard let columns = model.columns[entity.id] else { return [] }
                node.children = columns.map { ExplorerNode(.column($0)) }
            case .column:
                node.children = []
            }
            return node.children ?? []
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item as? ExplorerNode).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item as? ExplorerNode)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? ExplorerNode else { return false }
            switch node.kind {
            case .schema: return true
            case .entity(let entity): return entity.kind != .routine
            case .column: return false
            }
        }

        /// Carga sob demanda (crit. 4: 10.000 tabelas sem travar o MainActor): se os filhos ainda não
        /// vieram, carrega e recusa esta expansão; ao terminar, expande de novo, já com filhos.
        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? ExplorerNode else { return false }
            let loaded: Bool = switch node.kind {
            case .schema(let schema): model.entities[schema] != nil
            case .entity(let entity): model.columns[entity.id] != nil
            case .column: true
            }
            guard !loaded else { return true }
            Task { @MainActor [weak outlineView] in
                switch node.kind {
                case .schema(let schema): await model.loadEntities(schema)
                case .entity(let entity): await model.loadColumns(entity)
                case .column: return
                }
                node.children = nil
                outlineView?.reloadItem(node, reloadChildren: true)
                outlineView?.expandItem(node)
            }
            return false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? ExplorerNode else { return nil }
            let cell = outlineView.makeView(withIdentifier: ExplorerCell.identifier, owner: nil) as? ExplorerCell ?? ExplorerCell()
            switch node.kind {
            case .schema(let name):
                cell.configure(symbol: "folder", title: name, detail: nil, identifier: "rk.explorer.schema.\(name)")
            case .entity(let entity):
                let symbol = switch entity.kind {
                case .table: "tablecells"
                case .view: "eye"
                case .materializedView: "square.stack.3d.up"
                case .routine: "function"
                }
                cell.configure(symbol: symbol, title: entity.name, detail: nil, identifier: "rk.explorer.entity.\(entity.name)")
            case .column(let column):
                // [CONFIRMADO CAP-04B/09] colunas com o tipo alinhado à direita (G-11b).
                cell.configure(symbol: column.isPrimaryKey ? "key.fill" : "minus", title: column.name,
                               detail: column.declaredType, identifier: "rk.explorer.column.\(column.name)")
            }
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            guard let node = item as? ExplorerNode else { return nil }
            switch node.kind {
            case .schema(let name): return name
            case .entity(let entity): return entity.name
            case .column(let column): return column.name
            }
        }

        @objc func openSelected() {
            guard let outline, outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? ExplorerNode,
                  case .entity(let entity) = node.kind else { return }
            model.open(entity)
        }

        @objc func copyName() {
            guard let outline, outline.clickedRow >= 0 || outline.selectedRow >= 0 else { return }
            let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
            guard let node = outline.item(atRow: row) as? ExplorerNode else { return }
            let name: String = switch node.kind {
            case .schema(let name): name
            case .entity(let entity): entity.name
            case .column(let column): column.name
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
        }

        @objc func refresh() { Task { await model.refresh() } }

        /// Menu de contexto (ADR-N15). Também abre pelo teclado (⇧F10 / tecla de menu do macOS).
        lazy var contextMenu: NSMenu = {
            let menu = NSMenu()
            menu.addItem(withTitle: String(localized: "Open"), action: #selector(openSelectedFromMenu), keyEquivalent: "").target = self
            menu.addItem(withTitle: String(localized: "Copy Name"), action: #selector(copyName), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Refresh"), action: #selector(refresh), keyEquivalent: "").target = self
            return menu
        }()

        @objc private func openSelectedFromMenu() {
            if let outline, outline.clickedRow >= 0 { outline.selectRowIndexes([outline.clickedRow], byExtendingSelection: false) }
            openSelected()
        }
    }
}

/// Teclado: Enter e ⌘↓ abrem a entidade selecionada (crit. 5); setas e type-select são nativos.
final class ExplorerOutlineView: NSOutlineView {
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isCommandDown = event.keyCode == 125 && event.modifierFlags.contains(.command)
        if isReturn || isCommandDown {
            onOpen?()
            return
        }
        super.keyDown(with: event)
    }
}

final class ExplorerCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("rk.explorer.cell")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        detail.textColor = .secondaryLabelColor
        detail.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(icon)
        addSubview(title)
        addSubview(detail)
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    func configure(symbol: String, title: String, detail: String?, identifier: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.title.stringValue = title
        self.detail.stringValue = detail ?? ""
        self.detail.isHidden = detail == nil
        setAccessibilityIdentifier(identifier)
        // VoiceOver: nome e tipo (crit. de NT-A11Y: lê a árvore com nível e tipo).
        setAccessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }
}
