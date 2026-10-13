import RSKeeperDomain

/// Modo de cancelamento (DR-29; docs/native/04 §2.1).
public enum CancelMode: String, Hashable, Sendable {
    /// Pedido ao servidor por outra conexão; sessão e transação continuam. O driver garante que o
    /// pedido atinja só a execução alvo (SPK-N03: guarda por marcador; nunca depender de `Task.cancel()`).
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

/// Completude da introspecção de metadados (Fase 4.2, EXT-04/05).
public enum IntrospectionLevel: String, Hashable, Sendable { case basic, full }

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
    /// Fase 4.2 (EXT-03/09/04-05): só a **declaração** entra na NST-04-01; as implementações vêm
    /// nas NST-17-01, 22-01 e 18-01.
    public var explain: Bool
    public var explainAnalyze: Bool
    public var health: Bool
    public var introspection: IntrospectionLevel

    public init(cancel: CancelMode, transactions: Bool = true, savepoints: Bool = true, transactionalDDL: Bool = true,
                schemas: Bool = true, changeDatabaseInSession: Bool = false, ilike: Bool = false, returning: Bool = false,
                streaming: StreamingMode = .cursor, readOnly: ReadOnlyEnforcement = .perTransaction, tls: Bool = false,
                ssh: Bool = false, statementTimeout: TimeoutMode = .clientDeadlineOnly, materializedViews: Bool = false,
                routines: Bool = false, triggers: Bool = false, partitions: Bool = false,
                explain: Bool = false, explainAnalyze: Bool = false, health: Bool = false,
                introspection: IntrospectionLevel = .basic) {
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
        self.explain = explain
        self.explainAnalyze = explainAnalyze
        self.health = health
        self.introspection = introspection
    }

    /// Coerência da declaração (NT-DRV, NST-04-01 Fase 4.2): `explainAnalyze` exige `explain`;
    /// `.interrupt` só para drivers de arquivo; `.killSession` descarta a transação.
    public func inconsistencies(for targetKind: TargetKind) -> [String] {
        var problems: [String] = []
        if explainAnalyze && !explain { problems.append("explainAnalyze sem explain") }
        if savepoints && !transactions { problems.append("savepoints sem transactions") }
        if cancel == .interrupt && targetKind != .file { problems.append("cancel .interrupt em driver de servidor") }
        if ssh && targetKind == .file { problems.append("ssh em driver de arquivo") }
        return problems
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
