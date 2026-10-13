import RSKeeperDomain

/// Política de repetição (ADR-N19; porta DR-05/06; NT-UNIT-10).
///
/// - Leituras idempotentes: no máximo **1** repetição, só em erro transitório de conexão/prazo.
/// - Escritas (execução com risco ≠ read, applyChanges, DDL, commit): **nunca** repetem.
///   Falha depois do envio vira `.outcomeUnknown`. Não há exactly-once.
public enum RetryPolicy {
    public enum Operation: Hashable, Sendable {
        case connect
        case metadataRead
        case pageRead
        case execute(risk: StatementRisk)
        case applyChanges
        case ddl
        case commit
        case rollback
    }

    public enum Decision: Hashable, Sendable {
        case retryOnce
        case fail(RSKeeperError)
        case outcomeUnknown(UnknownReason)
    }

    /// Indica se a operação é uma leitura idempotente.
    public static func isIdempotentRead(_ operation: Operation) -> Bool {
        switch operation {
        case .metadataRead, .pageRead, .connect: true
        case .execute(let risk): risk == .read
        case .applyChanges, .ddl, .commit, .rollback: false
        }
    }

    /// Decide o que fazer após uma falha.
    /// - Parameters:
    ///   - attempts: tentativas já feitas (1 = a primeira falhou).
    ///   - sentToServer: se a instrução pode ter chegado ao servidor antes da falha.
    public static func decide(_ operation: Operation, error: RSKeeperError, attempts: Int, sentToServer: Bool) -> Decision {
        if isIdempotentRead(operation) {
            if error.isTransientForIdempotentRead, attempts < 2 { return .retryOnce }
            return .fail(error)
        }
        // Escrita: nunca repete. Perda de conexão/prazo depois do envio → desfecho desconhecido.
        if sentToServer {
            switch error {
            case .connection: return .outcomeUnknown(.connectionLost)
            case .timeout: return .outcomeUnknown(.timeoutAfterSend)
            case .cancelled where operation == .commit: return .outcomeUnknown(.cancelledDuringCommit)
            case .outcomeUnknown(let reason): return .outcomeUnknown(reason)
            default: break
            }
        }
        return .fail(error)
    }
}
