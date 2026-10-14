import Foundation

/// Regras de tamanho do workspace (doc 10 §3.2 [META]; calibradas no SPK-N08). Puras e testáveis.
public enum WorkspaceLayout {
    public static let railWidth: CGFloat = 40
    public static let sidebar = (min: CGFloat(180), ideal: CGFloat(260), max: CGFloat(420))
    public static let inspector = (min: CGFloat(240), ideal: CGFloat(300), max: CGFloat(520))
    public static let contentMin: CGFloat = 400
    public static let minimumWindow = CGSize(width: 900, height: 560)
    /// Abaixo disto a sidebar recolhe para o trilho.
    public static let narrowWindowWidth: CGFloat = 1_024
    /// Abaixo disto (largura da aba) o inspetor fecha sozinho e a barra de status avisa.
    public static let inspectorAutoCloseContentWidth: CGFloat = 640

    public struct Decision: Equatable, Sendable {
        public var collapseSidebar = false
        public var collapseInspector = false
        /// O inspetor fechou sozinho: a barra de status avisa.
        public var inspectorAutoClosed = false
    }

    /// O que recolher para uma largura de janela e de conteúdo. Nunca expande sozinho (respeita o usuário).
    public static func decide(windowWidth: CGFloat, contentWidth: CGFloat, sidebarVisible: Bool, inspectorVisible: Bool) -> Decision {
        var decision = Decision()
        if sidebarVisible, windowWidth < narrowWindowWidth { decision.collapseSidebar = true }
        if inspectorVisible, contentWidth < inspectorAutoCloseContentWidth {
            decision.collapseInspector = true
            decision.inspectorAutoClosed = true
        }
        return decision
    }

    /// Chave de persistência por janela (SPK-N08: o `autosaveName` é por nome, não por janela).
    public static func autosaveName(window: UUID) -> String { "rskeeper.workspace.\(window.uuidString)" }
}
