import RSKeeperDesignSystem
import RSKeeperDomain
import RSKeeperFeatures
import RSKeeperSecurity
import SwiftUI

/// Janela Conexões (NST-03-01…05). Conectar abre a janela de workspace da conexão; esta janela sai
/// do primeiro plano e pode ser reaberta com ⌘⇧N (doc 10 §1).
struct ConnectionsWindowView: View {
    let services: AppServices
    @Environment(\.openWindow) private var openWindow
    @State private var model: ConnectionsModel?

    var body: some View {
        Group {
            switch services.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                RKEmptyState(String(localized: "Something went wrong"), message: message, systemImage: "exclamationmark.triangle")
            case .ready(let ready):
                if let model {
                    ConnectionScreen(model: model)
                } else {
                    Color.clear.onAppear {
                        model = ConnectionsModel(service: ready.connections) { profile, session, window in
                            openWindow(id: SceneID.workspace, value: WorkspaceWindowID(
                                raw: window.raw, sessionID: session.raw, profileID: profile.id.raw, title: profile.name))
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if services.environment.kind != .prod {
                RKBadge(services.environment.kind == .dev ? "DEV" : "TEST", tone: .info, outlined: true).padding(RKSpacing.s2)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Color.rk(.surfaceWindow))
        .task { await services.start() }
        #if RSK_DEV_BUILD || RSK_TEST_BUILD
        .onReceive(NotificationCenter.default.publisher(for: SampleDatabase.notification)) { _ in
            Task { if let url = try? await SampleDatabase.create() { await model?.useFile(url) } }
        }
        #endif
    }
}
