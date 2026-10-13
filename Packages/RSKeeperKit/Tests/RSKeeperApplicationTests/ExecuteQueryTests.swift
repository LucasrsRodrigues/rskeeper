import Foundation
import Testing
import RSKeeperApplication
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperDriverSQLite
import RSKeeperSQLKit

/// NST-07-02 — planejar e executar consultas; scripts param na primeira falha (W1-T07).
@Suite("Executar e cancelar (W1-T07, NST-07-02)", .serialized)
struct ExecuteQueryTests {
    private struct SQLiteBox {
        let directory: URL
        let session: DatabaseSession
        let tab = TabID.generate()

        static func make(maxConnections: Int = 4) async throws -> SQLiteBox {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rsk-exec-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("t.db").path
            FileManager.default.createFile(atPath: path, contents: nil)
            let registry = SessionRegistry(limits: .init(maxConnectionsPerSession: maxConnections))
            let window = WindowID.generate()
            let id = try await registry.open(window: window, profileID: ProfileID.generate(), factory: SQLiteDriver(),
                                             target: .file(path: path, readOnly: false), options: OpenOptions())
            return SQLiteBox(directory: directory, session: try await registry.session(id, for: window))
        }

        @discardableResult
        func run(_ text: String, scope: ExecutionScope = .all, id: ExecutionID = .generate()) async throws -> ScriptOutcome {
            let plan = try ExecuteQueryUseCase().plan(text, scope: scope, dialect: .sqlite, placeholders: .question, readOnly: false)
            return try await ExecuteQueryUseCase().run(plan, session: session, tab: tab, executionID: id)
        }

        func count(_ table: String) async throws -> Int64? {
            let outcome = try await run("SELECT count(*) FROM \(table)")
            if case .rows(_, let batch, _, _)? = outcome.outcomes.first, case .int(let n) = batch.columns[0][0] { return n }
            return nil
        }

        func cleanup() async {
            await session.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("NT-DRV-09: falha na 2ª de 3 → ok/failed/skipped; Auto efetiva a 1ª")
    func stopsAtFirstFailure() async throws {
        let box = try await SQLiteBox.make()
        try await box.run("CREATE TABLE t (a INTEGER NOT NULL)")
        let outcome = try await box.run("INSERT INTO t VALUES (1); INSERT INTO t VALUES (NULL); INSERT INTO t VALUES (3)")
        #expect(outcome.reports.map(\.status.isOK) == [true, false, false])
        #expect(outcome.reports[2].status == .skipped)
        #expect(outcome.reports.map(\.committed) == [.yes, .no, .no])
        #expect(outcome.reports[0].affectedRows == 1)
        #expect(StatementReport.stopAtFirstFailure(outcome.reports))
        #expect(try await box.count("t") == 1)
        await box.cleanup()
    }

    @Test("BEGIN…COMMIT efetiva; BEGIN…ROLLBACK desfaz; ROLLBACK TO não encerra")
    func explicitTransactionsInScript() async throws {
        let box = try await SQLiteBox.make()
        try await box.run("CREATE TABLE t (a INTEGER)")
        let committed = try await box.run("BEGIN; INSERT INTO t VALUES (1); COMMIT")
        #expect(committed.reports[1].committed == .yes)
        let rolledBack = try await box.run("BEGIN; INSERT INTO t VALUES (2); SAVEPOINT s; INSERT INTO t VALUES (3); ROLLBACK TO s; ROLLBACK")
        #expect(rolledBack.reports[1].committed == .no)
        #expect(rolledBack.reports[3].committed == .no)
        #expect(!rolledBack.autoRolledBackTransaction)
        #expect(try await box.count("t") == 1)
        await box.cleanup()
    }

    @Test("Modo Auto: BEGIN sem COMMIT é desfeito na devolução, com aviso (DR-17)")
    func autoModeLeftOpen() async throws {
        let box = try await SQLiteBox.make()
        try await box.run("CREATE TABLE t (a INTEGER)")
        let outcome = try await box.run("BEGIN; INSERT INTO t VALUES (1)")
        #expect(outcome.autoRolledBackTransaction)
        #expect(outcome.reports[1].committed == .no)
        #expect(try await box.count("t") == 0)
        await box.cleanup()
    }

    @Test("Repetir o ExecutionID devolve o desfecho sem reexecutar (DR-06); segunda execução na aba → busy")
    func idempotencyAndBusy() async throws {
        let box = try await SQLiteBox.make()
        try await box.run("CREATE TABLE t (a INTEGER)")
        let id = ExecutionID.generate()
        _ = try await box.run("INSERT INTO t VALUES (1)", id: id)
        _ = try await box.run("INSERT INTO t VALUES (1)", id: id)
        #expect(try await box.count("t") == 1)

        let long = Task {
            try await box.run("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c")
        }
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: RSKeeperError.conflict(.busy)) { try await box.run("SELECT 1") }
        long.cancel()
        let result = try await long.value
        #expect(result.reports.first?.status == .cancelled)
        #expect(try await box.count("t") == 1, "a aba volta a aceitar execução depois do cancelamento")
        await box.cleanup()
    }

    @Test("Cancelar pela sessão interrompe em ≤ 1 s [META] e marca .cancelled; as seguintes ficam .skipped")
    func cancelBySession() async throws {
        let box = try await SQLiteBox.make()
        let id = ExecutionID.generate()
        let running = Task {
            try await box.run("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c; SELECT 2", id: id)
        }
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let start = clock.now
        await box.session.cancel(id)
        let outcome = try await running.value
        #expect(clock.now - start < .seconds(1))
        #expect(outcome.reports.map(\.status) == [.cancelled, .skipped])
        await box.cleanup()
    }

    @Test("Plano: instrução atual, seleção, indisponível entre instruções, somente leitura e parâmetros")
    func planning() throws {
        let useCase = ExecuteQueryUseCase()
        let text = "SELECT 1;\n\nDELETE FROM t WHERE id = :id;"
        let current = try useCase.plan(text, scope: .current(cursor: 3), dialect: .sqlite, placeholders: .question, readOnly: false)
        #expect(current.statements.map(\.statement.sql) == ["SELECT 1"])
        #expect(!ExecuteQueryUseCase.hasCurrentStatement(text, cursor: 10, dialect: .sqlite))
        #expect(throws: RSKeeperError.self) { try useCase.plan(text, scope: .current(cursor: 10), dialect: .sqlite, placeholders: .question, readOnly: false) }
        // Seleção de um trecho vira a instrução marcada, com intervalo no texto original.
        let selection = try useCase.plan(text, scope: .selection(0..<6), dialect: .sqlite, placeholders: .question, readOnly: false)
        #expect(selection.statements.map(\.statement.sql) == ["SELECT"] && selection.statements[0].sourceRange == 0..<6)
        // Parâmetros: faltando → erro com o nome; presente → ligado por bind no estilo do driver.
        #expect(ExecuteQueryUseCase.parameterNames(text, scope: .all, dialect: .sqlite) == ["id"])
        #expect(throws: RSKeeperError.validation(RedactedMessage(alreadyRedacted: "Informe valores para: :id"))) {
            try useCase.plan(text, scope: .all, dialect: .sqlite, placeholders: .question, readOnly: false)
        }
        let bound = try useCase.plan(text, scope: .all, dialect: .postgresql, placeholders: .dollarNumbered, readOnly: false, parameters: ["id": .int(7)])
        #expect(bound.statements[1].statement.sql == "DELETE FROM t WHERE id = $1" && bound.statements[1].statement.bindings == [.int(7)])
        #expect(bound.statements.map(\.risk) == [.read, .write])
        // Somente leitura (DR-12, camada 1): recusado antes do envio.
        #expect(throws: RSKeeperError.readOnly) {
            try useCase.plan(text, scope: .all, dialect: .sqlite, placeholders: .question, readOnly: true, parameters: ["id": .int(1)])
        }
        #expect(throws: RSKeeperError.self) { try useCase.plan("COPY t FROM STDIN", scope: .all, dialect: .postgresql, placeholders: .dollarNumbered, readOnly: false) }
    }
}

private extension StatementStatus {
    var isOK: Bool { self == .ok }
}
