/// Classificação de risco de uma instrução (docs/native/03 §4.3; porta DR-11).
public enum StatementRisk: String, Hashable, Sendable, Codable {
    case read, write, ddl, transactionControl, destructive, unknown
}

/// Situação de uma instrução dentro de um script (porta DR-13).
public enum StatementStatus: Hashable, Sendable {
    case ok
    case failed(RSKeeperError)
    case skipped
    case cancelled
}

/// Se a instrução foi efetivada no servidor.
public enum CommitState: String, Hashable, Sendable, Codable { case yes, no, unknown }

/// Desfecho terminal de uma execução. Nunca presume sucesso em caso de dúvida (DR-05/07).
public enum ExecutionOutcome: Hashable, Sendable {
    case succeeded
    case failed(RSKeeperError)
    case cancelled
    case outcomeUnknown(UnknownReason)
}

/// Estado de uma execução. Não existe estado de fila (porta DR-28): uma segunda execução na aba é `.busy`.
public enum ExecutionState: Hashable, Sendable {
    case running(statementIndex: Int)
    case cancelling
    case finished(ExecutionOutcome)

    public var isTerminal: Bool { if case .finished = self { true } else { false } }

    /// Transições válidas (03 §4.2). Estados terminais não mudam mais.
    public func canTransition(to next: ExecutionState) -> Bool {
        switch (self, next) {
        case (.finished, _):
            return false
        case (.running(let current), .running(let following)):
            return following > current
        case (.running, .cancelling), (.running, .finished):
            return true
        case (.cancelling, .finished):
            return true
        default:
            return false
        }
    }
}

/// Relatório por instrução (03 §4.2).
public struct StatementReport: Hashable, Sendable {
    public let index: Int
    public let risk: StatementRisk
    public let status: StatementStatus
    public let committed: CommitState
    public let affectedRows: Int?

    public init(index: Int, risk: StatementRisk, status: StatementStatus, committed: CommitState, affectedRows: Int? = nil) {
        self.index = index
        self.risk = risk
        self.status = status
        self.committed = committed
        self.affectedRows = affectedRows
    }

    /// Invariante 4.2-2: o script para na primeira falha; as instruções seguintes ficam `.skipped`.
    public static func stopAtFirstFailure(_ reports: [StatementReport]) -> Bool {
        var failed = false
        for report in reports {
            if failed {
                guard report.status == .skipped else { return false }
            } else if case .failed = report.status {
                failed = true
            }
        }
        return true
    }
}
