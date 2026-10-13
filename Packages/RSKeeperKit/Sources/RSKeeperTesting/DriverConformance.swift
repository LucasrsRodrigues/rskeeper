import Darwin
import RSKeeperDomain
import RSKeeperDriversCore

/// Verificações da suíte de conformidade (NST-04-01; doc 04 §15). Os IDs seguem o NT-DRV.
/// Verificações que dependem de transações por aba, scripts ou `applyChanges` ficam nas histórias
/// que introduzem esses recursos (NST-07-02, onda 2).
public enum ConformanceCheck: String, Sendable, CaseIterable {
    case openClose = "NT-DRV-01"
    case metadata = "NT-DRV-02"
    case bind = "NT-DRV-04"
    case quoting = "NT-DRV-05"
    case readOnly = "NT-DRV-06"
    case cancelLongQuery = "NT-DRV-07"
    case truncationRows = "NT-DRV-10"
    case truncationBytes = "NT-DRV-10b"
    case usableAfterTruncationAndCancel = "NT-DRV-11"
    case autoModeLeak = "NT-DRV-13"
    case errorsNormalized = "NT-DRV-20"
    case capabilitiesCoherent = "NST-04-01/4.2"
}

public enum ConformanceResult: Sendable, Equatable {
    case passed
    case failed([String])
    /// A fixture não oferece o que a verificação precisa (motivo explícito; nunca conta como aprovação).
    case skipped(String)
}

/// Tudo o que a suíte precisa saber sobre um driver concreto e o banco de teste dele.
/// Os drivers reais montam a fixture sobre bancos **descartáveis** com dados sintéticos.
public struct ConformanceFixture: Sendable {
    public var factory: any DriverFactory
    public var target: ResolvedTarget
    /// Instrução que devolve uma linha e uma coluna.
    public var selectOne: String
    /// Consulta longa e cancelável (≥ 10 s se não for cancelada).
    public var longRunning: String?
    /// SQL que gera `n` linhas com algumas colunas de texto e número.
    public var generateRows: (@Sendable (Int) -> String)?
    /// SQL inválido que contém `secretMarker` (NT-DRV-20: o marcador não pode voltar na mensagem).
    public var invalidSQL: String
    public var secretMarker: String
    /// Metadados esperados de uma tabela da fixture.
    public var expectedTable: (ref: EntityRef, columns: [String])?
    /// SQL que devolve o parâmetro 1 como texto (`SELECT ?`, `SELECT $1::text`).
    public var echoParameter: String?
    /// DDL que cria uma tabela com uma coluna de nome dado (já citado) no schema da fixture; e onde procurar.
    public var createTableWithColumn: (@Sendable (_ quotedTable: String, _ quotedColumn: String) -> String)?
    public var scratchSchema: SchemaRef?
    /// Corpus de contorno de somente leitura (cada instrução precisa falhar numa conexão `readOnly`).
    public var readOnlyBypassCorpus: [String]
    /// Vazamento em modo Auto: (preparar, iniciar transação, inserir, contar linhas inseridas).
    public var autoLeak: (setup: [String], begin: String, insert: String, count: String)?
    /// Teto de crescimento de memória ao truncar 5 M de linhas [META].
    public var truncationMemoryCeiling: Int

    public init(factory: any DriverFactory, target: ResolvedTarget, selectOne: String = "SELECT 1",
                longRunning: String? = nil, generateRows: (@Sendable (Int) -> String)? = nil,
                invalidSQL: String, secretMarker: String, expectedTable: (ref: EntityRef, columns: [String])? = nil,
                echoParameter: String? = nil,
                createTableWithColumn: (@Sendable (String, String) -> String)? = nil, scratchSchema: SchemaRef? = nil,
                readOnlyBypassCorpus: [String] = [],
                autoLeak: (setup: [String], begin: String, insert: String, count: String)? = nil,
                truncationMemoryCeiling: Int = 200 * 1024 * 1024) {
        self.factory = factory
        self.target = target
        self.selectOne = selectOne
        self.longRunning = longRunning
        self.generateRows = generateRows
        self.invalidSQL = invalidSQL
        self.secretMarker = secretMarker
        self.expectedTable = expectedTable
        self.echoParameter = echoParameter
        self.createTableWithColumn = createTableWithColumn
        self.scratchSchema = scratchSchema
        self.readOnlyBypassCorpus = readOnlyBypassCorpus
        self.autoLeak = autoLeak
        self.truncationMemoryCeiling = truncationMemoryCeiling
    }
}

/// Suíte de conformidade. Cada verificação abre as próprias conexões e as fecha.
public enum DriverConformance {
    public static func run(_ check: ConformanceCheck, _ fixture: ConformanceFixture) async -> ConformanceResult {
        var failures: [String] = []
        func fail(_ message: String) { failures.append(message) }
        do {
            switch check {
            case .openClose: try await openClose(fixture, fail)
            case .metadata:
                guard let expected = fixture.expectedTable else { return .skipped("fixture sem tabela esperada") }
                try await metadata(fixture, expected, fail)
            case .bind:
                guard let echo = fixture.echoParameter else { return .skipped("fixture sem SQL de eco") }
                try await bind(fixture, echo, fail)
            case .quoting:
                guard let create = fixture.createTableWithColumn, let schema = fixture.scratchSchema else {
                    return .skipped("fixture sem DDL de teste")
                }
                try await quoting(fixture, create, schema, fail)
            case .readOnly:
                guard !fixture.readOnlyBypassCorpus.isEmpty else { return .skipped("fixture sem corpus de somente leitura") }
                try await readOnly(fixture, fail)
            case .cancelLongQuery:
                guard let long = fixture.longRunning else { return .skipped("fixture sem consulta longa") }
                try await cancelLongQuery(fixture, long, fail)
            case .truncationRows:
                guard let generate = fixture.generateRows else { return .skipped("fixture sem gerador de linhas") }
                try await truncationRows(fixture, generate, fail)
            case .truncationBytes:
                guard let generate = fixture.generateRows else { return .skipped("fixture sem gerador de linhas") }
                try await truncationBytes(fixture, generate, fail)
            case .usableAfterTruncationAndCancel:
                guard let generate = fixture.generateRows else { return .skipped("fixture sem gerador de linhas") }
                try await usableAfter(fixture, generate, fail)
            case .autoModeLeak:
                guard let leak = fixture.autoLeak else { return .skipped("fixture sem cenário de transação") }
                try await autoModeLeak(fixture, leak, fail)
            case .errorsNormalized: try await errorsNormalized(fixture, fail)
            case .capabilitiesCoherent:
                let descriptor = fixture.factory.descriptor
                descriptor.capabilities.inconsistencies(for: descriptor.targetKind).forEach(fail)
            }
        } catch {
            fail("erro inesperado: \(DriverError.normalized(error))")
        }
        return failures.isEmpty ? .passed : .failed(failures)
    }

    // MARK: Verificações

    private static func open(_ fixture: ConformanceFixture, readOnly: Bool = false) async throws(DriverError) -> any PhysicalConnection {
        try await fixture.factory.open(fixture.target, options: OpenOptions(readOnly: readOnly))
    }

    private static func isSelectOne(_ outcome: StatementOutcome) -> Bool {
        if case .rows(_, let batch, _, let count) = outcome { return count == 1 && batch.rowCount == 1 }
        return false
    }

    private static func openClose(_ f: ConformanceFixture, _ fail: (String) -> Void) async throws {
        let connection = try await open(f)
        if connection.serverVersion.isEmpty { fail("serverVersion vazio") }
        if !isSelectOne(try await connection.execute(BoundStatement(sql: f.selectOne), limits: .default)) {
            fail("selectOne não devolveu 1 linha")
        }
        await connection.close()
        do {
            _ = try await connection.execute(BoundStatement(sql: f.selectOne), limits: .default)
            fail("executar após close não falhou")
        } catch {
            if case .connection = error {} else { fail("após close: esperado .connection, veio \(error)") }
        }
    }

    private static func metadata(_ f: ConformanceFixture, _ expected: (ref: EntityRef, columns: [String]),
                                 _ fail: (String) -> Void) async throws {
        let connection = try await open(f)
        defer { Task { await connection.close() } }
        if let database = expected.ref.schema.database {
            if !(try await connection.databases()).contains(where: { $0.name == database }) { fail("database \(database) ausente") }
            if let schema = expected.ref.schema.name,
               !(try await connection.schemas(in: database)).contains(where: { $0.ref.name == schema }) {
                fail("schema \(schema) ausente")
            }
        }
        let entities = try await connection.entities(in: expected.ref.schema)
        if !entities.contains(where: { $0.ref.name == expected.ref.name && $0.kind == .table }) { fail("tabela \(expected.ref.name) ausente") }
        let columns = try await connection.columns(of: expected.ref).sorted { $0.ordinal < $1.ordinal }.map(\.name)
        if columns != expected.columns { fail("colunas \(columns) ≠ \(expected.columns)") }
    }

    private static func bind(_ f: ConformanceFixture, _ echo: String, _ fail: (String) -> Void) async throws {
        let connection = try await open(f)
        defer { Task { await connection.close() } }
        let values = ["simples", "aspas ' e \" ", "x'; DROP TABLE t; --", "ünïcødé 🎉 中文", String(repeating: "a", count: 10_000)]
        for value in values {
            let outcome = try await connection.execute(BoundStatement(sql: echo, bindings: [.text(value)]), limits: .default)
            guard case .rows(_, let batch, _, _) = outcome, batch.rowCount == 1 else { fail("eco sem linha para \(value.prefix(20))"); continue }
            let cell = batch.columns[0][0]
            if cell != .text(value) { fail("eco alterou o valor: \(value.prefix(20)) → \(cell)") }
        }
        // NUL: devolve igual ou recusa com .validation; nunca altera o SQL.
        do {
            let outcome = try await connection.execute(BoundStatement(sql: echo, bindings: [.text("a\u{0}b")]), limits: .default)
            if case .rows(_, let batch, _, _) = outcome, batch.columns[0][0] != .text("a\u{0}b") { fail("NUL alterado") }
        } catch {
            switch error {
            case .validation, .driver: break
            default: fail("NUL: erro inesperado \(error)")
            }
        }
    }

    private static func quoting(_ f: ConformanceFixture, _ create: @Sendable (String, String) -> String, _ schema: SchemaRef,
                                _ fail: (String) -> Void) async throws {
        let connection = try await open(f)
        defer { Task { await connection.close() } }
        let dialect = f.factory.descriptor.dialect
        for (index, name) in ["aspas\"dentro", "ponto.no.meio", "com espaço", "ção_ü", "MiXeD"].enumerated() {
            let table = "rk_quote_\(index)_\(UInt32.random(in: 0...UInt32.max))"
            let quotedTable = try dialect.qualified(EntityRef(schema: schema, name: table))
            _ = try await connection.execute(BoundStatement(sql: create(quotedTable, try dialect.quoteIdentifier(name))), limits: .default)
            let columns = try await connection.columns(of: EntityRef(schema: schema, name: table)).map(\.name)
            if columns != [name] { fail("identificador \(name) voltou como \(columns)") }
            _ = try await connection.execute(BoundStatement(sql: "DROP TABLE \(quotedTable)"), limits: .default)
        }
        do {
            _ = try dialect.quoteIdentifier("com\u{0}nul")
            fail("quoteIdentifier aceitou NUL")
        } catch {}
    }

    private static func readOnly(_ f: ConformanceFixture, _ fail: (String) -> Void) async throws {
        let connection = try await open(f, readOnly: true)
        defer { Task { await connection.close() } }
        for sql in f.readOnlyBypassCorpus {
            do {
                _ = try await connection.execute(BoundStatement(sql: sql), limits: .default)
                fail("somente leitura aceitou: \(sql)")
            } catch {
                switch error {
                case .readOnly, .validation, .driver, .syntaxOrSemantic: break
                default: fail("\(sql): erro inesperado \(error)")
                }
            }
        }
        if !isSelectOne(try await connection.execute(BoundStatement(sql: f.selectOne), limits: .default)) {
            fail("leitura falhou depois do corpus")
        }
    }

    private static func cancelLongQuery(_ f: ConformanceFixture, _ long: String, _ fail: (String) -> Void) async throws {
        let connection = try await open(f)
        defer { Task { await connection.close() } }
        // 1. Cancelando a Task consumidora.
        let clock = ContinuousClock()
        let task = Task { () async throws -> StatementOutcome in   // sem typed throws: crash do IRGen no Swift 6.4 (W1-D01)
            try await connection.execute(BoundStatement(sql: long), limits: .default)
        }
        try await Task.sleep(for: .milliseconds(300))
        let start = clock.now
        task.cancel()
        let result = await task.result
        let latency = clock.now - start
        if case .success = result { fail("consulta longa terminou sem cancelar") }
        if case .failure(let error) = result {
            if case .cancelled = DriverError.normalized(error) {} else { fail("cancelamento: esperado .cancelled, veio \(error)") }
        }
        if latency > .seconds(2) { fail("cancelamento levou \(latency) (meta ≤ 2 s)") }
        // 2. Pela alça de cancelamento.
        if let handle = connection.cancelHandle() {
            let second = Task { () async throws -> StatementOutcome in   // sem typed throws: crash do IRGen no Swift 6.4 (W1-D01)
                try await connection.execute(BoundStatement(sql: long), limits: .default)
            }
            try await Task.sleep(for: .milliseconds(300))
            let handleStart = clock.now
            await handle.cancel()
            let handleResult = await second.result
            if case .success = handleResult { fail("alça de cancelamento não interrompeu") }
            if clock.now - handleStart > .seconds(2) { fail("alça levou \(clock.now - handleStart)") }
        }
        if !isSelectOne(try await connection.execute(BoundStatement(sql: f.selectOne), limits: .default)) {
            fail("conexão inutilizável depois do cancelamento")
        }
    }

    private static func truncationRows(_ f: ConformanceFixture, _ generate: @Sendable (Int) -> String,
                                       _ fail: (String) -> Void) async throws {
        let connection = try await open(f)
        defer { Task { await connection.close() } }
        let before = MemoryProbe.footprint()
        var peak = before
        var rows = 0
        var end: ResultEnd?
        let limits = ReadLimits(maxRows: 50_000, maxBytes: 1 << 30, maxCellBytes: CellValueLimits.inlineTextMax)
        for try await event in connection.stream(BoundStatement(sql: generate(5_000_000)), limits: limits, batchSize: 1_000) {
            switch event {
            case .batch(let batch):
                rows += batch.rowCount
                peak = max(peak, MemoryProbe.footprint())
            case .end(let resultEnd): end = resultEnd
            case .columns: break
            }
        }
        if end != .rows(truncated: .maxRows(50_000), rowCount: 50_000) { fail("fim esperado maxRows(50000), veio \(String(describing: end))") }
        if rows != 50_000 { fail("lotes somaram \(rows) linhas") }
        if peak - before > f.truncationMemoryCeiling { fail("memória cresceu \((peak - before) >> 20) MB") }
    }

    private static func truncationBytes(_ f: ConformanceFixture, _ generate: @Sendable (Int) -> String,
                                        _ fail: (String) -> Void) async throws {
        let connection = try await open(f)
        defer { Task { await connection.close() } }
        let limits = ReadLimits(maxRows: 1_000_000, maxBytes: 64 * 1024, maxCellBytes: CellValueLimits.inlineTextMax)
        let outcome = try await connection.execute(BoundStatement(sql: generate(100_000)), limits: limits)
        guard case .rows(_, let batch, let truncated, let count) = outcome else { return fail("sem linhas") }
        if truncated != .maxBytes(64 * 1024) { fail("esperado maxBytes, veio \(String(describing: truncated))") }
        if batch.estimatedByteCount > 64 * 1024 { fail("lote passou do teto de bytes") }
        if count == 0 || count >= 100_000 { fail("contagem inesperada \(count)") }
    }

    private static func usableAfter(_ f: ConformanceFixture, _ generate: @Sendable (Int) -> String,
                                    _ fail: (String) -> Void) async throws {
        let connection = try await open(f)
        defer { Task { await connection.close() } }
        // Truncar e, em seguida, abandonar um stream no meio.
        _ = try await connection.execute(BoundStatement(sql: generate(200_000)),
                                         limits: ReadLimits(maxRows: 10, maxBytes: 1 << 30, maxCellBytes: 1 << 16))
        let bigSQL = generate(1_000_000)
        let abandoned = Task {
            for try await event in connection.stream(BoundStatement(sql: bigSQL), limits: .default, batchSize: 100) {
                if case .batch = event { break }
            }
        }
        _ = await abandoned.result
        for _ in 0..<3 {
            if !isSelectOne(try await connection.execute(BoundStatement(sql: f.selectOne), limits: .default)) {
                fail("SELECT 1 falhou depois de truncar ou abandonar o stream")
            }
        }
    }

    private static func autoModeLeak(_ f: ConformanceFixture, _ leak: (setup: [String], begin: String, insert: String, count: String),
                                     _ fail: (String) -> Void) async throws {
        let a = try await open(f)
        let b = try await open(f)
        defer { Task { await a.close(); await b.close() } }
        for sql in leak.setup { _ = try await a.execute(BoundStatement(sql: sql), limits: .default) }
        _ = try await a.execute(BoundStatement(sql: leak.begin), limits: .default)
        _ = try await a.execute(BoundStatement(sql: leak.insert), limits: .default)
        if await a.transactionState() != .inTransaction { fail("transactionState não detectou o BEGIN") }
        try await a.resetSession()
        if await a.transactionState() != .idle { fail("resetSession não encerrou a transação") }
        for connection in [a, b] {
            let outcome = try await connection.execute(BoundStatement(sql: leak.count), limits: .default)
            if case .rows(_, let batch, _, _) = outcome, batch.columns.first?.first != .int(0) {
                fail("linha não commitada vazou: \(String(describing: batch.columns.first?.first))")
            }
        }
    }

    private static func errorsNormalized(_ f: ConformanceFixture, _ fail: (String) -> Void) async throws {
        let connection = try await open(f)
        defer { Task { await connection.close() } }
        do {
            _ = try await connection.execute(BoundStatement(sql: f.invalidSQL), limits: .default)
            fail("SQL inválido não falhou")
        } catch {
            let message: String
            switch error {
            case .syntaxOrSemantic(let text, _): message = text.text
            case .driver(_, let text): message = text.text
            default: return fail("esperado .syntaxOrSemantic/.driver, veio \(error)")
            }
            if message.contains(f.secretMarker) { fail("a mensagem de erro contém o SQL do usuário") }
        }
        if !isSelectOne(try await connection.execute(BoundStatement(sql: f.selectOne), limits: .default)) {
            fail("conexão inutilizável depois do erro")
        }
    }
}

/// Memória física do processo (`phys_footprint`), para o teto do NT-DRV-10.
public enum MemoryProbe {
    public static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
