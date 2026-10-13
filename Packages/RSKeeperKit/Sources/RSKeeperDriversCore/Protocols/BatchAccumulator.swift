import RSKeeperDomain

/// Acumula linhas em lotes colunares e impõe `maxRows`/`maxBytes` durante a leitura (DR-08/09).
/// Todos os drivers usam o mesmo acumulador, para que o truncamento seja idêntico entre eles.
///
/// Uso: para cada linha lida, `append(row)`; quando devolver `.stop`, o driver **para de ler**,
/// fecha o cursor/portal e emite `finish()`.
public struct BatchAccumulator: Sendable {
    public enum Decision: Sendable, Equatable { case `continue`, stop }

    public let columnCount: Int
    public let limits: ReadLimits
    public let batchSize: Int
    public private(set) var rowCount = 0
    public private(set) var byteCount = 0
    public private(set) var truncated: TruncationReason?
    private var pending: [[CellValue]]

    public init(columnCount: Int, limits: ReadLimits, batchSize: Int) {
        precondition(batchSize > 0, "batchSize precisa ser positivo")
        self.columnCount = columnCount
        self.limits = limits
        self.batchSize = batchSize
        self.pending = Array(repeating: [], count: columnCount)
    }

    /// Lote pronto para emitir, se `pending` atingiu `batchSize`.
    public var readyBatch: Bool { (pending.first?.count ?? 0) >= batchSize }

    /// Registra uma linha. A linha `maxRows + 1` **não** é guardada: só prova que há mais e trunca.
    public mutating func append(_ row: [CellValue]) -> Decision {
        guard truncated == nil else { return .stop }
        if rowCount == limits.maxRows {
            truncated = .maxRows(limits.maxRows)
            return .stop
        }
        let bytes = row.reduce(0) { $0 + $1.estimatedByteCount }
        if byteCount + bytes > limits.maxBytes {
            truncated = .maxBytes(limits.maxBytes)
            return .stop
        }
        for index in 0..<columnCount { pending[index].append(index < row.count ? row[index] : .null) }
        rowCount += 1
        byteCount += bytes
        return .continue
    }

    /// Retira o lote pendente (vazio se não houver linhas).
    public mutating func takeBatch() -> RowBatch? {
        guard let first = pending.first, !first.isEmpty else { return nil }
        let batch = RowBatch(columns: pending)
        pending = Array(repeating: [], count: columnCount)
        return batch
    }

    public var end: ResultEnd { .rows(truncated: truncated, rowCount: rowCount) }
}
