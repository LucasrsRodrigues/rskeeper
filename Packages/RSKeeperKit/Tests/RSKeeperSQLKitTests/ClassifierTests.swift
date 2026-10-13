import Testing
import RSKeeperDomain
@testable import RSKeeperSQLKit

/// NST-04-05 — classificação de risco (DR-11), parâmetros e URL.
@Suite("SQLKit — risco, parâmetros e URL (W1-T01)")
struct ClassifierTests {
    private func risk(_ sql: String, _ dialect: SQLDialect = .postgresql) -> StatementRisk {
        let all = RiskClassifier.classify(sql, dialect: dialect)
        precondition(all.count == 1, "esperada 1 instrução em: \(sql)")
        return all[0].risk
    }

    @Test("Corpus de risco", arguments: [
        ("SELECT * FROM t", StatementRisk.read),
        ("(SELECT 1) UNION (SELECT 2)", .read),
        ("select * from t for update", .read),
        ("VALUES (1), (2)", .read),
        ("SHOW search_path", .read),
        ("EXPLAIN SELECT * FROM t", .read),
        ("EXPLAIN (ANALYZE false) DELETE FROM t", .read),
        ("WITH x AS (SELECT 1) SELECT * FROM x", .read),
        ("INSERT INTO t VALUES (1)", .write),
        ("INSERT INTO t VALUES (1) ON CONFLICT (id) DO UPDATE SET v = 2", .write),
        ("UPDATE t SET v = 1 WHERE id = 2", .write),
        ("UPDATE t SET v = (SELECT max(v) FROM u WHERE u.id = 1)", .destructive),
        ("DELETE FROM t WHERE id = 1", .write),
        ("DELETE FROM t", .destructive),
        ("dElEtE   fRoM t", .destructive),
        ("/* comentário */ DELETE FROM t", .destructive),
        ("DELETE /* WHERE */ FROM t -- WHERE id = 1", .destructive),
        ("DELETE FROM t WHERE id IN (SELECT id FROM u)", .write),
        ("TRUNCATE t", .destructive),
        ("DROP TABLE t", .destructive),
        ("ALTER TABLE t ADD COLUMN c int", .ddl),
        ("ALTER TABLE t DROP COLUMN c", .destructive),
        ("CREATE TABLE t (id int REFERENCES u ON DELETE CASCADE ON UPDATE CASCADE)", .ddl),
        ("CREATE INDEX i ON t (c)", .ddl),
        ("GRANT SELECT ON t TO r", .ddl),
        ("SELECT * INTO nova FROM t", .ddl),
        ("BEGIN", .transactionControl),
        ("COMMIT", .transactionControl),
        ("ROLLBACK TO SAVEPOINT s", .transactionControl),
        ("SET TRANSACTION READ WRITE", .transactionControl),
        ("SET search_path TO app", .transactionControl),
        ("RESET ALL", .transactionControl),
        ("SET ROLE admin", .unknown),
        ("SET SESSION AUTHORIZATION admin", .unknown),
        ("DO $$ BEGIN DELETE FROM t; END $$", .unknown),
        ("CALL proc()", .unknown),
        ("COPY t TO '/tmp/x'", .unknown),
        ("frobnicate everything", .unknown),
    ])
    func corpus(sql: String, expected: StatementRisk) {
        #expect(risk(sql) == expected, "\(sql)")
    }

    @Test("CTE que modifica dados nunca é leitura")
    func dataModifyingCTE() {
        #expect(risk("WITH d AS (DELETE FROM t WHERE id = 1 RETURNING *) SELECT * FROM d") == .write)
        #expect(risk("WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d") == .destructive)
        #expect(risk("WITH x AS (SELECT 1) UPDATE t SET v = 1") == .destructive)
        #expect(risk("WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x") == .write)
        let classified = RiskClassifier.classify("WITH d AS (DELETE FROM t RETURNING *) SELECT 1", dialect: .postgresql)[0]
        #expect(classified.reasons.first == .dataModifyingCTE)
    }

    @Test("EXPLAIN ANALYZE executa: vale o risco da instrução analisada")
    func explainAnalyze() {
        #expect(risk("EXPLAIN ANALYZE DELETE FROM t") == .destructive)
        #expect(risk("EXPLAIN (ANALYZE, BUFFERS) UPDATE t SET v = 1 WHERE id = 1") == .write)
        #expect(risk("EXPLAIN ANALYZE SELECT 1") == .read)
        #expect(risk("EXPLAIN QUERY PLAN SELECT 1", .sqlite) == .read)
    }

    @Test("SQLite: PRAGMA de leitura × escrita, VACUUM INTO e ATTACH")
    func sqliteSpecifics() {
        #expect(risk("PRAGMA journal_mode", .sqlite) == .read)
        #expect(risk("PRAGMA main.table_info(t)", .sqlite) == .read)
        #expect(risk("PRAGMA journal_mode = WAL", .sqlite) == .write)
        #expect(risk("PRAGMA journal_mode(WAL)", .sqlite) == .write)
        #expect(risk("PRAGMA query_only = 0", .sqlite) == .write)
        #expect(risk("PRAGMA wal_checkpoint", .sqlite) == .write)
        #expect(risk("VACUUM", .sqlite) == .ddl)
        #expect(risk("VACUUM INTO '/tmp/copia.db'", .sqlite) == .write)
        #expect(risk("ATTACH DATABASE 'x.db' AS x", .sqlite) == .write)
        #expect(risk("INSERT OR REPLACE INTO t VALUES (1)", .sqlite) == .write)
        #expect(risk("REPLACE INTO t VALUES (1)", .sqlite) == .write)
    }

    @Test("Somente leitura (camada 1): só `read` passa; corpus de contorno do NT-DRV-06 é recusado")
    func readOnlyLayer() {
        let refused = ["BEGIN READ WRITE", "SET TRANSACTION READ WRITE", "RESET ALL", "PRAGMA query_only=0; VACUUM INTO 'x'",
                       "ATTACH 'novo.db' AS n", "PRAGMA journal_mode=WAL", "EXPLAIN ANALYZE DELETE FROM t", "SELECT 'x"]
        for script in refused {
            let dialect: SQLDialect = script.contains("PRAGMA") || script.contains("ATTACH") ? .sqlite : .postgresql
            #expect(RiskClassifier.classify(script, dialect: dialect).contains { !$0.isAllowedInReadOnly }, "\(script)")
        }
        #expect(RiskClassifier.classify("SELECT 1; SHOW x", dialect: .postgresql).allSatisfy { $0.isAllowedInReadOnly })
    }

    @Test("COPY FROM STDIN / TO STDOUT é bloqueado (SPK-N03)")
    func copyBlocked() {
        #expect(RiskClassifier.classify("COPY t FROM STDIN", dialect: .postgresql)[0].blocked == .copyProtocol)
        #expect(RiskClassifier.classify("COPY (SELECT 1) TO STDOUT", dialect: .postgresql)[0].blocked == .copyProtocol)
        #expect(RiskClassifier.classify("SELECT 'COPY x FROM STDIN'", dialect: .postgresql)[0].blocked == nil)
    }

    @Test("Literal sem fechamento é `unknown`")
    func unterminatedIsUnknown() {
        #expect(risk("SELECT 'aberto") == .unknown)
    }

    // MARK: Parâmetros

    @Test("`:nome` fora de literal, comentário e cast; reescrita por estilo")
    func parameters() throws {
        let text = "SELECT :a, ':b', $$:c$$, x::int, :a, :d -- :e"
        let split = StatementSplitter.split(text, dialect: .postgresql)
        let statement = split.statements[0]
        #expect(ParameterScanner.names(in: statement, lexed: split.lexed) == ["a", "d"])
        let pg = try ParameterScanner.rewrite(statement, lexed: split.lexed, style: .dollarNumbered)
        #expect(pg.sql == "SELECT $1, ':b', $$:c$$, x::int, $1, $2")
        #expect(pg.bindOrder == ["a", "d"])

        let sqliteSplit = StatementSplitter.split("SELECT * FROM t WHERE a = :a AND b = :b OR a = :a", dialect: .sqlite)
        let q = try ParameterScanner.rewrite(sqliteSplit.statements[0], lexed: sqliteSplit.lexed, style: .questionMark)
        #expect(q.sql == "SELECT * FROM t WHERE a = ? AND b = ? OR a = ?")
        #expect(q.bindOrder == ["a", "b", "a"])
    }

    @Test("Mistura de `:nome` com posicional é recusada")
    func mixedParameters() {
        let split = StatementSplitter.split("SELECT :a, ?", dialect: .sqlite)
        #expect(throws: ParameterError.mixedStyles) {
            try ParameterScanner.rewrite(split.statements[0], lexed: split.lexed, style: .questionMark)
        }
    }

    // MARK: URL

    @Test("URL PostgreSQL completa, com caracteres codificados e sslmode")
    func postgresURL() throws {
        let parsed = try ConnectionURLParser.parse("postgres://app%40corp:s%3Ag%2Fredo@db.example.com:6543/vendas?sslmode=verify-full&application_name=x")
        #expect(parsed.kind == .postgresql)
        #expect(parsed.host == "db.example.com")
        #expect(parsed.port == 6543)
        #expect(parsed.user == "app@corp")
        #expect(parsed.password?.reveal() == "s:g/redo")
        #expect(parsed.database == "vendas")
        #expect(parsed.tlsMode == .verifyFull)
        #expect(parsed.ignoredParameters == ["application_name"])
    }

    @Test("A senha colada nunca aparece em descrição ou interpolação (AR-IPC-08)")
    func passwordRedacted() throws {
        let parsed = try ConnectionURLParser.parse("postgresql://u:supersecreta@h/db")
        #expect(!"\(parsed)".contains("supersecreta"))
        #expect(!String(reflecting: parsed).contains("supersecreta"))
        #expect("\(parsed.password!)" == "<secret>")
    }

    @Test("URL mínima, IPv6 e SQLite")
    func otherURLs() throws {
        let minimal = try ConnectionURLParser.parse("postgresql://localhost")
        #expect(minimal.host == "localhost" && minimal.port == nil && minimal.user == nil && minimal.database == nil)
        #expect(try ConnectionURLParser.parse("postgres://[::1]:5432/db").host == "::1")
        let sqlite = try ConnectionURLParser.parse("sqlite:///Users/eu/dados%20app.db")
        #expect(sqlite.kind == .sqlite && sqlite.filePath == "/Users/eu/dados app.db")
    }

    @Test("Erros: esquema, porta e sslmode inválidos")
    func urlErrors() {
        #expect(throws: ConnectionURLError.unsupportedScheme("http")) { try ConnectionURLParser.parse("http://x") }
        #expect(throws: ConnectionURLError.invalidSSLMode("talvez")) { try ConnectionURLParser.parse("postgres://h/db?sslmode=talvez") }
        #expect(throws: (any Error).self) { try ConnectionURLParser.parse("postgres://h:99999/db") }
        #expect(throws: ConnectionURLError.invalidURL) { try ConnectionURLParser.parse("sem esquema") }
    }
}
