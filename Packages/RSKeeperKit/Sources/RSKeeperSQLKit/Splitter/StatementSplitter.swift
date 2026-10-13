/// Uma instrução do script, com intervalos em unidades UTF-16 do texto original.
public struct SQLStatement: Sendable, Hashable {
    /// Posição na lista de instruções (0…).
    public let index: Int
    /// Do primeiro ao último token significativo (sem espaços, comentários iniciais nem o `;`).
    public let range: Range<Int>
    /// O `;` que termina a instrução, se houver.
    public let terminator: Range<Int>?
    /// Índices dos tokens (em `LexedSQL.tokens`) cobertos por `range`.
    public let tokenRange: Range<Int>
    /// Texto enviado ao driver.
    public let sql: String
    /// Contém literal, comentário ou identificador sem fechamento.
    public let hasUnterminatedToken: Bool

    /// Intervalo usado para "instrução atual": inclui o `;` e a posição logo depois dele.
    public var cursorRange: ClosedRange<Int> { range.lowerBound...(terminator?.upperBound ?? range.upperBound) }
}

/// Resultado da divisão: instruções e o texto tokenizado.
public struct SplitSQL: Sendable {
    public let lexed: LexedSQL
    public let statements: [SQLStatement]

    /// "Instrução atual" (NST-04-05, crit. 2): a que contém o cursor. Entre instruções → `nil`
    /// (a ação "Executar atual" fica indisponível).
    public func statement(atUTF16Offset offset: Int) -> SQLStatement? {
        // Busca binária: as instruções estão em ordem e não se sobrepõem.
        var low = 0, high = statements.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = statements[mid]
            if candidate.cursorRange.contains(offset) { return candidate }
            if offset < candidate.cursorRange.lowerBound { high = mid - 1 } else { low = mid + 1 }
        }
        return nil
    }

    /// Instruções que se sobrepõem a um intervalo (seleção).
    public func statements(overlapping range: Range<Int>) -> [SQLStatement] {
        statements.filter { $0.range.overlaps(range) || (range.isEmpty && $0.cursorRange.contains(range.lowerBound)) }
    }
}

/// Divisor de instruções por dialeto (NST-04-05; doc 04 §8).
///
/// - `;` dentro de literal, identificador citado, comentário ou `$tag$` não divide (pelo lexer).
/// - Corpos com `;` interno: `CREATE TRIGGER … BEGIN … END` (SQLite) e `BEGIN ATOMIC … END`
///   (PostgreSQL 14+), inclusive com `CASE … END` dentro do corpo.
/// - Instrução vazia (só `;`, espaços ou comentários) não é emitida.
public enum StatementSplitter {
    public static func split(_ sql: String, dialect: SQLDialect) -> SplitSQL {
        split(SQLLexer.tokenize(sql, dialect: dialect))
    }

    public static func split(_ lexed: LexedSQL) -> SplitSQL {
        var statements: [SQLStatement] = []
        var builder = Builder()

        for (i, token) in lexed.tokens.enumerated() {
            if token.kind.isTrivia { continue }
            if token.kind == .semicolon, builder.bodyDepth == 0 {
                if let statement = builder.finish(index: statements.count, terminator: token.range, lexed: lexed) {
                    statements.append(statement)
                }
                builder = Builder()
                continue
            }
            builder.add(tokenIndex: i, token: token, lexed: lexed)
        }
        if let statement = builder.finish(index: statements.count, terminator: nil, lexed: lexed) {
            statements.append(statement)
        }
        return SplitSQL(lexed: lexed, statements: statements)
    }

    /// Acumula uma instrução e acompanha os corpos com `;` interno.
    private struct Builder {
        var first: Int?
        var last: Int?
        var unterminated = false
        var bodyDepth = 0
        var headWords: [String] = []
        var previousKeyword: String?

        mutating func add(tokenIndex: Int, token: SQLToken, lexed: LexedSQL) {
            if first == nil { first = tokenIndex }
            last = tokenIndex
            if token.isUnterminated { unterminated = true }
            guard let word = lexed.keyword(token) else { previousKeyword = nil; return }
            if headWords.count < 4 { headWords.append(word) }

            switch word {
            case "BEGIN" where isSQLiteTrigger(lexed.dialect) && bodyDepth == 0:
                bodyDepth = 1
            case "ATOMIC" where lexed.dialect == .postgresql && previousKeyword == "BEGIN":
                bodyDepth += 1
            case "CASE" where bodyDepth > 0:
                bodyDepth += 1
            case "END" where bodyDepth > 0:
                bodyDepth -= 1
            default:
                break
            }
            previousKeyword = word
        }

        /// `CREATE [TEMP|TEMPORARY] TRIGGER` no SQLite.
        private func isSQLiteTrigger(_ dialect: SQLDialect) -> Bool {
            guard dialect == .sqlite, headWords.first == "CREATE" else { return false }
            return headWords.dropFirst().prefix(2).contains("TRIGGER")
        }

        func finish(index: Int, terminator: Range<Int>?, lexed: LexedSQL) -> SQLStatement? {
            guard let first, let last else { return nil }
            let range = lexed.tokens[first].range.lowerBound..<lexed.tokens[last].range.upperBound
            return SQLStatement(index: index, range: range, terminator: terminator, tokenRange: first..<(last + 1),
                                sql: lexed.text(range), hasUnterminatedToken: unterminated)
        }
    }
}
