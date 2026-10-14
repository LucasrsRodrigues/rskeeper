import Foundation
import Testing
import RSKeeperApplication
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperDriverSQLite

/// NST-05-02 — metadados do explorador com SQLite real (W1-T18).
@Suite("Explorador — metadados (W1-T18)", .serialized)
struct ExplorerServiceTests {
    private func open(tables: Int = 0) async throws -> (DatabaseSession, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rsk-explorer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("t.db").path
        FileManager.default.createFile(atPath: path, contents: nil)
        let setup = try await SQLiteDriver().open(.file(path: path, readOnly: false), options: OpenOptions())
        _ = try await setup.execute(BoundStatement(sql: "CREATE TABLE pedidos (id INTEGER PRIMARY KEY, cliente TEXT NOT NULL)"), limits: .default)
        _ = try await setup.execute(BoundStatement(sql: "CREATE VIEW v_pedidos AS SELECT * FROM pedidos"), limits: .default)
        if tables > 0 {
            _ = try await setup.execute(BoundStatement(sql: "BEGIN"), limits: .default)
            for i in 0..<tables { _ = try await setup.execute(BoundStatement(sql: "CREATE TABLE t\(i) (a INTEGER)"), limits: .default) }
            _ = try await setup.execute(BoundStatement(sql: "COMMIT"), limits: .default)
        }
        await setup.close()
        let registry = SessionRegistry()
        let window = WindowID.generate()
        let id = try await registry.open(window: window, profileID: .generate(), factory: SQLiteDriver(),
                                         target: .file(path: path, readOnly: false), policy: .init(environment: .local, readOnly: false, targetName: "t"))
        return (try await registry.session(id, for: window), directory)
    }

    @Test("Database atual, schemas, entidades por tipo e colunas com PK; cache e atualizar")
    func metadata() async throws {
        let (session, directory) = try await open()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ExplorerService(session: session)
        let database = try await service.currentDatabase()
        #expect(database == "main")
        #expect(try await service.schemas(in: database).contains("main"))
        let entities = try await service.entities(database: nil, schema: "main")
        #expect(entities.map(\.name) == ["pedidos", "v_pedidos"])
        #expect(entities.map(\.kind) == [.table, .view])
        let columns = try await service.columns(of: entities[0])
        #expect(columns.map(\.name) == ["id", "cliente"])
        #expect(columns[0].isPrimaryKey && !columns[1].nullable)
        #expect(entities[0].tabKind == .table(database: nil, schema: "main", name: "pedidos"))
        await service.refresh()
        #expect(try await service.entities(database: nil, schema: "main").count == 2)
        await session.close()
    }

    @Test("NT-PERF: 10.000 tabelas listadas e filtradas sem travar")
    func tenThousandTables() async throws {
        let (session, directory) = try await open(tables: 10_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ExplorerService(session: session)
        let clock = ContinuousClock()
        var entities: [ExplorerEntity] = []
        let listing = try await clock.measure { entities = try await service.entities(database: nil, schema: "main") }
        #expect(entities.count == 10_002)
        let filtering = clock.measure {
            _ = entities.filter { $0.name.range(of: "t99", options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        #expect(listing < .seconds(2), "listar levou \(listing)")
        #expect(filtering < .milliseconds(100), "filtrar levou \(filtering)")
        await session.close()
    }
}
