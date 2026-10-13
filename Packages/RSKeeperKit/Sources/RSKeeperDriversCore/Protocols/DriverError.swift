import RSKeeperDomain

/// Falha de TLS.
public enum TLSFailure: String, Hashable, Sendable { case untrustedCertificate, hostnameMismatch, handshake, protocolVersion }

/// Capacidade ausente.
public enum Capability: String, Hashable, Sendable { case cancel, transactions, savepoints, schemas, streaming, tls, ssh, ilike, returning }

/// Fase em que o desfecho ficou desconhecido (DR-05/07).
public enum OutcomePhase: String, Hashable, Sendable { case execute, commit, rollback, applyChanges }

/// Erro normalizado de driver (docs/native/04 §2.5). Mensagens já redigidas; o SQL do usuário nunca entra.
public enum DriverError: Error, Hashable, Sendable {
    case connection(RedactedMessage)
    case authentication
    case tls(TLSFailure)
    case syntaxOrSemantic(RedactedMessage, position: Int?)
    case constraint(RedactedMessage)
    case readOnly
    case confirmationRequired
    case connectionLimit
    case busy
    case cancelled
    case timedOut
    case outcomeUnknown(phase: OutcomePhase)
    case unsupported(Capability)
    case validation(RedactedMessage)
    case driver(code: String, RedactedMessage)

    /// Mapeamento para o erro de aplicação (NST-01-01 crit. 2).
    public var applicationError: RSKeeperError {
        switch self {
        case .connection(let message): .connection(message)
        case .authentication: .auth(RedactedMessage(alreadyRedacted: "Credencial recusada."))
        case .tls(let failure): .connection(RedactedMessage(alreadyRedacted: "Falha de TLS: \(failure.rawValue)."))
        case .syntaxOrSemantic(let message, _): .driver(code: "syntax", message: message)
        case .constraint(let message): .driver(code: "constraint", message: message)
        case .readOnly: .readOnly
        case .confirmationRequired: .confirmationRequired
        case .connectionLimit: .conflict(.connectionLimit)
        case .busy: .conflict(.busy)
        case .cancelled: .cancelled
        case .timedOut: .timeout
        case .outcomeUnknown(let phase):
            .outcomeUnknown(phase == .commit || phase == .rollback ? .cancelledDuringCommit : .connectionLost)
        case .unsupported(let capability): .unsupported(RedactedMessage(alreadyRedacted: "Não suportado: \(capability.rawValue)."))
        case .validation(let message): .validation(message)
        case .driver(let code, let message): .driver(code: code, message: message)
        }
    }
}
