import SwiftUI

/// Ponto de entrada do RSKeeper (W0-T08: janela vazia mínima).
@main
struct RSKeeperApp: App {
    var body: some Scene {
        WindowGroup {
            Text("RSKeeper")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
