/// Dialeto léxico. Só o que muda a **tokenização** fica aqui; regras de execução ficam nos drivers.
public enum SQLDialect: String, Sendable, Hashable, CaseIterable {
    case sqlite
    case postgresql

    /// `/* /* */ */` aninha no PostgreSQL; no SQLite o primeiro `*/` fecha.
    var nestsBlockComments: Bool { self == .postgresql }
    /// `$tag$ … $tag$` e `$1`.
    var supportsDollarQuoting: Bool { self == .postgresql }
    /// `` `x` `` e `[x]` são identificadores no SQLite; `[` é subscrito no PostgreSQL.
    var supportsBacktickAndBracketIdentifiers: Bool { self == .sqlite }
    /// `?`, `?NNN` e `@nome` são parâmetros no SQLite; `?` é operador (jsonb) no PostgreSQL.
    var supportsQuestionAndAtParameters: Bool { self == .sqlite }
}

public enum SQLTokenKind: Sendable, Hashable {
    case whitespace
    case lineComment
    case blockComment
    /// Literal de texto (`'…'`, `E'…'`), inclusive o prefixo.
    case string
    /// Texto entre `$tag$`.
    case dollarString
    /// `"x"`, `` `x` ``, `[x]`.
    case quotedIdentifier
    case number
    /// Palavra-chave ou identificador sem aspas.
    case word
    /// `:nome`, `$1`, `?`, `?1`, `@nome`.
    case parameter
    case openParen
    case closeParen
    case semicolon
    /// Operadores e demais pontuações (inclusive `::`).
    case punctuation

    /// Espaços e comentários: não afetam o significado.
    public var isTrivia: Bool { self == .whitespace || self == .lineComment || self == .blockComment }
}

/// Token com intervalo em **unidades UTF-16** (compatível com `NSRange` do editor).
public struct SQLToken: Sendable, Hashable {
    public let kind: SQLTokenKind
    public let range: Range<Int>
    /// Literal, comentário ou identificador sem fechamento até o fim do texto.
    public let isUnterminated: Bool
}

/// Resultado do lexer: o texto em UTF-16 e os tokens que o **particionam** (sem lacunas).
public struct LexedSQL: Sendable {
    public let dialect: SQLDialect
    public let units: [UInt16]
    public let tokens: [SQLToken]

    /// Texto de um intervalo UTF-16.
    public func text(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    public func text(of token: SQLToken) -> String { text(token.range) }

    /// Palavra em maiúsculas ASCII (para comparar com palavras-chave), ou `nil` se não for `word`.
    public func keyword(_ token: SQLToken) -> String? {
        guard token.kind == .word else { return nil }
        var scalars = String.UnicodeScalarView()
        for unit in units[token.range] {
            let upper = (unit >= 0x61 && unit <= 0x7A) ? unit - 0x20 : unit
            guard let scalar = Unicode.Scalar(upper) else { return text(of: token).uppercased() }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

/// Lexer SQL por dialeto (NST-04-05; ADR-N17). Puro, sem I/O, O(n).
public enum SQLLexer {
    public static func tokenize(_ sql: String, dialect: SQLDialect) -> LexedSQL {
        let units = Array(sql.utf16)
        var tokens: [SQLToken] = []
        tokens.reserveCapacity(units.count / 3)
        var scanner = Scanner(units: units, dialect: dialect)
        while let token = scanner.next() { tokens.append(token) }
        return LexedSQL(dialect: dialect, units: units, tokens: tokens)
    }
}

// MARK: - Implementação

private enum Unit {
    static let space: UInt16 = 0x20, tab: UInt16 = 0x09, newline: UInt16 = 0x0A, carriageReturn: UInt16 = 0x0D
    static let formFeed: UInt16 = 0x0C, verticalTab: UInt16 = 0x0B
    static let dash: UInt16 = 0x2D, slash: UInt16 = 0x2F, star: UInt16 = 0x2A
    static let quote: UInt16 = 0x27, doubleQuote: UInt16 = 0x22, backtick: UInt16 = 0x60, backslash: UInt16 = 0x5C
    static let openBracket: UInt16 = 0x5B, closeBracket: UInt16 = 0x5D
    static let dollar: UInt16 = 0x24, colon: UInt16 = 0x3A, question: UInt16 = 0x3F, at: UInt16 = 0x40
    static let semicolon: UInt16 = 0x3B, openParen: UInt16 = 0x28, closeParen: UInt16 = 0x29
    static let dot: UInt16 = 0x2E, underscore: UInt16 = 0x5F

    static func isWhitespace(_ u: UInt16) -> Bool {
        u == space || u == tab || u == newline || u == carriageReturn || u == formFeed || u == verticalTab
    }
    static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
    static func isASCIILetter(_ u: UInt16) -> Bool { (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) }
    /// Início de identificador: letra, `_` ou qualquer não ASCII (identificadores Unicode).
    static func isWordStart(_ u: UInt16) -> Bool { isASCIILetter(u) || u == underscore || u >= 0x80 }
    static func isWordPart(_ u: UInt16) -> Bool { isWordStart(u) || isDigit(u) || u == dollar }
}

private struct Scanner {
    let units: [UInt16]
    let dialect: SQLDialect
    var index = 0

    init(units: [UInt16], dialect: SQLDialect) {
        self.units = units
        self.dialect = dialect
    }

    private func peek(_ offset: Int = 0) -> UInt16? {
        let i = index + offset
        return i < units.count ? units[i] : nil
    }

    mutating func next() -> SQLToken? {
        guard index < units.count else { return nil }
        let start = index
        let u = units[index]
        var unterminated = false
        let kind: SQLTokenKind

        if Unit.isWhitespace(u) {
            while let c = peek(), Unit.isWhitespace(c) { index += 1 }
            kind = .whitespace
        } else if u == Unit.dash, peek(1) == Unit.dash {
            while let c = peek(), c != Unit.newline { index += 1 }
            kind = .lineComment
        } else if u == Unit.slash, peek(1) == Unit.star {
            unterminated = !scanBlockComment()
            kind = .blockComment
        } else if u == Unit.quote {
            unterminated = !scanQuoted(close: Unit.quote, backslashEscapes: false)
            kind = .string
        } else if u == Unit.doubleQuote {
            unterminated = !scanQuoted(close: Unit.doubleQuote, backslashEscapes: false)
            kind = .quotedIdentifier
        } else if dialect.supportsBacktickAndBracketIdentifiers, u == Unit.backtick {
            unterminated = !scanQuoted(close: Unit.backtick, backslashEscapes: false)
            kind = .quotedIdentifier
        } else if dialect.supportsBacktickAndBracketIdentifiers, u == Unit.openBracket {
            unterminated = !scanBracketIdentifier()
            kind = .quotedIdentifier
        } else if dialect.supportsDollarQuoting, u == Unit.dollar {
            if let digit = peek(1), Unit.isDigit(digit) {
                index += 1
                while let c = peek(), Unit.isDigit(c) { index += 1 }
                kind = .parameter
            } else if let tagEnd = dollarTagEnd() {
                unterminated = !scanDollarString(tag: Array(units[start..<tagEnd]))
                kind = .dollarString
            } else {
                index += 1
                kind = .punctuation
            }
        } else if u == Unit.colon {
            if peek(1) == Unit.colon {
                index += 2
                kind = .punctuation                       // cast `::tipo`
            } else if let c = peek(1), Unit.isWordStart(c) {
                index += 1
                while let c = peek(), Unit.isWordPart(c), c != Unit.dollar { index += 1 }
                kind = .parameter                         // `:nome`
            } else {
                index += 1
                kind = .punctuation
            }
        } else if dialect.supportsQuestionAndAtParameters, u == Unit.question {
            index += 1
            while let c = peek(), Unit.isDigit(c) { index += 1 }
            kind = .parameter
        } else if dialect.supportsQuestionAndAtParameters, u == Unit.at, let c = peek(1), Unit.isWordStart(c) {
            index += 1
            while let c = peek(), Unit.isWordPart(c) { index += 1 }
            kind = .parameter
        } else if Unit.isDigit(u) || (u == Unit.dot && peek(1).map(Unit.isDigit) == true) {
            scanNumber()
            kind = .number
        } else if Unit.isWordStart(u) {
            // Prefixo E'…' (PostgreSQL): texto com escapes por barra invertida.
            if dialect == .postgresql, u == 0x45 || u == 0x65, peek(1) == Unit.quote {
                index += 1
                unterminated = !scanQuoted(close: Unit.quote, backslashEscapes: true)
                kind = .string
            } else {
                while let c = peek(), Unit.isWordPart(c) { index += 1 }
                kind = .word
            }
        } else if u == Unit.semicolon {
            index += 1
            kind = .semicolon
        } else if u == Unit.openParen {
            index += 1
            kind = .openParen
        } else if u == Unit.closeParen {
            index += 1
            kind = .closeParen
        } else {
            // Par substituto (emoji etc.) vira um token só, para nunca cortar um caractere ao meio.
            index += (u >= 0xD800 && u <= 0xDBFF && index + 1 < units.count) ? 2 : 1
            kind = .punctuation
        }
        return SQLToken(kind: kind, range: start..<index, isUnterminated: unterminated)
    }

    /// `/* … */`, aninhado se o dialeto permitir. Devolve `false` se não fechar.
    private mutating func scanBlockComment() -> Bool {
        index += 2
        var depth = 1
        while index < units.count {
            if units[index] == Unit.star, peek(1) == Unit.slash {
                index += 2
                depth -= 1
                if depth == 0 { return true }
            } else if dialect.nestsBlockComments, units[index] == Unit.slash, peek(1) == Unit.star {
                index += 2
                depth += 1
            } else {
                index += 1
            }
        }
        return false
    }

    /// Literal com aspas dobradas como escape (`''`, `""`); opcionalmente `\x`.
    private mutating func scanQuoted(close: UInt16, backslashEscapes: Bool) -> Bool {
        index += 1
        while index < units.count {
            let c = units[index]
            if backslashEscapes, c == Unit.backslash {
                index = min(index + 2, units.count)
            } else if c == close {
                if peek(1) == close { index += 2 } else { index += 1; return true }
            } else {
                index += 1
            }
        }
        return false
    }

    private mutating func scanBracketIdentifier() -> Bool {
        index += 1
        while index < units.count {
            if units[index] == Unit.closeBracket { index += 1; return true }
            index += 1
        }
        return false
    }

    /// Fim (exclusivo) de uma tag `$$` ou `$nome$` a partir de `index`, sem consumir.
    private func dollarTagEnd() -> Int? {
        var i = index + 1
        if i < units.count, units[i] == Unit.dollar { return i + 1 }
        guard i < units.count, Unit.isASCIILetter(units[i]) || units[i] == Unit.underscore else { return nil }
        while i < units.count, Unit.isASCIILetter(units[i]) || Unit.isDigit(units[i]) || units[i] == Unit.underscore { i += 1 }
        return (i < units.count && units[i] == Unit.dollar) ? i + 1 : nil
    }

    private mutating func scanDollarString(tag: [UInt16]) -> Bool {
        index += tag.count
        while index < units.count {
            if units[index] == Unit.dollar, index + tag.count <= units.count,
               units[index..<(index + tag.count)].elementsEqual(tag) {
                index += tag.count
                return true
            }
            index += 1
        }
        return false
    }

    private mutating func scanNumber() {
        if units[index] == 0x30, let x = peek(1), x == 0x78 || x == 0x58 {           // 0x…
            index += 2
            while let c = peek(), Unit.isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) { index += 1 }
            return
        }
        while let c = peek(), Unit.isDigit(c) || c == Unit.underscore { index += 1 }
        if peek() == Unit.dot, peek(1) != Unit.dot {                                 // `1..2` não é decimal
            index += 1
            while let c = peek(), Unit.isDigit(c) || c == Unit.underscore { index += 1 }
        }
        if let e = peek(), e == 0x65 || e == 0x45 {
            let sign = peek(1)
            let digitOffset = (sign == 0x2B || sign == 0x2D) ? 2 : 1
            if let d = peek(digitOffset), Unit.isDigit(d) {
                index += digitOffset
                while let c = peek(), Unit.isDigit(c) { index += 1 }
            }
        }
    }
}
