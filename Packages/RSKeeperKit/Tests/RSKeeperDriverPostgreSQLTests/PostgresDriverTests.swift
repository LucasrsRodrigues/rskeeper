import Foundation
import Testing
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperDriverPostgreSQL
import RSKeeperTesting

/// Bancos de teste: containers descartáveis de `scripts/ci/pg-test.sh` (127.0.0.1:554<versão>).
/// Sem `RSK_PG_PORTS`, os testes aparecem como **pulados** (nunca aprovados em silêncio);
/// o job de drivers do CI sempre define a variável.
enum PGTestEnvironment {
    static let ports: [Int] = (ProcessInfo.processInfo.environment["RSK_PG_PORTS"] ?? "")
        .split(separator: ",").compactMap { Int($0) }
    static let password = ProcessInfo.processInfo.environment["RSK_PG_PASSWORD"] ?? ""
    static var available: Bool { !ports.isEmpty }

    static func target(_ port: Int, password: String = PGTestEnvironment.password) -> ResolvedTarget {
        .server(host: "127.0.0.1", port: UInt16(port), user: "rskeeper", password: SecretValue(password), database: "rskeeper_test")
    }

    static func open(_ port: Int, readOnly: Bool = false) async throws -> any PhysicalConnection {
        try await PostgresDriver().open(target(port), options: OpenOptions(readOnly: readOnly))
    }
}

@discardableResult
private func run(_ connection: any PhysicalConnection, _ sql: String, _ bindings: [BindValue] = []) async throws -> StatementOutcome {
    try await connection.execute(BoundStatement(sql: sql, bindings: bindings), limits: .default)
}

private func firstCell(_ outcome: StatementOutcome) -> CellValue? {
    if case .rows(_, let batch, _, _) = outcome { return batch.columns.first?.first }
    return nil
}

@Suite("Driver PostgreSQL — conformidade (W1-T04, NST-04-03)", .serialized, .enabled(if: PGTestEnvironment.available))
struct PostgresConformanceTests {
    static func fixture(_ port: Int, schema: String) -> ConformanceFixture {
        ConformanceFixture(
            factory: PostgresDriver(),
            target: PGTestEnvironment.target(port),
            longRunning: "SELECT pg_sleep(30)",
            generateRows: { n in "SELECT g::int8 AS id, 'linha ' || g AS nome, (g * 1.5)::numeric(20,2) AS valor FROM generate_series(1, \(n)) g" },
            invalidSQL: "SELEC 'segredo-xyz' FROM nada",
            secretMarker: "segredo-xyz",
            expectedTable: (EntityRef(schema: SchemaRef(database: "rskeeper_test", name: schema), name: "pedidos"), ["id", "nome", "criado_em"]),
            echoParameter: "SELECT $1::text",
            createTableWithColumn: { table, column in "CREATE TABLE \(table) (\(column) text)" },
            scratchSchema: SchemaRef(database: nil, name: schema),
            readOnlyBypassCorpus: [
                "INSERT INTO \(schema).pedidos (nome) VALUES ('x')",
                "CREATE TABLE \(schema).z (a int)",
                "BEGIN READ WRITE",
                "SET TRANSACTION READ WRITE",
                "SET default_transaction_read_only = off",
                "RESET ALL",
                "SELECT nextval('\(schema).pedidos_id_seq')",                    // classificado como leitura; barrado pelo servidor
                "DELETE FROM \(schema).pedidos",
            ],
            autoLeak: (setup: ["CREATE TABLE IF NOT EXISTS \(schema).vazamento (a int)", "DELETE FROM \(schema).vazamento"],
                       begin: "BEGIN", insert: "INSERT INTO \(schema).vazamento VALUES (1)",
                       count: "SELECT count(*) FROM \(schema).vazamento"))
    }

    /// Cada caso usa um schema próprio, criado e removido no teste (dados sintéticos).
    @Test("Todas as verificações passam em cada versão (nenhuma pulada)",
          arguments: PGTestEnvironment.ports, ConformanceCheck.allCases)
    func conformance(port: Int, check: ConformanceCheck) async throws {
        let schema = "rsk_t_\(UInt32.random(in: 0...UInt32.max))"
        let setup = try await PGTestEnvironment.open(port)
        try await run(setup, "CREATE SCHEMA \(schema)")
        try await run(setup, "CREATE TABLE \(schema).pedidos (id serial PRIMARY KEY, nome text NOT NULL, criado_em timestamptz)")
        let result = await DriverConformance.run(check, Self.fixture(port, schema: schema))
        try await run(setup, "DROP SCHEMA \(schema) CASCADE")
        await setup.close()
        #expect(result == .passed, "porta \(port) — \(check.rawValue): \(result)")
    }
}

@Suite("Driver PostgreSQL — condições do SPK-N03 (W1-T04)", .serialized, .enabled(if: PGTestEnvironment.available))
struct PostgresDriverTests {
    @Test("NT-DRV-08: cancelamento em corrida com a conclusão nunca atinge a consulta seguinte", arguments: PGTestEnvironment.ports)
    func cancelRace(port: Int) async throws {
        let connection = try await PGTestEnvironment.open(port)
        defer { Task { await connection.close() } }
        var hitNext = 0
        var cancelledShort = 0
        for i in 0..<60 {
            // Consulta curta; o cancel chega perto do fim; a seguinte começa logo depois.
            // Como a sessão faz: a instrução leva o ExecutionID e a alça é vinculada a ele.
            let execution = ExecutionID.generate()
            let short = Task {
                try await connection.execute(BoundStatement(sql: "SELECT pg_sleep(0.05), \(i)", executionID: execution), limits: .default)
            }
            try await Task.sleep(for: .milliseconds(Int.random(in: 20...60)))
            let handle = try #require(connection.cancelHandle(for: execution))
            let cancel = Task { await handle.cancel() }
            if case .failure = await short.result { cancelledShort += 1 }
            do {
                try await run(connection, "SELECT pg_sleep(0.03)")
            } catch {
                hitNext += 1
            }
            await cancel.value
        }
        #expect(hitNext == 0, "o cancelamento atingiu a consulta seguinte \(hitNext)× em 60")
        // Controle positivo: sem isto, um cancelamento que nunca age passaria (já aconteceu: PID lido errado).
        #expect(cancelledShort > 0, "o cancelamento nunca interrompeu a consulta alvo: teste sem poder de detecção")
    }

    @Test("Tipos binários → CellValue (numeric exato, int8, json/jsonb, bytea, timestamptz, arrays, uuid, enum)",
          arguments: PGTestEnvironment.ports)
    func types(port: Int) async throws {
        let connection = try await PGTestEnvironment.open(port)
        defer { Task { await connection.close() } }
        let typeName = "rsk_humor_\(UInt32.random(in: 0...UInt32.max))"
        try await run(connection, "CREATE TYPE \(typeName) AS ENUM ('feliz', 'triste')")
        defer { Task { _ = try? await run(connection, "DROP TYPE \(typeName)") } }
        let outcome = try await run(connection, """
            SELECT 12345678901234567890.123456789::numeric, (-0.000123)::numeric, 9223372036854775807::int8,
                   '{"a": [1, 2]}'::jsonb, '\\x00ff10'::bytea, '2026-10-13 12:34:56.789+00'::timestamptz,
                   '2026-10-13'::date, ARRAY[1, NULL, 3]::int4[], ARRAY[['a','b'],['c','d']]::text[],
                   'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid, 'triste'::\(typeName), NULL::text, true,
                   '1 year 2 mons 3 days 04:05:06'::interval, '192.168.0.1/24'::inet, 'infinity'::timestamp,
                   1.5::float4, B'101'::bit(3)
            """)
        guard case .rows(let columns, let batch, _, _) = outcome else { Issue.record("sem linhas"); return }
        let row = batch.columns.map { $0[0] }
        #expect(row[0] == .decimal("12345678901234567890.123456789"))
        #expect(row[1] == .decimal("-0.000123"))
        #expect(row[2] == .int(9_223_372_036_854_775_807))
        #expect(row[3] == .json("{\"a\": [1, 2]}"))
        #expect(row[4] == .bytes(preview: [0x00, 0xFF, 0x10], totalSize: 3))
        #expect(row[5] == .timestamp("2026-10-13 12:34:56.789", timeZone: "UTC"))
        #expect(row[6] == .date("2026-10-13"))
        #expect(row[7] == .array([.int(1), .null, .int(3)]))
        #expect(row[8] == .array([.array([.text("a"), .text("b")]), .array([.text("c"), .text("d")])]))
        #expect(row[9] == .uuid(UUID(uuidString: "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")!))
        #expect(row[10] == .text("triste"))
        #expect(row[11] == .null)
        #expect(row[12] == .bool(true))
        #expect(row[13] == .text("1 year 2 mons 3 days 04:05:06"))
        #expect(row[14] == .text("192.168.0.1/24"))
        #expect(row[15] == .timestamp("infinity", timeZone: nil))
        #expect(row[16] == .double(1.5))
        #expect(row[17] == .text("101"))
        #expect(columns[0].nativeTypeName == "numeric" && columns[10].nativeTypeName == typeName)
        #expect(columns[7].portableType == .array)
    }

    @Test("COPY STDIN/STDOUT bloqueado; várias instruções recusadas (divisor obrigatório)", arguments: PGTestEnvironment.ports)
    func blockedStatements(port: Int) async throws {
        let connection = try await PGTestEnvironment.open(port)
        defer { Task { await connection.close() } }
        for sql in ["COPY (SELECT 1) TO STDOUT", "COPY pg_class FROM STDIN", "SELECT 1; SELECT 2"] {
            await #expect(throws: DriverError.self, "\(sql)") { try await run(connection, sql) }
        }
        #expect(firstCell(try await run(connection, "SELECT 1")) == .int(1))
    }

    @Test("Afetadas, comando e RETURNING", arguments: PGTestEnvironment.ports)
    func outcomes(port: Int) async throws {
        let connection = try await PGTestEnvironment.open(port)
        defer { Task { await connection.close() } }
        try await run(connection, "CREATE TEMP TABLE t (a int)")
        guard case .affected(let inserted) = try await run(connection, "INSERT INTO t SELECT generate_series(1, 5)") else {
            Issue.record("esperado afetadas"); return
        }
        #expect(inserted == 5)
        guard case .rows(_, let batch, _, _) = try await run(connection, "UPDATE t SET a = a * 10 WHERE a <= 2 RETURNING a") else {
            Issue.record("esperado linhas do RETURNING"); return
        }
        #expect(batch.columns[0] == [.int(10), .int(20)])
        guard case .command(let tag) = try await run(connection, "CREATE TEMP TABLE u (b int)") else { Issue.record("esperado comando"); return }
        #expect(tag == "CREATE TABLE")
    }

    @Test("Transação: estado ocioso, aberto e falho (25P02); reset desfaz e limpa SET", arguments: PGTestEnvironment.ports)
    func transactionStates(port: Int) async throws {
        let connection = try await PGTestEnvironment.open(port)
        defer { Task { await connection.close() } }
        #expect(await connection.transactionState() == .idle)
        try await run(connection, "BEGIN")
        #expect(await connection.transactionState() == .inTransaction)
        _ = try? await run(connection, "SELECT 1 / 0")
        #expect(await connection.transactionState() == .failed)
        try await connection.resetSession()
        #expect(await connection.transactionState() == .idle)
        try await run(connection, "SET search_path TO pg_catalog")
        try await connection.resetSession()
        guard case .rows(_, let batch, _, _) = try await run(connection, "SHOW search_path") else { Issue.record("sem linhas"); return }
        #expect(batch.columns[0][0] == .text("\"$user\", public"))
    }

    @Test("Autenticação recusada → .authentication; servidor inexistente → .connection")
    func connectionErrors() async throws {
        let port = try #require(PGTestEnvironment.ports.first)
        await #expect(throws: DriverError.authentication) {
            _ = try await PostgresDriver().open(PGTestEnvironment.target(port, password: "errada"), options: OpenOptions())
        }
        do {
            _ = try await PostgresDriver().open(.server(host: "127.0.0.1", port: 1, user: "x", password: nil, database: nil),
                                                options: OpenOptions(connectTimeoutSeconds: 3))
            Issue.record("conectou numa porta fechada")
        } catch {
            switch error {
            case .connection, .timedOut: break
            default: Issue.record("esperado .connection, veio \(error)")
            }
        }
    }

    @Test("Metadados: schemas de sistema presentes; rotinas e views listadas", arguments: PGTestEnvironment.ports)
    func metadata(port: Int) async throws {
        let connection = try await PGTestEnvironment.open(port)
        defer { Task { await connection.close() } }
        let schemas = try await connection.schemas(in: "rskeeper_test").compactMap(\.ref.name)
        #expect(schemas.contains("public") && schemas.contains("pg_catalog") && schemas.contains("information_schema"))
        #expect(try await connection.databases().contains { $0.name == "rskeeper_test" })
        let catalog = try await connection.entities(in: SchemaRef(database: "rskeeper_test", name: "pg_catalog"))
        #expect(catalog.contains { $0.ref.name == "pg_class" && $0.kind == .table })
        #expect(catalog.contains { $0.ref.name == "pg_stat_activity" && $0.kind == .view })
        #expect(catalog.contains { $0.ref.name == "now" && $0.kind == .routine })
    }
}

@Suite("Driver PostgreSQL — servidor derruba a conexão (W1-T10, NT-INT)", .enabled(if: PGTestEnvironment.available))
struct PostgresConnectionLossTests {
    @Test("pg_terminate_backend: a próxima consulta falha como .connection, sem travar (R-NDRV-08)", arguments: PGTestEnvironment.ports)
    func serverTerminatesConnection(port: Int) async throws {
        let victim = try await PGTestEnvironment.open(port)
        let admin = try await PGTestEnvironment.open(port)
        defer { Task { await admin.close(); await victim.close() } }
        guard case .rows(_, let batch, _, _) = try await victim.execute(BoundStatement(sql: "SELECT pg_backend_pid()::int8"), limits: .default),
              case .int(let pid) = batch.columns[0][0] else { Issue.record("sem pid"); return }
        _ = try await admin.execute(BoundStatement(sql: "SELECT pg_terminate_backend($1::int4)", bindings: [.int(pid)]), limits: .default)
        try await Task.sleep(for: .milliseconds(300))
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await victim.execute(BoundStatement(sql: "SELECT 1"), limits: .default)
            Issue.record("consulta numa conexão derrubada não falhou")
        } catch {
            switch error {
            case .connection: break
            default: Issue.record("esperado .connection, veio \(error)")
            }
        }
        #expect(clock.now - start < .seconds(5), "a falha precisa ser rápida (R-NDRV-08)")
    }
}
