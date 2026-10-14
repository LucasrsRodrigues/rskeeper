import Foundation
import Observation
import RSKeeperApplication
import RSKeeperDomain

/// Estado de uma janela de workspace (NST-05-01): uma conexão aberta por janela (doc 10 §1).
@MainActor
@Observable
public final class WorkspaceModel {
    public enum RailDestination: String, CaseIterable, Sendable { case explorer, savedQueries, history }

    public let windowID: WindowID
    public let title: String
    public private(set) var session: DatabaseSession?
    public var railDestination: RailDestination = .explorer
    public private(set) var sidebarVisible = true
    public private(set) var inspectorVisible = false
    /// Aviso transitório na barra de status (ex.: "Inspetor fechado: pouco espaço").
    public private(set) var notice: String?

    @ObservationIgnored weak var split: WorkspaceSplitController?
    @ObservationIgnored private let sessions: SessionRegistry?

    public init(windowID: WindowID, title: String, sessionID: SessionID?, sessions: SessionRegistry?) {
        self.windowID = windowID
        self.title = title
        self.sessions = sessions
        if let sessionID, let sessions {
            Task { [weak self] in self?.session = try? await sessions.session(sessionID, for: windowID) }
        }
    }

    var autosaveName: String { WorkspaceLayout.autosaveName(window: windowID.raw) }

    func attach(_ controller: WorkspaceSplitController) {
        split = controller
        sidebarVisible = controller.isSidebarVisible
        inspectorVisible = controller.isInspectorVisible
        controller.onVisibilityChange = { [weak self] sidebar, inspector in
            self?.sidebarVisible = sidebar
            self?.inspectorVisible = inspector
        }
        controller.onLayoutDecision = { [weak self] decision in
            if decision.inspectorAutoClosed { self?.notice = String(localized: "Inspector closed: not enough space") }
        }
    }

    public func toggleSidebar() { split?.setSidebar(visible: !(split?.isSidebarVisible ?? true)) }
    public func toggleInspector() {
        notice = nil
        split?.setInspector(visible: !(split?.isInspectorVisible ?? false))
    }

    /// Fecha as sessões desta janela (cancelar → rollback → desconectar).
    public func disconnect() async {
        await sessions?.closeWindow(windowID)
        session = nil
    }
}

extension WorkspaceModel: CommandPerforming {
    public var commandContext: CommandContext {
        CommandContext(isConnected: session != nil, isWorkspace: true)
    }

    public func perform(_ command: CommandID) {
        switch command {
        case CommandRegistry.toggleSidebar: toggleSidebar()
        case CommandRegistry.toggleInspector: toggleInspector()
        case CommandRegistry.nextRegion: split?.focusRegion(forward: true)
        case CommandRegistry.previousRegion: split?.focusRegion(forward: false)
        case CommandRegistry.disconnect: Task { await disconnect() }
        default: break
        }
    }
}
