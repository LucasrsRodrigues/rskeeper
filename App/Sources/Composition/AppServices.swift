import Foundation
import Observation
import RSKeeperApplication
import RSKeeperDomain
import RSKeeperDriverPostgreSQL
import RSKeeperDriverSQLite
import RSKeeperPersistence
import RSKeeperSecurity

/// Raiz de composição (doc 02 §7): o **único** lugar que conhece drivers concretos, banco local,
/// Keychain e bookmarks. As telas recebem só fachadas da camada de aplicação.
@MainActor
@Observable
final class AppServices {
    struct Ready {
        let connections: ConnectionsService
        let sessions: SessionRegistry
        let drafts: DraftAutosaver
    }

    enum State {
        case loading
        case ready(Ready)
        /// Banco local ilegível ou em modo de recuperação: a UI explica e não perde dados.
        case failed(String)
    }

    private(set) var state: State = .loading
    let environment: AppEnvironment

    init(environment: AppEnvironment) { self.environment = environment }

    func start() async {
        guard case .loading = state else { return }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let database = try await MigrationRunner(root: environment.dataRoot, appVersion: version).open()
            let bookmarks = BookmarkStore(storage: DatabaseBookmarkStorage(database: database), appDataRoot: environment.dataRoot)
            let secrets = SecretStore(service: SecretStore.service(bundleIDBase: Self.baseBundleIdentifier, environment: environment.kind))
            let transient = TransientSecrets()
            let resolver = ProfileTargetResolver(bookmarks: bookmarks, tracker: ScopedAccessTracker(), secrets: secrets, transient: transient)
            // Drivers registrados só aqui (NST-04-01, crit. 1).
            let drivers = DriverRegistry([SQLiteDriver(), PostgresDriver()])
            let sessions = SessionRegistry()
            let connections = ConnectionsService(
                profiles: ProfileRepository(database: database), drivers: drivers, fileGrants: FileGrantService(store: bookmarks),
                secrets: secrets, transient: transient,
                connectUseCase: ConnectUseCase(drivers: drivers, sessions: sessions, resolver: resolver), resolver: resolver)
            state = .ready(Ready(connections: connections, sessions: sessions,
                                 drafts: DraftAutosaver(repository: DraftRepository(database: database))))
        } catch {
            state = .failed(String(localized: "The local database could not be opened. Your data was not changed."))
        }
    }

    static var baseBundleIdentifier: String {
        let id = Bundle.main.bundleIdentifier ?? "app.rskeeper.RSKeeper"
        for suffix in [".dev", ".test"] where id.hasSuffix(suffix) { return String(id.dropLast(suffix.count)) }
        return id
    }
}
