import Foundation

/// Identificadores de cena (docs/native/10).
enum SceneID {
    static let connections = "connections"
    static let workspace = "workspace"
    static let gallery = "component-gallery"
}

/// Identidade de uma janela de workspace (uma por conexão aberta, a partir da onda 1).
struct WorkspaceWindowID: Hashable, Codable, Sendable {
    let raw: UUID
    init(raw: UUID = UUID()) { self.raw = raw }
}

/// Identificadores de acessibilidade no padrão `rk.<feature>.<elemento>` (usados pelos XCUITests).
enum AccessibilityID {
    static let connectionsWindow = "rk.connections.window"
    static let connectionsEmptyState = "rk.connections.emptyState"
    static let workspaceWindow = "rk.workspace.window"
    static let settingsGeneral = "rk.settings.general"
}
