import RSKeeperDomain
import RSKeeperDriversCore

/// Driver em memória para testes (W0-T18). Não fala com nenhum banco.
///
/// Respostas fixas por SQL exato, atraso configurável e cancelamento cooperativo.
public struct InMemoryDriver: DriverFactory {
    public struct Script: Sendable {
        public var responses: [String: StatementOutcome]
        /// Resultados gerados sob demanda (sem materializar), para testes de truncamento (NT-DRV-10).
        public var generated: [String: RowGenerator]
        /// Erros por SQL exato (NT-DRV-20).
        public var failures: [String: DriverError]
        public var catalog: InMemoryCatalog
        /// Atraso por SQL exato (consulta "longa" cancelável); senão vale `delay`.
        public var slow: [String: Duration]
        public var delay: Duration
        public var openDelay: Duration
        public var failOpen: DriverError?

        public init(responses: [String: StatementOutcome] = [:], generated: [String: RowGenerator] = [:],
                    failures: [String: DriverError] = [:], catalog: InMemoryCatalog = InMemoryCatalog(),
                    slow: [String: Duration] = [:], delay: Duration = .zero, openDelay: Duration = .zero, failOpen: DriverError? = nil) {
            self.responses = responses
            self.generated = generated
            self.failures = failures
            self.catalog = catalog
            self.slow = slow
            self.delay = delay
            self.openDelay = openDelay
            self.failOpen = failOpen
        }
    }

    public let descriptor: DriverDescriptor
    public let script: Script
    public let log: InMemoryDriverLog

    public init(script: Script = Script(), log: InMemoryDriverLog = InMemoryDriverLog()) {
        self.script = script
        self.log = log
        self.descriptor = DriverDescriptor(
            id: DriverID(rawValue: "inmemory"), displayName: "In-Memory (teste)", targetKind: .server,
            capabilities: DriverCapabilities(cancel: .server), dialect: ANSIDialect())
    }

    public func validate(_ target: ConnectionTarget) throws(DriverError) {
        guard target.kind == .server else { throw .validation(RedactedMessage(alreadyRedacted: "Alvo deve ser servidor.")) }
    }

    public func open(_ target: ResolvedTarget, options: OpenOptions) async throws(DriverError) -> any PhysicalConnection {
        do { try await Task.sleep(for: script.openDelay) } catch { throw .cancelled }
        if let failure = script.failOpen { throw failure }
        let number = await log.allocateConnectionNumber()
        let connection = InMemoryConnection(number: number, script: script, log: log)
        await log.record(.opened(number))
        return connection
    }
}

/// Gerador de linhas: `rowCount` linhas calculadas por `(linha, coluna)`.
public struct RowGenerator: Sendable {
    public let columns: [ResultColumn]
    public let rowCount: Int
    public let cell: @Sendable (Int, Int) -> CellValue
    public init(columns: [ResultColumn], rowCount: Int, cell: @escaping @Sendable (Int, Int) -> CellValue) {
        self.columns = columns
        self.rowCount = rowCount
        self.cell = cell
    }
}

/// Catálogo fixo de metadados do driver em memória.
public struct InMemoryCatalog: Sendable {
    public var databases: [String]
    public var schemas: [String: [String]]
    public var entities: [SchemaRef: [EntityInfo]]
    public var columns: [EntityRef: [ColumnInfo]]
    public init(databases: [String] = ["memoria"], schemas: [String: [String]] = ["memoria": ["public"]],
                entities: [SchemaRef: [EntityInfo]] = [:], columns: [EntityRef: [ColumnInfo]] = [:]) {
        self.databases = databases
        self.schemas = schemas
        self.entities = entities
        self.columns = columns
    }
}

/// Eventos observáveis do driver em memória, para os testes verificarem ordem e efeitos.
public actor InMemoryDriverLog {
    public enum Event: Hashable, Sendable {
        case opened(Int), executed(String), cancelled(String), rolledBack(Int), reset(Int), closed(Int)
    }
    public private(set) var events: [Event] = []
    private var nextConnection = 0
    public init() {}
    public func record(_ event: Event) { events.append(event) }
    /// Número sequencial da próxima conexão aberta (identifica a conexão nos eventos).
    func allocateConnectionNumber() -> Int {
        nextConnection += 1
        return nextConnection
    }
}

/// Conexão em memória. `actor` garante isolamento; o cancelamento é cooperativo via `Task`.
public actor InMemoryConnection: PhysicalConnection {
    public nonisolated let serverVersion = "in-memory 1.0"
    /// Número sequencial desta conexão nos eventos do log.
    public nonisolated let number: Int
    private let script: InMemoryDriver.Script
    private let log: InMemoryDriverLog
    private var inTransaction = false
    private var current: (sql: String, task: Task<StatementOutcome, any Error>)?
    private var closed = false

    init(number: Int, script: InMemoryDriver.Script, log: InMemoryDriverLog) {
        self.number = number
        self.script = script
        self.log = log
    }

    public func execute(_ statement: BoundStatement, limits: ReadLimits) async throws(DriverError) -> StatementOutcome {
        guard !closed else { throw .connection(RedactedMessage(alreadyRedacted: "Conexão fechada.")) }
        guard current == nil else { throw .busy }
        let sql = statement.sql
        if script.generated[sql] != nil || script.failures[sql] != nil {
            return try await StatementOutcome.collect(stream(statement, limits: limits, batchSize: limits.maxRows))
        }
        let delay = script.slow[sql] ?? script.delay
        let response = script.responses[sql] ?? .command("OK")
        let task = Task<StatementOutcome, any Error> {
            try await Task.sleep(for: delay)
            return response
        }
        current = (sql, task)
        defer { current = nil }
        do {
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            switch sql.uppercased() {
            case "BEGIN": inTransaction = true
            case "COMMIT", "ROLLBACK": inTransaction = false
            default: break
            }
            await log.record(.executed(sql))
            return Self.applyLimits(outcome, limits)
        } catch {
            await log.record(.cancelled(sql))
            throw .cancelled
        }
    }

    /// Aplica `maxRows` como faria um driver real (sem materializar além do limite).
    private static func applyLimits(_ outcome: StatementOutcome, _ limits: ReadLimits) -> StatementOutcome {
        guard case .rows(let columns, let batch, _, let rowCount) = outcome, rowCount > limits.maxRows else { return outcome }
        let trimmed = RowBatch(columns: batch.columns.map { Array($0.prefix(limits.maxRows)) })
        return .rows(columns: columns, firstBatch: trimmed, truncated: .maxRows(limits.maxRows), rowCount: limits.maxRows)
    }

    // MARK: Stream (NST-04-01)

    public nonisolated func stream(_ statement: BoundStatement, limits: ReadLimits, batchSize: Int) -> ResultStream {
        let (stream, continuation) = ResultStream.makeStream()
        let task = Task { await self.produce(statement, limits: limits, batchSize: batchSize, into: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func produce(_ statement: BoundStatement, limits: ReadLimits, batchSize: Int,
                         into continuation: ResultStream.Continuation) async {
        guard !closed else { return continuation.finish(throwing: DriverError.connection(RedactedMessage(alreadyRedacted: "Conexão fechada."))) }
        let sql = statement.sql
        if let failure = script.failures[sql] {
            await log.record(.executed(sql))
            return continuation.finish(throwing: failure)
        }
        do {
            try await Task.sleep(for: script.slow[sql] ?? script.delay)
        } catch {
            await log.record(.cancelled(sql))
            return continuation.finish(throwing: DriverError.cancelled)
        }
        if let generator = script.generated[sql] {
            continuation.yield(.columns(generator.columns))
            var accumulator = BatchAccumulator(columnCount: generator.columns.count, limits: limits, batchSize: batchSize)
            var row = 0
            while row < generator.rowCount {
                if Task.isCancelled {
                    await log.record(.cancelled(sql))
                    return continuation.finish(throwing: DriverError.cancelled)
                }
                let values = (0..<generator.columns.count).map { generator.cell(row, $0) }
                if accumulator.append(values) == .stop { break }
                if accumulator.readyBatch, let batch = accumulator.takeBatch() {
                    continuation.yield(.batch(batch))
                    await Task.yield()
                }
                row += 1
            }
            if let batch = accumulator.takeBatch() { continuation.yield(.batch(batch)) }
            continuation.yield(.end(accumulator.end))
            await log.record(.executed(sql))
            return continuation.finish()
        }
        switch script.responses[sql] ?? .command("OK") {
        case .rows(let columns, let batch, _, _):
            continuation.yield(.columns(columns))
            var accumulator = BatchAccumulator(columnCount: columns.count, limits: limits, batchSize: batchSize)
            for row in 0..<batch.rowCount {
                if accumulator.append(batch.columns.map { $0[row] }) == .stop { break }
                if accumulator.readyBatch, let ready = accumulator.takeBatch() { continuation.yield(.batch(ready)) }
            }
            if let ready = accumulator.takeBatch() { continuation.yield(.batch(ready)) }
            continuation.yield(.end(accumulator.end))
        case .affected(let count):
            continuation.yield(.end(.affected(count)))
        case .command(let tag):
            switch sql.uppercased() {
            case "BEGIN": inTransaction = true
            case "COMMIT", "ROLLBACK": inTransaction = false
            default: break
            }
            continuation.yield(.end(.command(tag)))
        }
        await log.record(.executed(sql))
        continuation.finish()
    }

    // MARK: Metadados (NST-04-01)

    public func databases() async throws(DriverError) -> [DatabaseInfo] { script.catalog.databases.map(DatabaseInfo.init) }

    public func schemas(in database: String) async throws(DriverError) -> [SchemaInfo] {
        (script.catalog.schemas[database] ?? []).map { SchemaInfo(ref: SchemaRef(database: database, name: $0)) }
    }

    public func entities(in schema: SchemaRef) async throws(DriverError) -> [EntityInfo] { script.catalog.entities[schema] ?? [] }

    public func columns(of entity: EntityRef) async throws(DriverError) -> [ColumnInfo] {
        guard let columns = script.catalog.columns[entity] else {
            throw .validation(RedactedMessage(alreadyRedacted: "Entidade inexistente."))
        }
        return columns
    }

    public func transactionState() async -> TransactionState { inTransaction ? .inTransaction : .idle }

    public func resetSession() async throws(DriverError) {
        if inTransaction {
            inTransaction = false
            await log.record(.rolledBack(number))
        }
        await log.record(.reset(number))
    }

    public nonisolated func cancelHandle() -> (any CancelHandle)? { InMemoryCancelHandle(connection: self) }

    func cancelCurrent() async {
        if let current {
            current.task.cancel()
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        current?.task.cancel()
        await log.record(.closed(number))
    }

    public var isClosed: Bool { closed }
}

struct InMemoryCancelHandle: CancelHandle {
    let connection: InMemoryConnection
    func cancel() async { await connection.cancelCurrent() }
}
