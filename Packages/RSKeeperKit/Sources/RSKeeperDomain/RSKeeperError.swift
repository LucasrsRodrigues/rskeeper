/// Mensagem que **já passou** pela redação de segredos (docs/native/06; NST-01-01 crit. 2).
///
/// O domínio não sabe redigir (isso é do `Redactor`, em RSKeeperSecurity); este tipo só marca,
/// no sistema de tipos, que o texto pode ser exibido e registrado.
public struct RedactedMessage: Hashable, Sendable, CustomStringConvertible {
    public let text: String

    /// Cria a mensagem a partir de um texto que o chamador garante estar redigido.
    public init(alreadyRedacted text: String) { self.text = text }

    public var description: String { text }
}

/// Motivo de um conflito (porta DR-06/19/20/27).
public enum ConflictReason: String, Hashable, Sendable, Codable {
    case busy                 // já há execução ativa na aba
    case connectionLimit      // orçamento de conexões esgotado
    case staleRevision        // controle otimista (expectedRevision)
    case previewStale         // digest do preview mudou
    case duplicateID
    case transactionActive
    case rateLimit
}

/// Motivo de um recurso não encontrado (porta DR-10).
public enum NotFoundReason: String, Hashable, Sendable, Codable {
    case unknown
    case expired
    case evicted
    case otherWindow          // escopo por janela: sempre parece inexistente
}

/// Motivo de um desfecho desconhecido (porta DR-05/07).
public enum UnknownReason: String, Hashable, Sendable, Codable {
    case connectionLost
    case timeoutAfterSend
    case cancelledDuringCommit
    case appTerminated
}

/// Erro tipado entre as camadas de aplicação, drivers e persistência (NST-01-01).
///
/// Todos os textos carregados são `RedactedMessage`; `description` nunca expõe dados crus.
public enum RSKeeperError: Error, Hashable, Sendable, CustomStringConvertible {
    case validation(RedactedMessage)
    case notFound(NotFoundReason)
    case timeout
    case cancelled
    case connection(RedactedMessage)
    case auth(RedactedMessage)
    case driver(code: String, message: RedactedMessage)
    case permission(RedactedMessage)
    case readOnly
    case confirmationRequired
    case conflict(ConflictReason)
    case unsupported(RedactedMessage)
    case outcomeUnknown(UnknownReason)
    case `internal`(RedactedMessage)

    /// Indica se uma **leitura idempotente** pode ser repetida uma vez (docs/native/03 §12.3).
    /// Escritas nunca são repetidas automaticamente: a decisão fica no caso de uso (NST-01-01 crit. 4).
    public var isTransientForIdempotentRead: Bool {
        switch self {
        case .connection, .timeout: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .validation(let message): "validation: \(message)"
        case .notFound(let reason): "notFound(\(reason.rawValue))"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .connection(let message): "connection: \(message)"
        case .auth(let message): "auth: \(message)"
        case .driver(let code, let message): "driver[\(code)]: \(message)"
        case .permission(let message): "permission: \(message)"
        case .readOnly: "readOnly"
        case .confirmationRequired: "confirmationRequired"
        case .conflict(let reason): "conflict(\(reason.rawValue))"
        case .unsupported(let message): "unsupported: \(message)"
        case .outcomeUnknown(let reason): "outcomeUnknown(\(reason.rawValue))"
        case .internal(let message): "internal: \(message)"
        }
    }
}
