import RSKeeperDomain
import RSKeeperDriversCore

/// Driver em memória para testes (W0-T18). Não fala com nenhum banco.
///
/// Respostas fixas por SQL exato, atraso configurável e cancelamento cooperativo.
public struct InMemoryDriver: DriverFactory {
    public struct Script: Sendable {
        public var responses: [String: StatementOutcome]
        public var delay: Duration
        public var openDelay: Duration
        public var failOpen: DriverError?

        public init(responses: [String: StatementOutcome] = [:], delay: Duration = .zero,
                    openDelay: Duration = .zero, failOpen: DriverError? = nil) {
            self.responses = responses
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
        let delay = script.delay
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
