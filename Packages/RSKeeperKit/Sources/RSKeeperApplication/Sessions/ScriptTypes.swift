import RSKeeperDomain
import RSKeeperDriversCore

/// Instrução pronta para a sessão: SQL já separado e com parâmetros ligados, mais o risco classificado.
public struct PlannedStatement: Sendable {
    public let statement: BoundStatement
    public let risk: StatementRisk
    /// Intervalo UTF-16 no texto do editor (destaque da instrução em execução).
    public let sourceRange: Range<Int>

    public init(statement: BoundStatement, risk: StatementRisk, sourceRange: Range<Int>) {
        self.statement = statement
        self.risk = risk
        self.sourceRange = sourceRange
    }
}

/// Desfecho de um script (NST-07-02, crit. 5).
public struct ScriptOutcome: Sendable {
    public let reports: [StatementReport]
    /// Resultado de cada instrução executada (nil nas que falharam ou foram puladas).
    public let outcomes: [StatementOutcome?]
    /// Modo Auto: o script deixou uma transação aberta e ela foi desfeita na devolução (aviso na UI).
    public let autoRolledBackTransaction: Bool

    public var succeeded: Bool { reports.allSatisfy { $0.status == .ok } }
}
