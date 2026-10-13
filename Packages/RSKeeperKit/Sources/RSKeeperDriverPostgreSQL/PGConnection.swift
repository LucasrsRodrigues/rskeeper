import Foundation
import PostgresNIO
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperSQLKit
import Synchronization

/// Logger da PostgresNIO sem saída: SQL e parâmetros nunca vão para log (ADR-N23).
let pgSilentLogger: Logger = {
    var logger = Logger(label: "rskeeper.postgres")
    logger.logLevel = .critical
    return logger
}()

/// Conexão física com o PostgreSQL (uma `PostgresConnection`).
public final class PGConnection: PhysicalConnection {
    public let serverVersion: String
    private let connection: PostgresConnection
    private let endpoint: PGEndpoint
    private let backendPID: Int32
    private let readOnly: Bool
    private let typeCatalog: Mutex<PGTypeCatalog>
    private var types: PGTypeCatalog { typeCatalog.withLock { $0 } }
    private let closed = Mutex(false)
    /// Marcador da execução em curso (para a alça geral `cancelHandle()`).
    private let currentMarker = Mutex<String?>(nil)

    static func marker(_ id: UUID) -> String { "/*rsk:exec=\(id.uuidString.lowercased())*/ " }

    private init(connection: PostgresConnection, endpoint: PGEndpoint, backendPID: Int32, readOnly: Bool,
                 types: PGTypeCatalog, serverVersion: String) {
        self.connection = connection
        self.endpoint = endpoint
        self.backendPID = backendPID
        self.readOnly = readOnly
        self.typeCatalog = Mutex(types)
        self.serverVersion = serverVersion
    }

    static func open(_ endpoint: PGEndpoint, readOnly: Bool) async throws(DriverError) -> PGConnection {
        let connection: PostgresConnection
        do {
            connection = try await PostgresConnection.connect(configuration: endpoint.configuration(), id: PGConnectionIDs.next(),
                                                              logger: pgSilentLogger)
        } catch {
            throw PGErrors.map(error)
        }
        do {
            // Camada 3 do somente leitura (doc 06 §9.2): todo BEGIN implícito ou explícito nasce READ ONLY.
            if readOnly { try await connection.query("SET default_transaction_read_only = on", logger: pgSilentLogger) }
            // `::text`: o resultado vem em binário; decodificar int4 como String daria lixo (e o cancelamento
            // guardado nunca casaria com o backend). Sem PID, a conexão não abre.
            guard let pid = try await scalar(connection, "SELECT pg_backend_pid()::text").flatMap({ Int32($0) }), pid > 0 else {
                throw DriverError.driver(code: "backend-pid", RedactedMessage(alreadyRedacted: "Não foi possível identificar o processo do servidor."))
            }
            let version = try await scalar(connection, "SHOW server_version") ?? "?"
            let types = try await loadTypes(connection)
            return PGConnection(connection: connection, endpoint: endpoint, backendPID: pid, readOnly: readOnly,
                                types: types, serverVersion: "PostgreSQL " + version)
        } catch {
            try? await connection.close()
            throw PGErrors.map(error)
        }
    }

    private static func scalar(_ connection: PostgresConnection, _ sql: String) async throws -> String? {
        for try await row in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: pgSilentLogger) {
            return try row.decode(String.self)
        }
        return nil
    }

    /// Catálogo de tipos (≈600 linhas): resolve enum, tipos de texto e arrays sem consultar no meio do stream.
    private static func loadTypes(_ connection: PostgresConnection, only oids: [Int64]? = nil) async throws -> PGTypeCatalog {
        var entries: [UInt32: PGTypeCatalog.Entry] = [:]
        let sql = "SELECT oid::int8, typname::text, typtype::text, typcategory::text, typelem::int8 FROM pg_type"
        let query: PostgresQuery = if let oids { "\(unescaped: sql) WHERE oid = ANY(\(oids)::oid[])" } else { PostgresQuery(unsafeSQL: sql) }
        let rows = try await connection.query(query, logger: pgSilentLogger)
        for try await (oid, name, kind, category, element) in rows.decode((Int64, String, String, String, Int64).self) {
            entries[UInt32(oid)] = .init(name: name, kind: kind.first ?? "b", category: category.first ?? "X", elementOID: UInt32(element))
        }
        return PGTypeCatalog(entries: entries)
    }

    // MARK: Execução

    public func stream(_ statement: BoundStatement, limits: ReadLimits, batchSize: Int) -> ResultStream {
        let (stream, continuation) = ResultStream.makeStream()
        let task = Task { [self] in
            do {
                try await run(statement, limits: limits, batchSize: batchSize, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: PGErrors.map(error))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(_ statement: BoundStatement, limits: ReadLimits, batchSize: Int,
                     continuation: ResultStream.Continuation) async throws {
        try ensureOpen()
        let split = StatementSplitter.split(statement.sql, dialect: .postgresql)
        guard split.statements.count == 1, let only = split.statements.first else {
            throw DriverError.validation(RedactedMessage(alreadyRedacted: "Envie uma instrução por vez (o divisor separa o script)."))
        }
        let classified = RiskClassifier.classify(only, in: split.lexed)
        if classified.blocked == .copyProtocol {
            throw DriverError.validation(RedactedMessage(alreadyRedacted: "COPY FROM STDIN / TO STDOUT não é suportado no editor; use a exportação."))
        }
        if readOnly, !classified.isAllowedInReadOnly { throw DriverError.readOnly }

        // Marcador por execução: o cancelamento só atinge esta instrução (SPK-N03, guarda).
        let marker = Self.marker(statement.executionID?.raw ?? UUID())
        currentMarker.withLock { $0 = marker }
        defer { currentMarker.withLock { if $0 == marker { $0 = nil } } }
        let query = PostgresQuery(unsafeSQL: marker + statement.sql, binds: try bindings(statement.bindings))
        let mayReturnRows = Self.mayReturnRows(only, split.lexed, classified)

        // Prazo e cancelamento cooperativo → cancelamento guardado no servidor (Task.cancel não age no PG).
        let watchdog = limits.deadline.map { deadline in
            Task { [self] in
                try await Task.sleep(until: deadline, clock: .continuous)
                await cancelGuarded(marker: marker)
            }
        }
        defer { watchdog?.cancel() }
        do {
            try await withTaskCancellationHandler {
                if mayReturnRows {
                    try await streamRows(query, marker: marker, limits: limits, batchSize: batchSize, continuation: continuation)
                } else {
                    try await executeCommand(query, tag: Self.commandTag(only, split.lexed), continuation: continuation)
                }
            } onCancel: {
                Task { await self.cancelGuarded(marker: marker) }
            }
        } catch {
            let mapped = PGErrors.map(error, markerLength: marker.utf8.count)
            if mapped == .cancelled, let deadline = limits.deadline, ContinuousClock.now >= deadline { throw DriverError.timedOut }
            throw mapped
        }
    }

    /// Caminho com contrapressão (`query` assíncrono): colunas imediatas, linhas sob demanda.
    private func streamRows(_ query: PostgresQuery, marker: String, limits: ReadLimits, batchSize: Int,
                            continuation: ResultStream.Continuation) async throws {
        let rows = try await connection.query(query, logger: pgSilentLogger)
        let oids = rows.columns.map { $0.dataType.rawValue }
        await refreshTypes(oids)
        let types = self.types
        let columns = zip(rows.columns, oids).map {
            ResultColumn(name: $0.name, nativeTypeName: types.name(of: $1), portableType: types.portableType(of: $1))
        }
        if columns.isEmpty {
            for try await _ in rows {}
            continuation.yield(.end(.command("OK")))
            return
        }
        continuation.yield(.columns(columns))
        var accumulator = BatchAccumulator(columnCount: columns.count, limits: limits, batchSize: batchSize)
        var stopped = false
        for try await row in rows {
            var values: [CellValue] = []
            values.reserveCapacity(columns.count)
            for (index, cell) in row.enumerated() {
                values.append(PGDecoder.cell(cell.bytes, oid: oids[index], catalog: types, maxCellBytes: limits.maxCellBytes))
            }
            if accumulator.append(values) == .stop { stopped = true; break }
            if accumulator.readyBatch, let batch = accumulator.takeBatch() { continuation.yield(.batch(batch)) }
        }
        if let batch = accumulator.takeBatch() { continuation.yield(.batch(batch)) }
        continuation.yield(.end(accumulator.end))
        if stopped {
            // Ao sair do laço a PostgresNIO drena o resto (segundos em resultados grandes): o cancelamento
            // guardado aborta a drenagem; a sonda confirma que a conexão voltou ao estado ocioso (SPK-N03).
            await cancelGuarded(marker: marker)
            try await probeOrClose()
        }
    }

    /// Caminho sem linhas: variante com callback, que devolve a tag e as linhas afetadas.
    private func executeCommand(_ query: PostgresQuery, tag: String, continuation: ResultStream.Continuation) async throws {
        let metadata = try await connection.query(query, logger: pgSilentLogger) { _ in }.get()
        if let affected = metadata.rows, ["INSERT", "UPDATE", "DELETE", "MERGE", "COPY"].contains(metadata.command) {
            continuation.yield(.end(.affected(affected)))
        } else {
            continuation.yield(.end(.command(metadata.command.isEmpty ? tag : metadata.command)))
        }
    }

    /// W1-D08: só instruções que podem devolver linhas usam o caminho com contrapressão.
    private static func mayReturnRows(_ statement: SQLStatement, _ lexed: LexedSQL, _ classified: ClassifiedStatement) -> Bool {
        if classified.risk == .read || classified.risk == .unknown { return true }
        let words = lexed.tokens[statement.tokenRange].compactMap { lexed.keyword($0) }
        return words.contains("RETURNING") || ["EXPLAIN", "SHOW", "FETCH", "VALUES", "TABLE"].contains(words.first ?? "")
    }

    private static func commandTag(_ statement: SQLStatement, _ lexed: LexedSQL) -> String {
        lexed.tokens[statement.tokenRange].lazy.compactMap { lexed.keyword($0) }.first ?? "OK"
    }

    private func bindings(_ values: [BindValue]) throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: values.count)
        for value in values {
            switch value {
            case .null: bindings.appendNull()
            case .bool(let bool): bindings.append(bool)
            case .int(let int): bindings.append(int)
            case .double(let double): bindings.append(double)
            case .text(let text), .decimalText(let text): bindings.append(text)
            case .bytes(let bytes): bindings.append(ByteBuffer(bytes: bytes))
            }
        }
        return bindings
    }

    // MARK: Cancelamento guardado (SPK-N03)

    /// Numa conexão auxiliar efêmera: cancela o backend **só** se ele ainda estiver executando a
    /// instrução com este marcador. Sem o guarda, o cancel atingiu a consulta seguinte em até 57% das corridas.
    func cancelGuarded(marker: String) async {
        guard let aux = try? await PostgresConnection.connect(configuration: endpoint.configuration(), id: PGConnectionIDs.next(),
                                                             logger: pgSilentLogger) else { return }
        let pattern = marker.trimmingCharacters(in: .whitespaces) + "%"
        _ = try? await aux.query("""
            SELECT pg_cancel_backend(pid) FROM pg_stat_activity
            WHERE pid = \(backendPID) AND state = 'active' AND query LIKE \(pattern)
            """, logger: pgSilentLogger).collect()
        try? await aux.close()
    }

    /// Depois de truncar: a conexão só segue em uso se uma sonda curta concluir; senão é fechada (AR-MEM-08).
    private func probeOrClose() async throws {
        let probe = Task { [connection] in try await connection.query("SELECT 1", logger: pgSilentLogger).collect() }
        let timeout = Task { try await Task.sleep(for: .seconds(5)); probe.cancel() }
        defer { timeout.cancel() }
        if case .failure = await probe.result {
            await close()
            throw DriverError.connection(RedactedMessage(alreadyRedacted: "A conexão não voltou ao estado ocioso e foi descartada."))
        }
    }

    /// Alça da execução em curso **no momento da chamada**; sem execução, não cancela nada.
    public func cancelHandle() -> (any CancelHandle)? {
        PGCancelHandle(connection: self, marker: currentMarker.withLock { $0 })
    }

    /// Alça vinculada à execução (DR-18): nunca atinge a instrução seguinte da conexão.
    public func cancelHandle(for executionID: ExecutionID) -> (any CancelHandle)? {
        PGCancelHandle(connection: self, marker: Self.marker(executionID.raw))
    }

    /// Tipos criados depois de abrir a conexão (enum novo…): busca os OIDs desconhecidos numa conexão
    /// auxiliar, porque a principal está no meio da consulta. Um tipo criado numa transação ainda não
    /// commitada não é visível de fora e continua `.unsupported`.
    private func refreshTypes(_ oids: [UInt32]) async {
        let known = types
        let missing = Set(oids).filter { PGDecoder.builtinPortable[$0] == nil && known.entries[$0] == nil }
        guard !missing.isEmpty,
              let aux = try? await PostgresConnection.connect(configuration: endpoint.configuration(), id: PGConnectionIDs.next(),
                                                             logger: pgSilentLogger) else { return }
        if let found = try? await Self.loadTypes(aux, only: missing.map { Int64($0) }) {
            typeCatalog.withLock { $0 = PGTypeCatalog(entries: $0.entries.merging(found.entries) { _, new in new }) }
        }
        try? await aux.close()
    }

    // MARK: Estado e reset (DR-17)

    /// `SAVEPOINT` só é aceito dentro de transação: sem efeito colateral, distingue ocioso, em
    /// transação e transação falha (25P02). A PostgresNIO não expõe o estado (SPK-N03).
    public func transactionState() async -> TransactionState {
        guard (try? ensureOpen()) != nil else { return .idle }
        do {
            try await connection.query("SAVEPOINT rsk_probe", logger: pgSilentLogger)
            try await connection.query("RELEASE SAVEPOINT rsk_probe", logger: pgSilentLogger)
            return .inTransaction
        } catch {
            switch (error as? PSQLError)?.serverInfo?[.sqlState] {
            case "25P02": return .failed
            default: return .idle
            }
        }
    }

    /// Desfaz transação aberta e limpa o estado da sessão (`DISCARD ALL`: SET, temporárias,
    /// LISTEN, locks consultivos). Reaplica a camada de somente leitura.
    public func resetSession() async throws(DriverError) {
        try ensureOpen()
        do {
            if await transactionState() != .idle { try await connection.query("ROLLBACK", logger: pgSilentLogger) }
            try await connection.query("DISCARD ALL", logger: pgSilentLogger)
            if readOnly { try await connection.query("SET default_transaction_read_only = on", logger: pgSilentLogger) }
        } catch {
            throw PGErrors.map(error)
        }
    }

    public func close() async {
        let wasClosed = closed.withLock { value in
            defer { value = true }
            return value
        }
        guard !wasClosed else { return }
        try? await connection.close()
    }

    /// R-NDRV-08: `query()` numa conexão fechada trava para sempre na PostgresNIO; checar antes.
    private func ensureOpen() throws(DriverError) {
        if closed.withLock({ $0 }) || connection.isClosed {
            throw .connection(RedactedMessage(alreadyRedacted: "Conexão fechada."))
        }
    }

    // MARK: Metadados (pg_catalog; doc 04 §10)

    private func rows(_ sql: String, _ binds: [BindValue] = []) async throws(DriverError) -> [[CellValue]] {
        try ensureOpen()
        do {
            var result: [[CellValue]] = []
            let rows = try await connection.query(PostgresQuery(unsafeSQL: sql, binds: try bindings(binds)), logger: pgSilentLogger)
            let oids = rows.columns.map { $0.dataType.rawValue }
            for try await row in rows {
                result.append(row.enumerated().map { PGDecoder.cell($1.bytes, oid: oids[$0], catalog: types, maxCellBytes: 1 << 16) })
            }
            return result
        } catch {
            throw PGErrors.map(error)
        }
    }

    private static func string(_ value: CellValue) -> String {
        if case .text(let text) = value { return text }
        return ""
    }

    public func databases() async throws(DriverError) -> [DatabaseInfo] {
        try await rows("SELECT datname::text FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname")
            .map { DatabaseInfo(name: Self.string($0[0])) }
    }

    /// Só o database da conexão é navegável (`changeDatabaseInSession = false`).
    public func schemas(in database: String) async throws(DriverError) -> [SchemaInfo] {
        try await rows("""
            SELECT nspname::text FROM pg_namespace
            WHERE nspname NOT LIKE 'pg\\_toast%' AND nspname NOT LIKE 'pg\\_temp\\_%'
            ORDER BY nspname
            """).map { SchemaInfo(ref: SchemaRef(database: database, name: Self.string($0[0]))) }
    }

    public func entities(in schema: SchemaRef) async throws(DriverError) -> [EntityInfo] {
        let name = schema.name ?? "public"
        let relations = try await rows("""
            SELECT c.relname::text, c.relkind::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relkind IN ('r', 'p', 'v', 'm', 'f') ORDER BY c.relname
            """, [.text(name)])
        let routines = try await rows("""
            SELECT DISTINCT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = $1 AND p.prokind IN ('f', 'p') ORDER BY 1
            """, [.text(name)])
        let kinds: [String: EntityKind] = ["r": .table, "p": .table, "f": .table, "v": .view, "m": .materializedView]
        return relations.map { EntityInfo(ref: EntityRef(schema: schema, name: Self.string($0[0])), kind: kinds[Self.string($0[1])] ?? .table) }
            + routines.map { EntityInfo(ref: EntityRef(schema: schema, name: Self.string($0[0])), kind: .routine) }
    }

    public func columns(of entity: EntityRef) async throws(DriverError) -> [ColumnInfo] {
        let dialect = PostgresDialect()
        let qualified = try dialect.quoteIdentifier(entity.schema.name ?? "public") + "." + dialect.quoteIdentifier(entity.name)
        let result = try await rows("""
            SELECT a.attname::text, a.attnum::int8, format_type(a.atttypid, a.atttypmod)::text, a.atttypid::int8,
                   (NOT a.attnotnull), EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey))
            FROM pg_attribute a
            WHERE a.attrelid = to_regclass($1) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """, [.text(qualified)])
        guard !result.isEmpty else { throw .validation(RedactedMessage(alreadyRedacted: "Tabela ou view inexistente.")) }
        return result.map { row in
            let oid: UInt32 = if case .int(let value) = row[3] { UInt32(value) } else { 0 }
            let ordinal: Int = if case .int(let value) = row[1] { Int(value) } else { 0 }
            return ColumnInfo(name: Self.string(row[0]), ordinal: ordinal, declaredType: Self.string(row[2]),
                              portableType: types.portableType(of: oid), nullable: row[4] == .bool(true), isPrimaryKey: row[5] == .bool(true))
        }
    }
}

struct PGCancelHandle: CancelHandle {
    let connection: PGConnection
    let marker: String?
    func cancel() async {
        guard let marker else { return }
        await connection.cancelGuarded(marker: marker)
    }
}

/// IDs de conexão da PostgresNIO (só para correlação interna; nunca exibidos).
enum PGConnectionIDs {
    private static let counter = Atomic<Int>(0)
    static func next() -> Int { counter.add(1, ordering: .relaxed).newValue }
}
