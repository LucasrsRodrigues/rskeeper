/// Classificação de ambiente de uma conexão (EXT-01; alteração registrada de RF-CONN-16; docs/native/03 §18.1).
public enum EnvironmentKind: Hashable, Sendable, Codable {
    case local
    case development
    case testing
    case staging
    case production
    case custom(EnvironmentID)

    /// Sugestão inicial para um perfil novo (03 §18.1, invariante 3): SQLite ou `localhost` → `local`;
    /// remoto → `development`. Sempre visível e editável pelo usuário.
    public static func suggested(for target: ConnectionTarget) -> EnvironmentKind {
        switch target {
        case .file:
            return .local
        case .server(let host, _, _, _):
            let normalized = host.lowercased()
            return ["localhost", "127.0.0.1", "::1"].contains(normalized) ? .local : .development
        }
    }

    /// Migração do valor antigo `ProfileEnvironment` (Fase 4.2).
    /// Retorna o novo valor e se a classificação fica confirmada.
    public static func migrated(fromLegacy legacy: String) -> (kind: EnvironmentKind, confirmed: Bool) {
        switch legacy {
        case "development": return (.development, true)
        case "staging": return (.staging, true)
        case "production": return (.production, true)
        default: return (.development, false) // "unspecified" e desconhecidos: selo "classificar"
        }
    }
}
