import RSKeeperDomain

/// Valor de segredo em memória, entregue ao driver só no momento de conectar (docs/native/06).
/// `description` nunca revela o conteúdo.
public struct SecretValue: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let storage: String
    public init(_ value: String) { storage = value }
    /// Acesso explícito, só para o driver montar a conexão.
    public func reveal() -> String { storage }
    public var description: String { "<secret>" }
    public var debugDescription: String { "<secret>" }
}

/// Alvo resolvido para abrir a conexão: caminho/bookmark já acessado e segredos lidos do Keychain.
public enum ResolvedTarget: Sendable {
    case file(path: String, readOnly: Bool)
    case server(host: String, port: UInt16, user: String?, password: SecretValue?, database: String?)
}

/// Opções de abertura.
public struct OpenOptions: Sendable {
    public var readOnly: Bool
    public var connectTimeoutSeconds: Int
    public var tls: TLSOptions?

    public init(readOnly: Bool = false, connectTimeoutSeconds: Int = 15, tls: TLSOptions? = nil) {
        self.readOnly = readOnly
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.tls = tls
    }
}

/// Valor ligado por bind (DR-16: bind obrigatório).
public enum BindValue: Hashable, Sendable {
    case null, bool(Bool), int(Int64), double(Double), text(String), bytes([UInt8]), decimalText(String)
}

/// Instrução única já separada pelo SQLKit, com parâmetros ligados por bind.
public struct BoundStatement: Sendable {
    public let sql: String
    public let bindings: [BindValue]
    /// Execução de origem. Drivers com cancelamento `.server` guardado usam isto para marcar a
    /// instrução e cancelar só ela (revisão de contrato v1, SPK-N03: `pg_cancel_backend` guardado
    /// por `/*rsk:exec=<id>*/`). `nil` em instruções internas (metadados, sondas).
    public let executionID: ExecutionID?
    public init(sql: String, bindings: [BindValue] = [], executionID: ExecutionID? = nil) {
        self.sql = sql
        self.bindings = bindings
        self.executionID = executionID
    }
}

/// Limites impostos **durante** a leitura (DR-08, AR-MEM-01).
public struct ReadLimits: Hashable, Sendable {
    public let maxRows: Int
    public let maxBytes: Int
    public let maxCellBytes: Int
    public let deadline: ContinuousClock.Instant?

    /// Padrões [META]: 50.000 linhas [CONFIRMADO maxResults], 256 MiB, 64 KiB por célula.
    public static let `default` = ReadLimits(maxRows: 50_000, maxBytes: 256 * 1024 * 1024, maxCellBytes: CellValueLimits.inlineTextMax)

    public init(maxRows: Int, maxBytes: Int, maxCellBytes: Int, deadline: ContinuousClock.Instant? = nil) {
        precondition(maxRows > 0 && maxBytes > 0 && maxCellBytes > 0, "limites devem ser positivos")
        self.maxRows = maxRows
        self.maxBytes = maxBytes
        self.maxCellBytes = maxCellBytes
        self.deadline = deadline
    }
}

/// Tipo portável de coluna.
public enum PortableType: String, Hashable, Sendable {
    case bool, int, bigint, decimal, double, text, bytes, date, time, timestamp, timestampTZ, json, uuid, array, interval, unknown
}

/// Coluna de um resultado.
public struct ResultColumn: Hashable, Sendable {
    public let name: String
    public let nativeTypeName: String
    public let portableType: PortableType
    public init(name: String, nativeTypeName: String, portableType: PortableType) {
        self.name = name
        self.nativeTypeName = nativeTypeName
        self.portableType = portableType
    }
}

/// Lote **colunar** de linhas (`columns[col][row]`), limitado em bytes (DR-09).
public struct RowBatch: Hashable, Sendable {
    public let columns: [[CellValue]]
    public var rowCount: Int { columns.first?.count ?? 0 }

    public init(columns: [[CellValue]]) {
        precondition(Set(columns.map(\.count)).count <= 1, "todas as colunas do lote precisam ter o mesmo número de linhas")
        self.columns = columns
    }

    /// Constrói a partir de linhas (conveniência para drivers que leem linha a linha).
    public init(rows: [[CellValue]], columnCount: Int) {
        var columns = Array(repeating: [CellValue](), count: columnCount)
        for row in rows {
            for index in 0..<columnCount { columns[index].append(index < row.count ? row[index] : .null) }
        }
        self.init(columns: columns)
    }
}

/// Motivo de truncamento de um resultado.
public enum TruncationReason: Hashable, Sendable {
    case maxRows(Int)
    case maxBytes(Int)
    case processBudget
}

/// Desfecho de uma instrução.
public enum StatementOutcome: Sendable {
    case rows(columns: [ResultColumn], firstBatch: RowBatch, truncated: TruncationReason?, rowCount: Int)
    case affected(Int)
    case command(String)
}

/// Estado transacional da conexão física (DR-17).
public enum TransactionState: String, Hashable, Sendable { case idle, inTransaction, failed }

/// Alça de cancelamento de uma execução em curso (DR-18/29).
///
/// SPK-N05: no SQLite, o cancelamento da `Task` já chega a `sqlite3_interrupt` pelo GRDB; o handle
/// serve a prazos e a "cancelar tudo". Depois de `.cancelled`, o chamador consulta `transactionState()`.
public protocol CancelHandle: Sendable {
    func cancel() async
}

/// Conexão física com o banco.
///
/// Decisão W0-D07: a conexão é uma referência `Sendable` (actor ou classe isolada); a **posse exclusiva**
/// é expressa pelo `ConnectionLease` não copiável (docs/native/03 §11), não pelo protocolo.
public protocol PhysicalConnection: AnyObject, Sendable {
    var serverVersion: String { get }
    func execute(_ statement: BoundStatement, limits: ReadLimits) async throws(DriverError) -> StatementOutcome
    func transactionState() async -> TransactionState
    func resetSession() async throws(DriverError)
    func cancelHandle() -> (any CancelHandle)?
    func close() async
}

/// Fábrica de conexões de um driver (docs/native/04 §2.2).
public protocol DriverFactory: Sendable {
    var descriptor: DriverDescriptor { get }
    func validate(_ target: ConnectionTarget) throws(DriverError)
    func open(_ target: ResolvedTarget, options: OpenOptions) async throws(DriverError) -> any PhysicalConnection
}
