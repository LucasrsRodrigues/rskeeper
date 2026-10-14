import SwiftUI

/// Comandos base (W0-T29). Os comandos de depuração só existem nos builds Dev e Test.
struct BaseCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        #if RSK_DEV_BUILD || RSK_TEST_BUILD
        CommandMenu("Debug") {
            Button("Open Empty Workspace Window") {
                openWindow(id: SceneID.workspace, value: WorkspaceWindowID())
            }
            .keyboardShortcut("w", modifiers: [.command, .option, .control])
            Button("Component Gallery") {
                openWindow(id: SceneID.gallery)
            }
            Button("Use Sample Database File") {
                NotificationCenter.default.post(name: SampleDatabase.notification, object: nil)
            }
        }
        #endif
    }
}
