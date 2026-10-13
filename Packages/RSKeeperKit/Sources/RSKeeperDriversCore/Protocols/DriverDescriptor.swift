import RSKeeperDomain

/// Modo de cancelamento (DR-29; docs/native/04 §2.1).
public enum CancelMode: String, Hashable, Sendable {
    /// Pedido ao servidor por outra conexão; sessão e transação continuam.
    case server
    /// Interrupção no próprio processo (`sqlite3_interrupt`); a conexão continua utilizável.
    case interrupt
    /// Destrói a conexão física e reabre. Único modo que descarta a transação.
    case killSession
    /// Sem cancelamento.
    case none

    /// Só `killSession` implica perder a transação (a UI avisa antes).
    public var discardsTransaction: Bool { self == .killSession }
}

public enum StreamingMode: String, Hashable, Sendable { case cursor, rowCallback, none }

public enum ReadOnlyEnforcement: String, Hashable, Sendable { case connectionOpen, perTransaction, sessionBestEffort }

public enum TimeoutMode: Hashable, Sendable {
    case server(String)
    case clientDeadlineOnly
}

/// Capacidades declaradas pelo driver; a UI e os casos de uso consultam isto (RF-DRV-04).
public struct DriverCapabilities: Hashable, Sendable {
    public var cancel: CancelMode
    public var transactions: Bool
    public var savepoints: Bool
    public var transactionalDDL: Bool
    public var schemas: Bool
    public var changeDatabaseInSession: Bool
    public var ilike: Bool
    public var returning: Bool
    public var streaming: StreamingMode
    public var readOnly: ReadOnlyEnforcement
    public var tls: Bool
    public var ssh: Bool
    public var statementTimeout: TimeoutMode
    public var materializedViews: Bool
    public var routines: Bool
    public var triggers: Bool
    public var partitions: Bool

    public init(cancel: CancelMode, transactions: Bool = true, savepoints: Bool = true, transactionalDDL: Bool = true,
                schemas: Bool = true, changeDatabaseInSession: Bool = false, ilike: Bool = false, returning: Bool = false,
                streaming: StreamingMode = .cursor, readOnly: ReadOnlyEnforcement = .perTransaction, tls: Bool = false,
                ssh: Bool = false, statementTimeout: TimeoutMode = .clientDeadlineOnly, materializedViews: Bool = false,
                routines: Bool = false, triggers: Bool = false, partitions: Bool = false) {
        self.cancel = cancel
        self.transactions = transactions
        self.savepoints = savepoints
        self.transactionalDDL = transactionalDDL
        self.schemas = schemas
        self.changeDatabaseInSession = changeDatabaseInSession
        self.ilike = ilike
        self.returning = returning
        self.streaming = streaming
        self.readOnly = readOnly
        self.tls = tls
        self.ssh = ssh
        self.statementTimeout = statementTimeout
        self.materializedViews = materializedViews
        self.routines = routines
        self.triggers = triggers
        self.partitions = partitions
    }
}

/// Descritor público de um driver (seletor de driver, RF-CONN-02).
public struct DriverDescriptor: Sendable {
    public let id: DriverID
    public let displayName: String
    public let targetKind: TargetKind
    public let capabilities: DriverCapabilities
    public let dialect: any Dialect

    public init(id: DriverID, displayName: String, targetKind: TargetKind, capabilities: DriverCapabilities,
                dialect: any Dialect) {
        self.id = id
        self.displayName = displayName
        self.targetKind = targetKind
        self.capabilities = capabilities
        self.dialect = dialect
    }

    /// O que o perfil precisa saber para validar invariantes (03 §2.1).
    public var requirements: DriverRequirements {
        DriverRequirements(targetKind: targetKind, supportsTLS: capabilities.tls, supportsSSH: capabilities.ssh)
    }
}
