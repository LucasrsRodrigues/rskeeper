import RSKeeperApplication
import RSKeeperDesignSystem
import RSKeeperDomain
import RSKeeperFeatures
import SwiftUI

/// Janela de workspace (NST-05-01): shell de quatro regiões da conexão aberta. Sem sessão (janela vazia
/// de depuração ou restaurada após reiniciar), mostra o shell desconectado.
struct WorkspaceWindowView: View {
    let route: WorkspaceWindowID?
    let services: AppServices
    @State private var model: WorkspaceModel?

    var body: some View {
        Group {
            if let model {
                WorkspaceShell(model: model) {
                    if let explorer = model.explorer {
                        ExplorerView(model: explorer)
                    } else {
                        RKEmptyState(String(localized: "Explorer"), systemImage: "cylinder.split.1x2")
                            .accessibilityIdentifier("rk.workspace.sidebar")
                    }
                } content: {
                    RKEmptyState(model.title, message: model.session == nil ? String(localized: "Not connected") : nil,
                                 systemImage: "rectangle.split.3x1")
                        .accessibilityIdentifier("rk.workspace.content")
                } inspector: {
                    RKEmptyState(String(localized: "Inspector"), systemImage: "sidebar.right")
                        .accessibilityIdentifier("rk.workspace.inspector")
                } status: {
                    HStack {
                        Text(model.notice ?? model.title).rkTypography(.caption).foregroundStyle(.rk(.textSecondary))
                        Spacer()
                    }
                    .padding(.horizontal, RKSpacing.s2)
                    .frame(height: 24)
                    .background(Color.rk(.surfaceWindow))
                    .accessibilityIdentifier("rk.workspace.status")
                }
                .focusedSceneValue(\.commandTarget, CommandTarget(performer: model))
            } else {
                Color.clear.onAppear {
                    var sessions: SessionRegistry?
                    if case .ready(let ready) = services.state { sessions = ready.sessions }
                    model = WorkspaceModel(windowID: WindowID(raw: route?.raw ?? UUID()),
                                           title: route?.title ?? String(localized: "Empty workspace"),
                                           sessionID: route?.sessionID.map(SessionID.init(raw:)), sessions: sessions)
                }
            }
        }
        .navigationTitle(route?.title ?? String(localized: "Workspace"))
        .background(Color.rk(.surfaceWindow))
    }
}
