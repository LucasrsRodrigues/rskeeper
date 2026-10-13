import RSKeeperDesignSystem
import SwiftUI

/// Ajustes (W0-T29): cena `Settings` com a aba "Geral" vazia. Conteúdo real na NST-13-03.
struct SettingsView: View {
    var body: some View {
        TabView {
            Form {
                Text("General settings will appear here.")
                    .foregroundStyle(.rk(.textSecondary))
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            .accessibilityIdentifier(AccessibilityID.settingsGeneral)
        }
        .frame(width: 480, height: 280)
    }
}
