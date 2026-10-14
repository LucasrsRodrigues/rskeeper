import Foundation
import Testing
@testable import RSKeeperApplication
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperPersistence
import RSKeeperSecurity
import RSKeeperTesting

/// NST-01-05 — rascunhos, recuperação e perda de conexão (W1-T10).
@Suite("Recuperação de falhas (W1-T10, NST-01-05)", .serialized)
struct RecoveryTests {
    private struct Root {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rsk-rec-\(UUID().uuidString)")
        var root: DataRoot { DataRoot(url: base.appendingPathComponent("root")) }
        func open() async throws -> AppDatabase { try await MigrationRunner(root: root, appVersion: "0.0.1").open() }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    private func profile(_ database: AppDatabase) async throws -> ProfileID {
        let profile = ConnectionProfile(name: "p", driverID: .sqlite, target: .file(FileGrant(id: UUID(), displayPath: "/tmp/x.db"), openMode: .readWrite))
        try await ProfileRepository(database: database).insert(profile)
        return profile.id
    }

    @Test("Debounce: várias edições → uma gravação depois do prazo; flush grava na hora; aba fechada some")
    func debounceAndFlush() async throws {
        let root = Root()
        defer { root.cleanup() }
        let database = try await root.open()
        let repository = DraftRepository(database: database)
        let saver = DraftAutosaver(repository: repository, delay: .milliseconds(150))
        let tab = TabRecord(id: .generate(), profileID: try await profile(database), window: .generate(), kind: .query, title: "Consulta #1", position: 0)
        await saver.textChanged(tab, text: "SELECT 1", savedTextHash: nil)
        await saver.textChanged(tab, text: "SELECT 12", savedTextHash: nil)
        #expect(try await repository.recoverable().isEmpty, "nada gravado antes do prazo")
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await repository.recoverable().map(\.text) == ["SELECT 12"])
        await saver.textChanged(tab, text: "SELECT 123", savedTextHash: nil)
        await saver.flush()
        #expect(try await repository.recoverable().map(\.text) == ["SELECT 123"])
        #expect(await !saver.hasPending)
        await saver.tabClosed(tab.id)
        #expect(try await repository.recoverable().isEmpty)
    }

    @Test("Critério 2: depois de um encerramento forçado, o próximo boot restaura abas e texto não salvo")
    func restoreAfterForcedExit() async throws {
        let root = Root()
        defer { root.cleanup() }
        let first = try await root.open()
        let profileID = try await profile(first)
        let window = WindowID.generate()
        let saved = TabRecord(id: .generate(), profileID: profileID, window: window, kind: .query, title: "Salva", position: 0)
        let edited = TabRecord(id: .generate(), profileID: profileID, window: window, kind: .table(database: nil, schema: "main", name: "pedidos"), title: "pedidos", position: 1)
        let repository = DraftRepository(database: first)
        try await repository.save(saved, text: "SELECT 1", savedTextHash: DraftRepository.hash("SELECT 1"))
        try await repository.save(edited, text: "SELECT * FROM pedidos -- editado", savedTextHash: DraftRepository.hash("SELECT * FROM pedidos"))
        // "kill -9": nada é fechado; outro processo abre o mesmo banco.
        let second = try await root.open()
        let recovered = try await DraftRepository(database: second).recoverable()
        #expect(recovered.map(\.tab.title) == ["Salva", "pedidos"])
        #expect(recovered.map(\.isUnsaved) == [false, true])
        #expect(recovered[1].tab.kind == .table(database: nil, schema: "main", name: "pedidos"))
        #expect(recovered[1].text == "SELECT * FROM pedidos -- editado")
    }

    // MARK: Perda de conexão

    private static let lostSQL = "SELECT pg_terminate_backend(pg_backend_pid())"

    private func session(_ log: InMemoryDriverLog) async throws -> DatabaseSession {
        let driver = InMemoryDriver(script: .init(failures: [Self.lostSQL: .connection(RedactedMessage(alreadyRedacted: "socket fechado"))]), log: log)
        let registry = SessionRegistry()
        let window = WindowID.generate()
        let id = try await registry.open(window: window, profileID: .generate(), factory: driver,
                                         target: .server(host: "m", port: 1, user: nil, password: nil, database: nil),
                                         policy: .init(environment: .local, readOnly: false, targetName: "t"))
        return try await registry.session(id, for: window)
    }

    private func planned(_ sql: String, _ risk: StatementRisk) -> [PlannedStatement] {
        [PlannedStatement(statement: BoundStatement(sql: sql), risk: risk, sourceRange: 0..<sql.utf16.count)]
    }

    @Test("Conexão perdida → evento, execuções recusadas até reconectar; reconectar não repete a escrita")
    func lostConnectionAndReconnect() async throws {
        let log = InMemoryDriverLog()
        let session = try await session(log)
        var events = session.events.makeAsyncIterator()
        let tab = TabID.generate()
        _ = try await session.executeScript(planned("INSERT 1", .write), tab: tab, executionID: .generate())
        let lost = try await session.executeScript(planned(Self.lostSQL, .read), tab: tab, executionID: .generate())
        #expect(lost.reports[0].status != .ok)
        #expect(await events.next() == .lost(RedactedMessage(alreadyRedacted: "A conexão com o banco foi perdida.")))
        #expect(await session.isLost)
        await #expect(throws: RSKeeperError.self) { _ = try await session.executeScript(planned("SELECT 1", .read), tab: tab, executionID: .generate()) }
        try await session.reconnect()
        #expect(await events.next() == .reconnected)
        _ = try await session.executeScript(planned("SELECT 1", .read), tab: tab, executionID: .generate())
        let inserts = await log.events.filter { $0 == .executed("INSERT 1") }.count
        #expect(inserts == 1, "a escrita anterior à queda não foi repetida")
        await session.close()
    }

    @Test("Critério 3: transação manual interrompida pela queda aparece como desfeita, nunca como ativa")
    func manualTransactionLost() async throws {
        let session = try await session(InMemoryDriverLog())
        var events = session.events.makeAsyncIterator()
        let tab = TabID.generate()
        try await session.beginTransaction(tab: tab)
        #expect(await session.hasTransaction(tab: tab))
        _ = try await session.executeScript(planned(Self.lostSQL, .read), tab: tab, executionID: .generate())
        #expect(await !session.hasTransaction(tab: tab))
        #expect(await events.next() == .transactionEnded(tab: tab, outcome: .presumedRolledBackByServer))
        await session.close()
    }
}
