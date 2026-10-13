import Foundation
import RSKeeperDomain

/// Operação sujeita a confirmação (03 §4.3).
public enum OperationKind: String, Sendable, Hashable { case execute, applyDDL, importTruncate }

/// Contexto da política, fixado na abertura da sessão a partir do perfil.
public struct OperationPolicyContext: Sendable, Hashable {
    public let environment: EnvironmentKind
    public let readOnly: Bool
    /// Nome que o usuário digita para confirmar em produção (nome do perfil).
    public let targetName: String

    public init(environment: EnvironmentKind, readOnly: Bool, targetName: String) {
        self.environment = environment
        self.readOnly = readOnly
        self.targetName = targetName
    }
}

/// O que a confirmação precisa mostrar e exigir.
public struct ConfirmationRequirement: Sendable, Hashable {
    /// Índices (no plano) das instruções que motivam a confirmação, com o risco de cada uma.
    public let statements: [Int]
    public let risks: [StatementRisk]
    /// Em produção, `destructive` e `unknown` exigem digitar o nome do alvo (DR-11).
    public let mustTypeTargetName: String?
}

public enum PolicyDecision: Sendable, Hashable {
    case allow
    case confirm(ConfirmationRequirement)
    case deny(RSKeeperError)
}

/// Motor de políticas central (NST-07-04 ampliada; ADR-N26; tabela DR-11 de docs/native/06 §9.1).
///
/// Independente da UI: o editor, a edição de dados, DDL e importação consultam o mesmo motor, e a
/// sessão o reaplica antes de executar. A classificação estática **não** é garantia: `unknown`
/// sempre exige confirmação; em somente leitura, tudo que não for `read` é recusado.
/// Políticas fixas por `EnvironmentKind` no MVP; só `production` é mais restritiva.
public struct OperationPolicyEngine: Sendable {
    public init() {}

    public func evaluate(_ risks: [StatementRisk], context: OperationPolicyContext) -> PolicyDecision {
        if context.readOnly, risks.contains(where: { $0 != .read }) { return .deny(.readOnly) }
        let production = context.environment == .production
        var flagged: [Int] = []
        var typing = false
        for (index, risk) in risks.enumerated() {
            switch risk {
            case .read, .transactionControl:
                continue
            case .write, .ddl:
                if production { flagged.append(index) }
            case .destructive, .unknown:
                flagged.append(index)
                if production { typing = true }
            }
        }
        guard !flagged.isEmpty else { return .allow }
        return .confirm(ConfirmationRequirement(statements: flagged, risks: flagged.map { risks[$0] },
                                                mustTypeTargetName: typing ? context.targetName : nil))
    }
}

/// Token de confirmação de uso único (DR-14): emitido e consumido pela sessão.
public struct ConfirmationToken: Sendable, Hashable {
    public let nonce: UUID
    init() { nonce = UUID() }
}
