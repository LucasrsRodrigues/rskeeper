import Foundation
import Testing
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperDriverSQLite
import RSKeeperTesting

/// Arquivo SQLite descartável num diretório temporário próprio do teste (dados sintéticos).
struct ScratchDatabase {
    let directory: URL
    let path: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rsk-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("teste.db").path
        // Arquivo vazio é um banco SQLite válido; o driver nunca cria arquivos.
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    var sidecars: [String] {
        ["-wal", "-shm", "-journal"].filter { FileManager.default.fileExists(atPath: path + $0) }
    }

    /// Bytes 18–19 do cabeçalho: 1 = rollback journal (DELETE…), 2 = WAL.
    var headerJournalVersion: (UInt8, UInt8) {
        let data = FileManager.default.contents(atPath: path) ?? Data()
        return data.count >= 20 ? (data[18], data[19]) : (0, 0)
    }
}

private func open(_ db: ScratchDatabase, readOnly: Bool = false) async throws -> any PhysicalConnection {
    try await SQLiteDriver().open(.file(path: db.path, readOnly: readOnly), options: OpenOptions())
}

@discardableResult
private func run(_ connection: any PhysicalConnection, _ sql: String, _ bindings: [BindValue] = []) async throws -> StatementOutcome {
    try await connection.execute(BoundStatement(sql: sql, bindings: bindings), limits: .default)
}

@Suite("Driver SQLite — conformidade (W1-T03, NST-04-02)", .serialized)
struct SQLiteConformanceTests {
    static func fixture(_ db: ScratchDatabase) -> ConformanceFixture {
        let directory = db.directory.path
        return ConformanceFixture(
            factory: SQLiteDriver(),
            target: .file(path: db.path, readOnly: false),
            longRunning: "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c",
            generateRows: { n in
                "WITH RECURSIVE g(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM g WHERE x < \(n)) SELECT x AS id, 'linha ' || x AS nome, x * 1.5 AS valor FROM g"
            },
            invalidSQL: "SELEC 'segredo-xyz' FROM nada",
            secretMarker: "segredo-xyz",
            expectedTable: (EntityRef(schema: SchemaRef(database: nil, name: "main"), name: "pedidos"), ["id", "nome", "criado_em"]),
            echoParameter: "SELECT ?",
            createTableWithColumn: { table, column in "CREATE TABLE \(table) (\(column) TEXT)" },
            scratchSchema: SchemaRef(database: nil, name: "main"),
            readOnlyBypassCorpus: [
                "INSERT INTO pedidos (nome) VALUES ('x')",
                "CREATE TABLE z (a)",
                "PRAGMA query_only = 0",
                "PRAGMA journal_mode = WAL",
                "VACUUM INTO '\(directory)/copia.db'",
                "ATTACH DATABASE '\(directory)/novo.db' AS novo",
                "DELETE FROM pedidos",
            ],
            autoLeak: (setup: ["CREATE TABLE IF NOT EXISTS vazamento (a INTEGER)", "DELETE FROM vazamento"],
                       begin: "BEGIN", insert: "INSERT INTO vazamento VALUES (1)", count: "SELECT count(*) FROM vazamento"))
    }

    @Test("Todas as verificações passam (nenhuma pulada)", arguments: ConformanceCheck.allCases)
    func conformance(_ check: ConformanceCheck) async throws {
        let db = try ScratchDatabase()
        defer { db.remove() }
        let setup = try await open(db)
        try await run(setup, "CREATE TABLE pedidos (id INTEGER PRIMARY KEY, nome TEXT NOT NULL, criado_em DATETIME)")
        await setup.close()
        let result = await DriverConformance.run(check, Self.fixture(db))
        #expect(result == .passed, "\(check.rawValue): \(result)")
        // VACUUM INTO / ATTACH do corpus de somente leitura não podem ter criado arquivos.
        #expect(!FileManager.default.fileExists(atPath: db.directory.appendingPathComponent("copia.db").path))
        #expect(!FileManager.default.fileExists(atPath: db.directory.appendingPathComponent("novo.db").path))
    }
}

@Suite("Driver SQLite — regras do SPK-N05 (W1-T03)", .serialized)
struct SQLiteDriverTests {
    @Test("NT-DRV-12: journal_mode do arquivo inalterado e sem -wal/-shm residuais (DELETE)")
    func journalModeUntouched() async throws {
        let db = try ScratchDatabase()
        defer { db.remove() }
        let connection = try await open(db)
        try await run(connection, "CREATE TABLE t (a INTEGER, b TEXT)")
        for i in 0..<100 { try await run(connection, "INSERT INTO t VALUES (?, ?)", [.int(Int64(i)), .text("v\(i)")]) }
        _ = try await run(connection, "SELECT * FROM t")
        await connection.close()
        #expect(db.sidecars.isEmpty, "arquivos auxiliares: \(db.sidecars)")
        #expect(db.headerJournalVersion == (1, 1), "o arquivo deixou de ser rollback journal")
        let reopened = try await open(db)
        guard case .rows(_, let batch, _, _) = try await run(reopened, "PRAGMA journal_mode") else { Issue.record("sem linhas"); return }
        #expect(batch.columns[0][0] == .text("delete"))
        await reopened.close()
    }

    @Test("WAL sem sidecars abre em somente leitura (fallback F3b) e não deixa arquivos")
    func walReadOnlyFallback() async throws {
        let db = try ScratchDatabase()
        defer { db.remove() }
        let writer = try await open(db)
        try await run(writer, "PRAGMA journal_mode = WAL")              // instrução do usuário, não do driver
        try await run(writer, "CREATE TABLE t (a)")
        try await run(writer, "INSERT INTO t VALUES (42)")
        await writer.close()
        #expect(db.headerJournalVersion == (2, 2))
        #expect(db.sidecars.isEmpty, "PERSIST_WAL=0 no fechamento deveria remover -wal/-shm: \(db.sidecars)")

        let reader = try await open(db, readOnly: true)
        guard case .rows(_, let batch, _, _) = try await run(reader, "SELECT a FROM t") else { Issue.record("sem linhas"); return }
        #expect(batch.columns[0] == [.int(42)])
        await #expect(throws: DriverError.readOnly) { try await run(reader, "INSERT INTO t VALUES (1)") }
        await reader.close()
        #expect(db.sidecars.isEmpty, "leitura deixou arquivos: \(db.sidecars)")
        #expect(db.headerJournalVersion == (2, 2))
    }

    @Test("NT-DRV-14 (parcial): transação aberta numa conexão não aparece na outra; escrita concorrente → .busy")
    func isolationBetweenConnections() async throws {
        let db = try ScratchDatabase()
        defer { db.remove() }
        let a = try await open(db)
        let b = try await open(db)
        try await run(a, "CREATE TABLE t (a INTEGER)")
        try await run(a, "BEGIN IMMEDIATE")
        try await run(a, "INSERT INTO t VALUES (1)")
        guard case .rows(_, let batch, _, _) = try await run(b, "SELECT count(*) FROM t") else { Issue.record("sem linhas"); return }
        #expect(batch.columns[0] == [.int(0)])
        await #expect(throws: DriverError.busy) { try await run(b, "INSERT INTO t VALUES (2)") }
        #expect(await a.transactionState() == .inTransaction)
        try await run(a, "ROLLBACK")
        #expect(await a.transactionState() == .idle)
        await a.close()
        await b.close()
    }

    @Test("Tipos: inteiros, real, texto, blob, null, bool, data e texto acima do limite")
    func types() async throws {
        let db = try ScratchDatabase()
        defer { db.remove() }
        let connection = try await open(db)
        try await run(connection, "CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n TEXT, f BOOLEAN, d DATETIME, j JSON)")
        try await run(connection, "INSERT INTO t VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [
            .int(9_223_372_036_854_775_807), .double(1.5), .text("ção"), .bytes([0, 1, 2]), .null, .bool(true),
            .text("2026-10-13 12:00:00"), .text("{\"a\":1}"),
        ])
        let limits = ReadLimits(maxRows: 10, maxBytes: 1 << 20, maxCellBytes: 4)
        guard case .rows(let columns, let batch, _, _) = try await connection.execute(BoundStatement(sql: "SELECT * FROM t"), limits: limits) else {
            Issue.record("sem linhas"); return
        }
        #expect(columns.map(\.portableType) == [.bigint, .double, .text, .bytes, .text, .bool, .timestamp, .json])
        let row = batch.columns.map { $0[0] }
        #expect(row[0] == .int(9_223_372_036_854_775_807))
        #expect(row[1] == .double(1.5))
        #expect(row[2] == .truncated(prefix: "çã", totalSize: 5))              // "ção" = 5 bytes; limite 4
        #expect(row[3] == .bytes(preview: [0, 1, 2], totalSize: 3))
        #expect(row[4] == .null)
        #expect(row[5] == .bool(true))
        #expect(row[6] == .timestamp("2026-10-13 12:00:00", timeZone: nil))
        await connection.close()
    }

    @Test("Afetadas, comando e várias instruções recusadas (o divisor é obrigatório)")
    func outcomes() async throws {
        let db = try ScratchDatabase()
        defer { db.remove() }
        let connection = try await open(db)
        guard case .command(let tag) = try await run(connection, "CREATE TABLE t (a)") else { Issue.record("esperado comando"); return }
        #expect(tag == "CREATE")
        try await run(connection, "INSERT INTO t VALUES (1), (2), (3)")
        guard case .affected(let count) = try await run(connection, "UPDATE t SET a = a + 1") else { Issue.record("esperado afetadas"); return }
        #expect(count == 3)
        await #expect(throws: DriverError.self) { try await run(connection, "SELECT 1; SELECT 2") }
        await connection.close()
    }

    @Test("Arquivo inexistente não é criado; alvo de servidor é recusado")
    func missingFile() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("rsk-nao-existe-\(UUID()).db").path
        await #expect(throws: DriverError.self) {
            _ = try await SQLiteDriver().open(.file(path: path, readOnly: false), options: OpenOptions())
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: DriverError.self) {
            try SQLiteDriver().validate(.server(host: "h", port: 1, user: nil, password: nil))
        }
    }

    @Test("Mensagem de erro sem valores do usuário")
    func redaction() async throws {
        let db = try ScratchDatabase()
        defer { db.remove() }
        let connection = try await open(db)
        try await run(connection, "CREATE TABLE t (a TEXT CHECK (a <> 'proibido'))")
        do {
            try await run(connection, "INSERT INTO t VALUES ('proibido')")
            Issue.record("CHECK não falhou")
        } catch {
            #expect("\(error)".contains("proibido") == false)
        }
        await connection.close()
    }
}
