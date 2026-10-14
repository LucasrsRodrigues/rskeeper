/// Tipo de aba (NST-06-01: na onda 1, consulta e tabela).
public enum TabKind: Hashable, Sendable, Codable {
    case query
    case table(database: String?, schema: String?, name: String)
}
