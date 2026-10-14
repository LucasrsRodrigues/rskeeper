import Foundation

/// Identificadores de cena (docs/native/10).
enum SceneID {
    static let connections = "connections"
    static let workspace = "workspace"
    static let gallery = "component-gallery"
}

/// Rota de uma janela de workspace (uma por conexão aberta; doc 10 §1). Sem sessão = janela vazia
/// (comando de depuração) ou restaurada depois de reiniciar (a sessão não sobrevive ao processo).
struct WorkspaceWindowID: Hashable, Codable, Sendable {
    let raw: UUID
    var sessionID: UUID?
    var profileID: UUID?
    /// Título que identifica a conexão (NST-03-05, crit. 5).
    var title: String?
    init(raw: UUID = UUID(), sessionID: UUID? = nil, profileID: UUID? = nil, title: String? = nil) {
        self.raw = raw
        self.sessionID = sessionID
        self.profileID = profileID
        self.title = title
    }
}

/// Identificadores de acessibilidade no padrão `rk.<feature>.<elemento>` (usados pelos XCUITests).
enum AccessibilityID {
    static let connectionsWindow = "rk.connections.window"
    static let connectionsEmptyState = "rk.connections.emptyState"
    static let workspaceWindow = "rk.workspace.window"
    static let settingsGeneral = "rk.settings.general"
}
