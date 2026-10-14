import RSKeeperDesignSystem
import SwiftUI

/// Janela de workspace (W0-T29): **conteúdo vazio**. O layout de quatro regiões é a NST-05-01
/// (onda 1), condicionado ao SPK-N08.
struct WorkspaceWindowView: View {
    let id: WorkspaceWindowID?

    var body: some View {
        RKEmptyState(id?.title ?? String(localized: "Empty workspace"), systemImage: "rectangle.split.3x1")
            .frame(minWidth: 800, minHeight: 500)
            .background(Color.rk(.surfaceWindow))
            .accessibilityIdentifier(AccessibilityID.workspaceWindow)
            .navigationTitle(id?.title ?? String(localized: "Workspace"))
    }
}
