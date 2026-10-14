import Foundation
import Testing
@testable import RSKeeperApplication
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperDriverSQLite
import RSKeeperPersistence
import RSKeeperSecurity

/// NST-03-03/04/05 — fachada da tela de conexões com SQLite real (W1-T12…T16).
@Suite("Serviço de conexões (W1-T12…T16)", .serialized)
struct ConnectionsServiceTests {
    private struct World {
        let base: URL
        let userFile: URL
        let service: ConnectionsService
        let sessions: SessionRegistry
        let repository: ProfileRepository
        let tracker: ScopedAccessTracker

        static func make() async throws -> World {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rsk-svc-\(UUID().uuidString)")
            let root = DataRoot(url: base.appendingPathComponent("root"))
            let database = try await MigrationRunner(root: root, appVersion: "0.0.1").open()
            let userFile = base.appendingPathComponent("usuario/vendas.db")
            try FileManager.default.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: userFile.path, contents: nil)
            let bookmarks = BookmarkStore(storage: DatabaseBookmarkStorage(database: database), appDataRoot: root)
            let tracker = ScopedAccessTracker()
            let secrets = SecretStore(service: SecretStore.service(bundleIDBase: "app.rskeeper.RSKeeper", environment: .test))
            let transient = TransientSecrets()
            let resolver = ProfileTargetResolver(bookmarks: bookmarks, tracker: tracker, secrets: secrets, transient: transient)
            let drivers = DriverRegistry([SQLiteDriver()])
            let sessions = SessionRegistry()
            let repository = ProfileRepository(database: database)
            let service = ConnectionsService(profiles: repository, drivers: drivers, fileGrants: FileGrantService(store: bookmarks),
                                             secrets: secrets, transient: transient,
                                             connectUseCase: ConnectUseCase(drivers: drivers, sessions: sessions, resolver: resolver),
                                             resolver: resolver)
            return World(base: base, userFile: userFile, service: service, sessions: sessions, repository: repository, tracker: tracker)
        }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    @Test("Arquivo escolhido → bookmark persistente → testar → conectar → recentes (F-CONN-02/07)")
    func sqliteFlow() async throws {
        let world = try await World.make()
        defer { world.cleanup() }
        #expect(world.service.driverChoices.map(\.id) == [.sqlite])
        let grant = try await world.service.grantFile(world.userFile)
        let profile = try await world.service.save(
            ConnectionProfile(name: "Vendas", driverID: .sqlite, target: .file(grant, openMode: .readWrite)), password: nil, isNew: true)
        let version = try await world.service.test(profile, password: nil)
        #expect(version.hasPrefix("SQLite "))
        let window = WindowID.generate()
        let sessionID = try await world.service.connector.connect(profile, window: window)
        await world.service.recordUse(profile.id)
        #expect(try await world.repository.sidebar().recent.map(\.name) == ["Vendas"])
        #expect(await world.tracker.openCount == 1, "escopo de acesso aberto enquanto a sessão usa o arquivo")
        _ = sessionID
        await world.sessions.closeWindow(window)
    }

    @Test("Arquivo dentro da raiz de dados do app é recusado (NT-SEC-07)")
    func appDataRootRefused() async throws {
        let world = try await World.make()
        defer { world.cleanup() }
        let inside = world.base.appendingPathComponent("root/data/app.db")
        await #expect(throws: RSKeeperError.self) { _ = try await world.service.grantFile(inside) }
    }

    @Test("URL colada preenche os campos; a senha não volta como texto e vai para o depósito de uso único")
    func urlImport() async throws {
        let world = try await World.make()
        defer { world.cleanup() }
        let draftID = ProfileID.generate()
        let fields = try await world.service.importURL("sqlite:///tmp/x.db", depositPasswordFor: draftID)
        #expect(fields.driverID == .sqlite && fields.filePath == "/tmp/x.db" && !fields.hasPassword)
        // PostgreSQL não registrado neste mundo: a UI recebe "indisponível", não um formulário quebrado.
        await #expect(throws: RSKeeperError.self) { _ = try await world.service.importURL("postgres://u:p@h/db", depositPasswordFor: draftID) }
        await #expect(throws: RSKeeperError.self) { _ = try await world.service.importURL("ftp://x", depositPasswordFor: draftID) }
        #expect(!"\(fields)".contains("p@h"))
    }

    @Test("Senha: com 'salvar senhas' vai ao Keychain (serviço .test); sem, só ao depósito de uso único")
    func passwordStorage() async throws {
        let world = try await World.make()
        defer { world.cleanup() }
        let saved = try await world.service.save(
            ConnectionProfile(name: "PG", driverID: .postgresql, target: .server(host: "db.invalid", port: 5432, user: "app", password: nil),
                              savePasswords: true), password: "s3cr3t", isNew: true)
        guard case .server(_, _, _, let reference?) = saved.target, case .stored = reference else { Issue.record("sem referência salva"); return }
        let secrets = SecretStore(service: SecretStore.service(bundleIDBase: "app.rskeeper.RSKeeper", environment: .test))
        #expect(try await secrets.value(for: reference, currentFingerprint: TargetFingerprinter.fingerprint(of: saved)) == "s3cr3t")
        try await world.service.delete(saved)
        #expect(await !secrets.hasSecret(for: SecretKey(profileID: saved.id, purpose: .password)), "excluir o perfil apaga o segredo")

        let prompt = try await world.service.save(
            ConnectionProfile(name: "PG2", driverID: .postgresql, target: .server(host: "db.invalid", port: 5432, user: "app", password: nil),
                              savePasswords: false), password: "uma-vez", isNew: true)
        guard case .server(_, _, _, let promptRef) = prompt.target else { return }
        #expect(promptRef == .prompt)
        #expect(await !secrets.hasSecret(for: SecretKey(profileID: prompt.id, purpose: .password)))
    }
}
