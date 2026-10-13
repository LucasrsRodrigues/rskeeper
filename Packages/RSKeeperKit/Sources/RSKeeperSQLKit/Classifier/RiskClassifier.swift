import RSKeeperDomain

/// Por que uma instrução recebeu a classificação (exibido na confirmação; NST-07-04).
public enum RiskReason: Sendable, Hashable {
    /// Palavra-chave principal (`DELETE`, `DROP`…).
    case keyword(String)
    /// `DELETE`/`UPDATE` sem `WHERE` no mesmo nível.
    case missingWhere(String)
    /// CTE (`WITH`) que modifica dados.
    case dataModifyingCTE
    /// `SELECT … INTO` cria tabela (PostgreSQL).
    case selectInto
    /// `EXPLAIN ANALYZE` executa a instrução analisada.
    case explainAnalyze
    /// `VACUUM INTO` cria arquivo.
    case vacuumInto
    /// `ATTACH`/`DETACH` (SQLite).
    case attach
    /// `PRAGMA` que altera estado.
    case writingPragma(String)
    /// `ALTER … DROP`.
    case alterDrop
    /// `SET`/`RESET` de parâmetro de sessão.
    case sessionSetting
    /// Troca de papel ou autorização (`SET ROLE`, `SET SESSION AUTHORIZATION`).
    case roleChange
    /// Comando não reconhecido.
    case unrecognized(String)
    /// Literal ou comentário sem fechamento: o texto não é confiável.
    case unterminated
}

/// Por que uma instrução nunca é enviada, independente de confirmação.
public enum BlockReason: Sendable, Hashable {
    /// `COPY … FROM STDIN` / `TO STDOUT`: exige o subprotocolo de cópia e derruba a conexão (SPK-N03).
    /// A exportação usa outro caminho.
    case copyProtocol
}

public struct ClassifiedStatement: Sendable, Hashable {
    public let risk: StatementRisk
    public let reasons: [RiskReason]
    public let blocked: BlockReason?

    /// Camada 1 do somente leitura (DR-12): só `read`, sem bloqueio.
    public var isAllowedInReadOnly: Bool { risk == .read && blocked == nil }
}

/// Classificador estático de risco (NST-04-05; DR-11; ADR-N20).
///
/// A classificação **não** é garantia: funções com efeito colateral em `SELECT` não são detectáveis.
/// A proteção real em somente leitura é a transação `READ ONLY` e as permissões do banco (DR-12).
public enum RiskClassifier {
    public static func classify(_ statement: SQLStatement, in lexed: LexedSQL) -> ClassifiedStatement {
        let view = TokenView(lexed: lexed, tokenRange: statement.tokenRange)
        if statement.hasUnterminatedToken {
            return ClassifiedStatement(risk: .unknown, reasons: [.unterminated], blocked: nil)
        }
        return classify(view, from: view.firstWordIndex())
    }

    /// Conveniência: divide e classifica um script.
    public static func classify(_ sql: String, dialect: SQLDialect) -> [ClassifiedStatement] {
        let split = StatementSplitter.split(sql, dialect: dialect)
        return split.statements.map { classify($0, in: split.lexed) }
    }

    private static func classify(_ view: TokenView, from start: Int?) -> ClassifiedStatement {
        guard let start, let head = view.word(at: start) else {
            return ClassifiedStatement(risk: .unknown, reasons: [.unrecognized(view.firstText)], blocked: nil)
        }
        func result(_ risk: StatementRisk, _ reasons: [RiskReason] = [.keyword(head)]) -> ClassifiedStatement {
            ClassifiedStatement(risk: risk, reasons: reasons, blocked: nil)
        }

        switch head {
        case "SELECT", "VALUES", "TABLE":
            if head == "SELECT", view.hasWordAtDepthZero("INTO", after: start) {
                return result(.ddl, [.selectInto])
            }
            return dataModification(in: view, from: start) ?? result(.read, [])
        case "SHOW", "DESCRIBE", "DESC":
            return result(.read, [])
        case "WITH":
            return dataModification(in: view, from: start).map {
                ClassifiedStatement(risk: $0.risk, reasons: [.dataModifyingCTE] + $0.reasons, blocked: nil)
            } ?? (view.hasWordAtDepthZero("INTO", after: start) ? result(.ddl, [.selectInto]) : result(.read, []))
        case "EXPLAIN":
            return explain(view, from: start)
        case "INSERT", "REPLACE", "MERGE", "UPSERT":
            return result(.write)
        case "UPDATE", "DELETE":
            return view.hasWhereAtSameDepth(after: start) ? result(.write) : result(.destructive, [.missingWhere(head)])
        case "TRUNCATE", "DROP":
            return result(.destructive)
        case "ALTER":
            return view.hasWordAtDepthZero("DROP", after: start) ? result(.destructive, [.alterDrop]) : result(.ddl)
        case "CREATE", "COMMENT", "GRANT", "REVOKE", "REINDEX", "CLUSTER", "REFRESH", "SECURITY":
            return result(.ddl)
        case "VACUUM":
            return view.hasWordAtDepthZero("INTO", after: start) ? result(.write, [.vacuumInto]) : result(.ddl)
        case "ANALYZE", "LOCK", "CHECKPOINT", "DISCARD", "LISTEN", "UNLISTEN", "NOTIFY":
            return result(.write)
        case "ATTACH", "DETACH":
            return result(.write, [.attach])
        case "PRAGMA":
            return pragma(view, from: start)
        case "BEGIN", "START", "COMMIT", "END", "ROLLBACK", "SAVEPOINT", "RELEASE", "ABORT":
            return result(.transactionControl)
        case "SET", "RESET":
            if let next = view.nextWord(after: start), next == "ROLE" || next == "SESSION" && view.wordAfterNext(start) == "AUTHORIZATION" {
                return result(.unknown, [.roleChange])
            }
            if let next = view.nextWord(after: start), next == "TRANSACTION" || next == "SESSION" && view.wordAfterNext(start) == "CHARACTERISTICS" {
                return result(.transactionControl)
            }
            return result(.transactionControl, [.sessionSetting])
        case "COPY":
            let blocked = view.containsWord("STDIN") || view.containsWord("STDOUT")
            return ClassifiedStatement(risk: .unknown, reasons: [.keyword(head)], blocked: blocked ? .copyProtocol : nil)
        default:
            return result(.unknown, [.unrecognized(head)])
        }
    }

    /// `INSERT/UPDATE/DELETE/MERGE` em qualquer nível (CTE, subconsulta). `nil` se não houver.
    private static func dataModification(in view: TokenView, from start: Int) -> ClassifiedStatement? {
        var reasons: [RiskReason] = []
        var risk: StatementRisk?
        for i in view.significantIndices where i > start {
            guard let word = view.word(at: i) else { continue }
            let previous = view.previousWord(before: i)
            switch word {
            case "INSERT", "MERGE":
                risk = max(risk, .write); reasons.append(.keyword(word))
            case "UPDATE" where previous != "FOR" && previous != "ON" && previous != "DO" && previous != "KEY":
                fallthrough
            case "DELETE" where previous != "ON":
                if view.hasWhereAtSameDepth(after: i) {
                    risk = max(risk, .write); reasons.append(.keyword(word))
                } else {
                    risk = .destructive; reasons.append(.missingWhere(word))
                }
            default:
                continue
            }
        }
        return risk.map { ClassifiedStatement(risk: $0, reasons: reasons, blocked: nil) }
    }

    /// `EXPLAIN` lê, a menos que `ANALYZE` execute a instrução: então vale o risco dela.
    private static func explain(_ view: TokenView, from start: Int) -> ClassifiedStatement {
        var i = view.nextSignificant(after: start)
        var analyze = false
        // EXPLAIN ANALYZE VERBOSE … | EXPLAIN (ANALYZE, BUFFERS) … | EXPLAIN QUERY PLAN …
        while let index = i {
            if view.kind(at: index) == .openParen {
                let close = view.matchingClose(of: index)
                for inner in view.significantIndices where inner > index && inner < close {
                    guard view.word(at: inner) == "ANALYZE" else { continue }
                    let value = view.word(at: view.nextSignificant(after: inner) ?? inner)
                    if value != "FALSE" && value != "OFF" && value != "0" { analyze = true }
                }
                i = view.nextSignificant(after: close)
                continue
            }
            guard let word = view.word(at: index) else { break }
            if word == "ANALYZE" || word == "ANALYSE" { analyze = true; i = view.nextSignificant(after: index); continue }
            if ["VERBOSE", "QUERY", "PLAN"].contains(word) { i = view.nextSignificant(after: index); continue }
            break
        }
        guard analyze else { return ClassifiedStatement(risk: .read, reasons: [], blocked: nil) }
        let inner = classify(view, from: i)
        return ClassifiedStatement(risk: inner.risk, reasons: [.explainAnalyze] + inner.reasons, blocked: inner.blocked)
    }

    /// Pragmas que só leem, inclusive na forma de função com argumento.
    private static let readOnlyPragmasWithArgument: Set<String> = [
        "TABLE_INFO", "TABLE_XINFO", "INDEX_LIST", "INDEX_INFO", "INDEX_XINFO", "FOREIGN_KEY_LIST",
        "FOREIGN_KEY_CHECK", "INTEGRITY_CHECK", "QUICK_CHECK", "TABLE_LIST", "PRAGMA_LIST", "FUNCTION_LIST",
        "COLLATION_LIST", "MODULE_LIST", "DATABASE_LIST", "COMPILE_OPTIONS",
    ]
    /// Pragmas que agem mesmo sem `=`.
    private static let actionPragmas: Set<String> = ["WAL_CHECKPOINT", "OPTIMIZE", "INCREMENTAL_VACUUM", "SHRINK_MEMORY"]

    private static func pragma(_ view: TokenView, from start: Int) -> ClassifiedStatement {
        var nameIndex = view.nextSignificant(after: start)
        // PRAGMA schema.nome
        if let first = nameIndex, let dot = view.nextSignificant(after: first), view.text(at: dot) == ".",
           let afterDot = view.nextSignificant(after: dot) {
            nameIndex = afterDot
        }
        guard let nameIndex, let name = view.word(at: nameIndex) else {
            return ClassifiedStatement(risk: .unknown, reasons: [.unrecognized("PRAGMA")], blocked: nil)
        }
        let next = view.nextSignificant(after: nameIndex)
        let assigns = next.map { view.text(at: $0) == "=" } ?? false
        let hasArgument = next.map { view.kind(at: $0) == .openParen } ?? false
        if assigns || actionPragmas.contains(name) || (hasArgument && !readOnlyPragmasWithArgument.contains(name)) {
            return ClassifiedStatement(risk: .write, reasons: [.writingPragma(name.lowercased())], blocked: nil)
        }
        return ClassifiedStatement(risk: .read, reasons: [], blocked: nil)
    }

    private static func max(_ current: StatementRisk?, _ new: StatementRisk) -> StatementRisk {
        guard let current else { return new }
        return severity(current) >= severity(new) ? current : new
    }

    private static func severity(_ risk: StatementRisk) -> Int {
        switch risk {
        case .read: 0
        case .transactionControl: 1
        case .write: 2
        case .ddl: 3
        case .destructive: 4
        case .unknown: 5
        }
    }
}

/// Visão dos tokens significativos de uma instrução, com profundidade de parênteses.
private struct TokenView {
    let lexed: LexedSQL
    let significantIndices: [Int]
    let depth: [Int: Int]

    init(lexed: LexedSQL, tokenRange: Range<Int>) {
        self.lexed = lexed
        var indices: [Int] = []
        var depth: [Int: Int] = [:]
        var current = 0
        for i in tokenRange where !lexed.tokens[i].kind.isTrivia {
            let kind = lexed.tokens[i].kind
            if kind == .closeParen { current = Swift.max(0, current - 1) }
            depth[i] = current
            if kind == .openParen { current += 1 }
            indices.append(i)
        }
        self.significantIndices = indices
        self.depth = depth
    }

    var firstText: String { significantIndices.first.map { text(at: $0) } ?? "" }

    func kind(at i: Int) -> SQLTokenKind { lexed.tokens[i].kind }
    func text(at i: Int) -> String { lexed.text(of: lexed.tokens[i]) }
    func word(at i: Int) -> String? { lexed.keyword(lexed.tokens[i]) }

    /// Primeira palavra, pulando parênteses de abertura (`(SELECT …)`).
    func firstWordIndex() -> Int? { significantIndices.first { kind(at: $0) == .word } }

    func nextSignificant(after i: Int) -> Int? { significantIndices.first { $0 > i } }
    func nextWord(after i: Int) -> String? { nextSignificant(after: i).flatMap(word(at:)) }
    func wordAfterNext(_ i: Int) -> String? { nextSignificant(after: i).flatMap { nextWord(after: $0) } }
    func previousWord(before i: Int) -> String? { significantIndices.last { $0 < i }.flatMap(word(at:)) }
    func containsWord(_ w: String) -> Bool { significantIndices.contains { word(at: $0) == w } }

    func hasWordAtDepthZero(_ w: String, after start: Int) -> Bool {
        significantIndices.contains { $0 > start && depth[$0] == depth[start] && word(at: $0) == w }
    }

    /// `WHERE` no mesmo nível de parênteses, antes de sair desse nível (ou do fim da instrução).
    func hasWhereAtSameDepth(after start: Int) -> Bool {
        guard let level = depth[start] else { return false }
        for i in significantIndices where i > start {
            let d = depth[i] ?? 0
            if d < level || (d == level && kind(at: i) == .closeParen) { return false }
            if d == level, word(at: i) == "WHERE" { return true }
        }
        return false
    }

    func matchingClose(of open: Int) -> Int {
        let level = depth[open] ?? 0
        return significantIndices.first { $0 > open && kind(at: $0) == .closeParen && depth[$0] == level } ?? (significantIndices.last ?? open)
    }
}
