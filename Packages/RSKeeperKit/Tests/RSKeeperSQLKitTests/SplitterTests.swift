import Testing
@testable import RSKeeperSQLKit

/// NST-04-05 — lexer e divisor (corpus por dialeto e propriedade de partição).
@Suite("SQLKit — lexer e divisor (W1-T01)")
struct SplitterTests {
    private func sqls(_ text: String, _ dialect: SQLDialect) -> [String] {
        StatementSplitter.split(text, dialect: dialect).statements.map(\.sql)
    }

    @Test("`;` em string, identificador citado e comentários não divide", arguments: SQLDialect.allCases)
    func semicolonInsideLiterals(dialect: SQLDialect) {
        let text = """
        SELECT 'a;b', "c;d" FROM t; -- comentário; com ponto e vírgula
        /* bloco; */ SELECT 2;
        """
        #expect(sqls(text, dialect) == ["SELECT 'a;b', \"c;d\" FROM t", "SELECT 2"])
    }

    @Test("Aspas dobradas como escape")
    func doubledQuotes() {
        #expect(sqls("SELECT 'it''s; ok'; SELECT 1", .sqlite) == ["SELECT 'it''s; ok'", "SELECT 1"])
    }

    @Test("PostgreSQL: dollar quoting com e sem tag, E-string e comentário aninhado")
    func postgresQuoting() {
        let text = """
        DO $$ BEGIN RAISE NOTICE 'x;y'; END $$;
        CREATE FUNCTION f() RETURNS int AS $body$ SELECT 1; $body$ LANGUAGE sql;
        SELECT E'a\\';b';
        /* externo /* interno; */ ainda; */ SELECT 3;
        SELECT $1::int, 'x'::text
        """
        let result = sqls(text, .postgresql)
        #expect(result.count == 5)
        #expect(result[0].hasPrefix("DO $$"))
        #expect(result[1].hasSuffix("LANGUAGE sql"))
        #expect(result[2] == "SELECT E'a\\';b'")
        #expect(result[3] == "SELECT 3")
        #expect(result[4] == "SELECT $1::int, 'x'::text")
    }

    @Test("SQLite: comentário de bloco não aninha; crase e colchetes são identificadores")
    func sqliteQuoting() {
        #expect(sqls("/* a /* b */ SELECT 1; SELECT [x;y], `z;w` FROM t", .sqlite) == ["SELECT 1", "SELECT [x;y], `z;w` FROM t"])
    }

    @Test("SQLite: corpo de trigger BEGIN…END com CASE…END interno é uma instrução só")
    func sqliteTrigger() {
        let text = """
        CREATE TRIGGER trg AFTER INSERT ON t BEGIN
          UPDATE t SET v = CASE WHEN NEW.v > 0 THEN 1 ELSE 0 END WHERE id = NEW.id;
          INSERT INTO log VALUES (NEW.id);
        END;
        SELECT 1;
        """
        let result = sqls(text, .sqlite)
        #expect(result.count == 2)
        #expect(result[0].hasSuffix("END"))
        #expect(result[1] == "SELECT 1")
    }

    @Test("SQLite: BEGIN de transação continua dividindo")
    func sqliteTransactionBegin() {
        #expect(sqls("BEGIN; INSERT INTO t VALUES (1); COMMIT;", .sqlite) == ["BEGIN", "INSERT INTO t VALUES (1)", "COMMIT"])
    }

    @Test("PostgreSQL: BEGIN ATOMIC…END (PG14+) é uma instrução só")
    func postgresBeginAtomic() {
        let text = """
        CREATE FUNCTION g() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT CASE WHEN true THEN 2 END; END;
        SELECT 4
        """
        let result = sqls(text, .postgresql)
        #expect(result.count == 2)
        #expect(result[0].hasSuffix("END"))
    }

    @Test("Instruções vazias e só comentário não são emitidas", arguments: SQLDialect.allCases)
    func emptyStatements(dialect: SQLDialect) {
        #expect(sqls(" ;; -- só comentário\n ; /* x */ ", dialect).isEmpty)
        #expect(sqls("", dialect).isEmpty)
    }

    @Test("Literal sem fechamento: tudo até o fim é uma instrução marcada", arguments: SQLDialect.allCases)
    func unterminated(dialect: SQLDialect) {
        let split = StatementSplitter.split("SELECT 1; SELECT 'aberto; DROP TABLE t", dialect: dialect)
        #expect(split.statements.count == 2)
        #expect(split.statements[1].hasUnterminatedToken)
    }

    @Test("Instrução atual: cursor dentro, logo após o `;`, e entre instruções → indisponível")
    func currentStatement() {
        let text = "SELECT 1;\n\n  SELECT 2;"
        let split = StatementSplitter.split(text, dialect: .sqlite)
        #expect(split.statement(atUTF16Offset: 3)?.sql == "SELECT 1")
        #expect(split.statement(atUTF16Offset: 9)?.sql == "SELECT 1")              // logo após o ;
        #expect(split.statement(atUTF16Offset: 10) == nil)                         // linha vazia
        #expect(split.statement(atUTF16Offset: 13)?.sql == "SELECT 2")
    }

    @Test("Seleção: instruções que se sobrepõem ao intervalo")
    func selection() {
        let split = StatementSplitter.split("SELECT 1; SELECT 2; SELECT 3", dialect: .sqlite)
        #expect(split.statements(overlapping: 12..<22).map(\.sql) == ["SELECT 2", "SELECT 3"])
    }

    @Test("Intervalos UTF-16 corretos com acentos e emoji")
    func utf16Ranges() {
        let text = "SELECT 'café 🎉'; SELECT 2"
        let split = StatementSplitter.split(text, dialect: .postgresql)
        let ns = text.utf16
        let first = split.statements[0].range
        let slice = String(ns[ns.index(ns.startIndex, offsetBy: first.lowerBound)..<ns.index(ns.startIndex, offsetBy: first.upperBound)])
        #expect(slice == "SELECT 'café 🎉'")
    }

    /// Propriedade (NST-04-05): os tokens particionam o texto; o que fica fora das instruções é só
    /// espaço, comentário ou `;`; dividir e juntar preserva o texto.
    @Test("Propriedade: partição e reconstrução preservam o texto", arguments: SQLDialect.allCases)
    func partitionProperty(dialect: SQLDialect) {
        var generator = SplitMix(seed: 0x5EED)
        let fragments = ["SELECT", " ", "\n", ";", "'a;b'", "\"q\"", "--c\n", "/*x;*/", "$$d;$$", "(", ")", "1.5", ":p",
                         "::int", "é", "🎉", "E'\\''", "[b]", "`t`", "BEGIN", "END", "CASE", "CREATE TRIGGER", "?", "@x", "'", "/*"]
        for _ in 0..<500 {
            let text = (0..<Int(generator.next() % 30)).map { _ in fragments[Int(generator.next() % UInt64(fragments.count))] }.joined()
            let split = StatementSplitter.split(text, dialect: dialect)
            let lexed = split.lexed
            // 1. Tokens contíguos cobrindo tudo.
            var position = 0
            for token in lexed.tokens {
                #expect(token.range.lowerBound == position)
                position = token.range.upperBound
            }
            #expect(position == lexed.units.count)
            // 2. Reconstrução: instruções + lacunas = texto original; lacunas só trivia/`;`.
            var rebuilt = ""
            var cursor = 0
            for statement in split.statements {
                let gap = lexed.text(cursor..<statement.range.lowerBound)
                #expect(isTrivia(gap, dialect), "lacuna não trivial: \(gap)")
                rebuilt += gap + statement.sql
                cursor = statement.range.upperBound
            }
            let tail = lexed.text(cursor..<lexed.units.count)
            #expect(isTrivia(tail, dialect))
            rebuilt += tail
            #expect(rebuilt == text)
        }
    }

    private func isTrivia(_ text: String, _ dialect: SQLDialect) -> Bool {
        SQLLexer.tokenize(text, dialect: dialect).tokens.allSatisfy { $0.kind.isTrivia || $0.kind == .semicolon }
    }

    @Test("Desempenho: 5 MB tokenizados e divididos em tempo linear")
    func performance() {
        let unit = "SELECT a, 'x;y', \"c\" FROM t WHERE b = :p; -- c\n"
        let text = String(repeating: unit, count: 5_000_000 / unit.utf8.count)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = StatementSplitter.split(text, dialect: .postgresql) }
        #expect(elapsed < .seconds(3), "5 MB levaram \(elapsed)")
    }
}

/// Gerador determinístico para o teste de propriedade.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
