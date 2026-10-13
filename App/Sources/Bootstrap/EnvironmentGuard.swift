import Foundation
import RSKeeperApplication
import RSKeeperSecurity

/// Guarda de ambiente (W0-T12): resolve o ambiente e a raiz de dados **antes** de qualquer
/// cena, acesso a dados ou log. No build Test, falha fechada (NT-SEC-14); em Dev/Release,
/// o argumento `-RSKeeperDataRoot` é ignorado (NT-SEC-22).
enum EnvironmentGuard {
    /// Código de saída quando a guarda recusa iniciar (EX_CONFIG).
    static let refusalExitCode: Int32 = 78

    /// Ambiente resolvido uma única vez (inicialização preguiçosa e thread-safe de `static let`).
    static let environment: AppEnvironment = resolveOrExit()

    private static func resolveOrExit() -> AppEnvironment {
        let name = Bundle.main.object(forInfoDictionaryKey: "RSKEnvironment") as? String ?? "<ausente>"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let baseID = baseBundleIdentifier()
        do {
            let environment = try AppEnvironment.resolve(
                environmentName: name,
                arguments: ProcessInfo.processInfo.arguments,
                temporaryDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                applicationSupport: DataRoot.currentApplicationSupport(),
                protectedRoots: AppEnvironment.defaultProtectedRoots(home: home, bundleIDBase: baseID))
            try environment.dataRoot.prepare()
            let swept = try environment.dataRoot.sweepTemporaryFiles()
            logStart(environment, baseID: baseID, swept: swept)
            return environment
        } catch {
            refuse("\(error)")
        }
    }

    /// Primeiro evento de log, já com a raiz resolvida. A raiz é campo **privado** (NT-SEC-20:
    /// aparece como `<private>` no `log show` sem perfil de depuração).
    private static func logStart(_ environment: AppEnvironment, baseID: String, swept: Int) {
        let logger = RKLogger(subsystem: RKLogger.subsystem(bundleIDBase: baseID, environment: environment.kind),
                              category: "lifecycle")
        logger.notice("app.started", [
            "environment": .public(environment.kind.rawValue),
            "sweptTemporaryFiles": .public(String(swept)),
            "dataRoot": .private(environment.dataRoot.url.path),
        ])
    }

    /// Bundle ID sem o sufixo do ambiente (`.dev`, `.test`).
    private static func baseBundleIdentifier() -> String {
        let id = Bundle.main.bundleIdentifier ?? "app.rskeeper.RSKeeper"
        for suffix in [".dev", ".test"] where id.hasSuffix(suffix) {
            return String(id.dropLast(suffix.count))
        }
        return id
    }

    private static func refuse(_ message: String) -> Never {
        FileHandle.standardError.write(Data("RSKeeper: recusado iniciar — \(message)\n".utf8))
        exit(refusalExitCode)
    }
}
