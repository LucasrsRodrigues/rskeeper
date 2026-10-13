import RSKeeperDesignSystem
import RSKeeperSecurity
import SwiftUI

/// Janela Conexões (W0-T29). Na onda 0 mostra só o estado vazio próprio; o gerenciamento de
/// conexões chega na onda 1 (NST-03-*), sem antecipação aqui.
struct ConnectionsWindowView: View {
    let environment: AppEnvironmentKind

    var body: some View {
        VStack(spacing: 0) {
            RKEmptyState(String(localized: "Welcome to RSKeeper"),
                         message: String(localized: "Connections will appear here."),
                         systemImage: "cylinder.split.1x2")
                .accessibilityIdentifier(AccessibilityID.connectionsEmptyState)
            if environment != .prod {
                HStack {
                    Spacer()
                    RKBadge(environment == .dev ? "DEV" : "TEST", tone: .info, outlined: true)
                        .padding(RKSpacing.s2)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Color.rk(.surfaceWindow))
        .accessibilityIdentifier(AccessibilityID.connectionsWindow)
    }
}
