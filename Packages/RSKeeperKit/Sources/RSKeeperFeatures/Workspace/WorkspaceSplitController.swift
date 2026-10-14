import AppKit
import SwiftUI

/// Regiões do workspace na ordem do ciclo de foco (doc 10 §6.1; o trilho e a barra de status são SwiftUI).
public enum WorkspaceRegion: Int, CaseIterable, Sendable { case sidebar, content, inspector }

/// Colunas do workspace em `NSSplitViewController` com painéis SwiftUI (ADR-N11 após o SPK-N08).
///
/// - Sidebar e inspetor como itens nativos: mínimos/máximos, recolher por comando e por arrasto, sem
///   avisos de constraint; o inspetor empurra o conteúdo.
/// - `sizingOptions = []` nos `NSHostingController`: o SwiftUI não impõe mínimos que briguem com o split.
/// - Regras de janela estreita aplicadas **um ciclo depois** do layout (mudar `isCollapsed` dentro do
///   layout causa recursão; medido no SPK-N08).
@MainActor
public final class WorkspaceSplitController: NSSplitViewController {
    private let sidebarHost: NSHostingController<AnyView>
    private let contentHost: NSHostingController<AnyView>
    private let inspectorHost: NSHostingController<AnyView>
    private let sidebarItem: NSSplitViewItem
    private let contentItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem
    private var pendingRules = false
    var onLayoutDecision: ((WorkspaceLayout.Decision) -> Void)?
    var onVisibilityChange: ((Bool, Bool) -> Void)?

    public init(sidebar: some View, content: some View, inspector: some View, autosaveName: String) {
        func host(_ view: some View) -> NSHostingController<AnyView> {
            let controller = NSHostingController(rootView: AnyView(view))
            controller.sizingOptions = []
            return controller
        }
        sidebarHost = host(sidebar)
        contentHost = host(content)
        inspectorHost = host(inspector)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = WorkspaceLayout.sidebar.min
        sidebarItem.maximumThickness = WorkspaceLayout.sidebar.max
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        contentItem = NSSplitViewItem(viewController: contentHost)
        contentItem.minimumThickness = WorkspaceLayout.contentMin
        contentItem.holdingPriority = NSLayoutConstraint.Priority(250)

        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspectorItem.minimumThickness = WorkspaceLayout.inspector.min
        inspectorItem.maximumThickness = WorkspaceLayout.inspector.max
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(255)
        inspectorItem.isCollapsed = true                                  // abre quando há o que inspecionar

        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
        splitView.autosaveName = autosaveName
        splitView.setAccessibilityIdentifier("rk.workspace.split")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    /// O SwiftUI recria as views dos painéis a cada atualização; os hosts precisam receber as novas
    /// (senão a sidebar ficaria presa ao conteúdo de quando a janela abriu).
    func update(sidebar: some View, content: some View, inspector: some View) {
        sidebarHost.rootView = AnyView(sidebar)
        contentHost.rootView = AnyView(content)
        inspectorHost.rootView = AnyView(inspector)
    }

    public var isSidebarVisible: Bool { !sidebarItem.isCollapsed }
    public var isInspectorVisible: Bool { !inspectorItem.isCollapsed }

    public func setSidebar(visible: Bool, animated: Bool = true) {
        guard sidebarItem.isCollapsed == visible else { return }
        (animated ? sidebarItem.animator() : sidebarItem).isCollapsed = !visible
    }

    public func setInspector(visible: Bool, animated: Bool = true) {
        guard inspectorItem.isCollapsed == visible else { return }
        (animated ? inspectorItem.animator() : inspectorItem).isCollapsed = !visible
    }

    // MARK: Foco entre regiões (F6 / ⇧F6)

    /// Leva o foco à próxima região visível (ou à anterior), pelo primeiro campo focável dela.
    public func focusRegion(forward: Bool) {
        guard let window = view.window else { return }
        let visible: [WorkspaceRegion] = WorkspaceRegion.allCases.filter {
            switch $0 {
            case .sidebar: isSidebarVisible
            case .content: true
            case .inspector: isInspectorVisible
            }
        }
        let current = visible.firstIndex { region($0).map { Self.contains(window.firstResponder, in: $0) } ?? false }
        let next = current.map { (($0 + (forward ? 1 : -1)) % visible.count + visible.count) % visible.count } ?? 0
        guard let target = region(visible[next]) else { return }
        window.makeFirstResponder(target.nextValidKeyView ?? target)
    }

    private static func contains(_ responder: NSResponder?, in view: NSView) -> Bool {
        (responder as? NSView)?.isDescendant(of: view) ?? false
    }

    private func region(_ region: WorkspaceRegion) -> NSView? {
        switch region {
        case .sidebar: sidebarItem.viewController.view
        case .content: contentItem.viewController.view
        case .inspector: inspectorItem.viewController.view
        }
    }

    // MARK: Regras de largura (doc 10 §3.2)

    public override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onVisibilityChange?(isSidebarVisible, isInspectorVisible)
        guard !pendingRules else { return }
        pendingRules = true
        DispatchQueue.main.async { [weak self] in                         // adiado: nunca durante o layout
            guard let self else { return }
            self.pendingRules = false
            self.applyWidthRules()
        }
    }

    /// Só quando o **usuário** estreita a janela (redimensionamento ao vivo). Na montagem da janela os
    /// primeiros layouts têm largura provisória e recolheriam a sidebar por engano.
    private func applyWidthRules() {
        guard let window = view.window, window.inLiveResize else { return }
        let decision = WorkspaceLayout.decide(windowWidth: window.frame.width,
                                              contentWidth: contentItem.viewController.view.frame.width,
                                              sidebarVisible: isSidebarVisible, inspectorVisible: isInspectorVisible)
        if decision.collapseSidebar { setSidebar(visible: false, animated: false) }
        if decision.collapseInspector { setInspector(visible: false, animated: false) }
        if decision.collapseSidebar || decision.collapseInspector { onLayoutDecision?(decision) }
    }
}
