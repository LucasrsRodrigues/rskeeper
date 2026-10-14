import AppKit
import RSKeeperApplication
import RSKeeperDesignSystem
import SwiftUI

/// Aplicação SwiftUI (iniciada por `RSKeeperMain` depois da guarda de ambiente).
struct RSKeeperApp: App {
    private let environment = EnvironmentGuard.environment
    @State private var services = AppServices(environment: EnvironmentGuard.environment)

    init() {
        // Abas nativas de NSWindow desligadas: várias conexões abrem várias janelas (docs/native/10).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        Window("Connections", id: SceneID.connections) {
            ConnectionsWindowView(services: services)
        }
        .defaultSize(width: 760, height: 480)
        .commands {
            RegistryCommands()
            BaseCommands()
        }

        WindowGroup("Workspace", id: SceneID.workspace, for: WorkspaceWindowID.self) { $id in
            WorkspaceWindowView(id: id)
        }

        #if RSK_DEV_BUILD || RSK_TEST_BUILD
        Window("Component Gallery", id: SceneID.gallery) {
            ComponentGallery()
        }
        #endif

        Settings {
            SettingsView()
        }
    }
}
