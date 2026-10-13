import SwiftUI

/// Aplicação SwiftUI (iniciada por `RSKeeperMain` depois da guarda de ambiente).
struct RSKeeperApp: App {
    var body: some Scene {
        WindowGroup {
            Text("RSKeeper")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}
