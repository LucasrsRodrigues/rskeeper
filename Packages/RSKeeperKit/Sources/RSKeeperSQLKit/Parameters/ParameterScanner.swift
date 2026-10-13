/// Estilo de placeholder do driver (doc 04 §7).
public enum SQLPlaceholderStyle: Sendable, Hashable {
    /// `?` (SQLite, MySQL): um por ocorrência; o mesmo nome repetido é ligado de novo.
    case questionMark
    /// `$1, $2…` (PostgreSQL): um número por nome; repetições reaproveitam o número.
    case dollarNumbered
}

public enum ParameterError: Error, Sendable, Hashable {
    /// `:nome` misturado com `?`/`$1` na mesma instrução.
    case mixedStyles
}

/// Instrução reescrita para o driver, com a ordem dos valores a ligar.
public struct RewrittenStatement: Sendable, Hashable {
    public let sql: String
    /// Nomes na ordem dos placeholders (com repetição em `.questionMark`; únicos em `.dollarNumbered`).
    public let bindOrder: [String]
}

/// Reconhece parâmetros `:nome` fora de literais e comentários, nunca em casts `::tipo` (pelo lexer),
/// e reescreve para o estilo do driver (RF-QRY-11; DR-16). Valores **sempre** por bind.
public enum ParameterScanner {
    /// Nomes distintos, na ordem da primeira ocorrência.
    public static func names(in statement: SQLStatement, lexed: LexedSQL) -> [String] {
        var seen: Set<String> = []
        return namedTokens(statement, lexed).compactMap { seen.insert($0.name).inserted ? $0.name : nil }
    }

    public static func rewrite(_ statement: SQLStatement, lexed: LexedSQL, style: SQLPlaceholderStyle)
        throws(ParameterError) -> RewrittenStatement {
        let named = namedTokens(statement, lexed)
        let positional = lexed.tokens[statement.tokenRange].contains { $0.kind == .parameter && !isNamed($0, lexed) }
        if !named.isEmpty, positional { throw .mixedStyles }
        guard !named.isEmpty else { return RewrittenStatement(sql: statement.sql, bindOrder: []) }

        var sql = ""
        var cursor = statement.range.lowerBound
        var order: [String] = []
        var numbers: [String: Int] = [:]
        for (token, name) in named {
            sql += lexed.text(cursor..<token.range.lowerBound)
            switch style {
            case .questionMark:
                sql += "?"
                order.append(name)
            case .dollarNumbered:
                let number = numbers[name] ?? { order.append(name); numbers[name] = order.count; return order.count }()
                sql += "$\(number)"
            }
            cursor = token.range.upperBound
        }
        sql += lexed.text(cursor..<statement.range.upperBound)
        return RewrittenStatement(sql: sql, bindOrder: order)
    }

    private static func isNamed(_ token: SQLToken, _ lexed: LexedSQL) -> Bool {
        token.range.count > 1 && lexed.units[token.range.lowerBound] == 0x3A      // ':'
    }

    private static func namedTokens(_ statement: SQLStatement, _ lexed: LexedSQL) -> [(token: SQLToken, name: String)] {
        lexed.tokens[statement.tokenRange].compactMap { token in
            guard token.kind == .parameter, isNamed(token, lexed) else { return nil }
            return (token, lexed.text((token.range.lowerBound + 1)..<token.range.upperBound))
        }
    }
}
