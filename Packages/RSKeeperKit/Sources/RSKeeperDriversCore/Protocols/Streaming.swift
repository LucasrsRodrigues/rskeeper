import RSKeeperDomain

/// Evento do stream de resultado (NST-04-01; doc 04 §2.3).
///
/// Ordem garantida para resultados com linhas: `.columns`, zero ou mais `.batch`, `.end(.rows)`.
/// Instruções sem linhas emitem só `.end(.affected)` ou `.end(.command)`.
public enum ResultEvent: Sendable {
    case columns([ResultColumn])
    /// Lote colunar com no máximo `batchSize` linhas.
    case batch(RowBatch)
    case end(ResultEnd)
}

public enum ResultEnd: Hashable, Sendable {
    /// Leitura encerrada; `truncated` ≠ nil se parou em `maxRows` ou `maxBytes` (invariante 1).
    case rows(truncated: TruncationReason?, rowCount: Int)
    case affected(Int)
    case command(String)
}

/// Stream de resultado. Erros são sempre `DriverError` (use `DriverError.normalized`).
/// Cancelar a `Task` consumidora encerra o stream e aciona o cancelamento do driver (invariante 4).
public typealias ResultStream = AsyncThrowingStream<ResultEvent, any Error>

extension DriverError {
    /// Converte qualquer erro do stream para o erro normalizado (doc 04 §2.5).
    public static func normalized(_ error: any Error) -> DriverError {
        switch error {
        case let error as DriverError: error
        case is CancellationError: .cancelled
        default: .driver(code: "unknown", RedactedMessage(alreadyRedacted: "Erro inesperado do driver."))
        }
    }
}

extension PhysicalConnection {
    /// Implementação padrão de `execute`: consome o stream e junta os lotes num só.
    /// Os limites continuam valendo, porque quem para a leitura é o driver.
    public func execute(_ statement: BoundStatement, limits: ReadLimits) async throws(DriverError) -> StatementOutcome {
        try await StatementOutcome.collect(stream(statement, limits: limits, batchSize: limits.maxRows))
    }
}

extension StatementOutcome {
    /// Consome um stream inteiro e devolve o desfecho com um único lote.
    public static func collect(_ stream: ResultStream) async throws(DriverError) -> StatementOutcome {
        var columns: [ResultColumn] = []
        var collected: [[CellValue]] = []
        do {
            for try await event in stream {
                switch event {
                case .columns(let resultColumns):
                    columns = resultColumns
                    collected = Array(repeating: [], count: resultColumns.count)
                case .batch(let batch):
                    for index in batch.columns.indices where index < collected.count {
                        collected[index].append(contentsOf: batch.columns[index])
                    }
                case .end(.rows(let truncated, let rowCount)):
                    return .rows(columns: columns, firstBatch: RowBatch(columns: collected), truncated: truncated, rowCount: rowCount)
                case .end(.affected(let count)):
                    return .affected(count)
                case .end(.command(let tag)):
                    return .command(tag)
                }
            }
        } catch {
            throw DriverError.normalized(error)
        }
        // Cancelar a Task consumidora encerra a iteração sem erro: isso é cancelamento, não falha do driver.
        if Task.isCancelled { throw .cancelled }
        throw .driver(code: "stream-ended", RedactedMessage(alreadyRedacted: "O stream terminou sem evento final."))
    }
}

/// Contagem aproximada de bytes para `ReadLimits.maxBytes` (DR-08/09). Conta o conteúdo, não o
/// overhead de `enum`; serve para comparar com o orçamento, não para medir memória exata.
extension CellValue {
    public var estimatedByteCount: Int {
        switch self {
        case .null: 1
        case .bool: 1
        case .int, .double: 8
        case .uuid: 16
        case .decimal(let text), .text(let text), .date(let text), .time(let text), .json(let text): text.utf8.count
        case .timestamp(let text, let zone): text.utf8.count + (zone?.utf8.count ?? 0)
        case .bytes(let preview, _): preview.count
        case .truncated(let prefix, _): prefix.utf8.count
        case .unsupported(let name): name.utf8.count
        case .array(let values): values.reduce(0) { $0 + $1.estimatedByteCount }
        }
    }
}

extension CellValue {
    /// Texto limitado a `limit` bytes UTF-8, sem cortar um caractere ao meio; acima disso, `.truncated`.
    public static func text(_ string: String, limit: Int) -> CellValue {
        let size = string.utf8.count
        guard size > limit else { return .text(string) }
        var prefix = ""
        var used = 0
        for character in string {
            let length = character.utf8.count
            if used + length > limit { break }
            prefix.append(character)
            used += length
        }
        return .truncated(prefix: prefix, totalSize: size)
    }
}

extension RowBatch {
    public var estimatedByteCount: Int { columns.reduce(0) { $0 + $1.reduce(0) { $0 + $1.estimatedByteCount } } }
}
