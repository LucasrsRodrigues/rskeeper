import Foundation
import Testing
import RSKeeperApplication
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperDriverSQLite
import RSKeeperSQLKit

/// NST-07-04 — motor de políticas (DR-11) e token de confirmação (DR-14) (W1-T08; NT-X01).
@Suite("Confirmação de risco (W1-T08, NST-07-04)", .serialized)
struct PolicyTests {
    private let engine = OperationPolicyEngine()
    private func context(_ environment: EnvironmentKind, readOnly: Bool = false) -> OperationPolicyContext {
        OperationPolicyContext(environment: environment, readOnly: readOnly, targetName: "Vendas Prod")
    }

    @Test("Matriz DR-11: risco × ambiente × somente leitura", arguments: [
        (StatementRisk.read, false, false, "allow"), (.read, true, false, "allow"), (.read, false, true, "allow"),
        (.transactionControl, false, false, "allow"), (.transactionControl, true, false, "allow"), (.transactionControl, false, true, "deny"),
        (.write, false, false, "allow"), (.write, true, false, "confirm"), (.write, false, true, "deny"),
        (.ddl, false, false, "allow"), (.ddl, true, false, "confirm"), (.ddl, false, true, "deny"),
        (.destructive, false, false, "confirm"), (.destructive, true, false, "type"), (.destructive, false, true, "deny"),
        (.unknown, false, false, "confirm"), (.unknown, true, false, "type"), (.unknown, false, true, "deny"),
    ])
    func matrix(risk: StatementRisk, production: Bool, readOnly: Bool, expected: String) {
        let decision = engine.evaluate([risk], context: context(production ? .production : .development, readOnly: readOnly))
        let actual: String = switch decision {
        case .allow: "allow"
        case .deny: "deny"
        case .confirm(let requirement): requirement.mustTypeTargetName == nil ? "confirm" : "type"
        }
        #expect(actual == expected, "\(risk) produção=\(production) leitura=\(readOnly)")
    }

    @Test("Ambientes não produtivos seguem a política padrão; o pedido lista as instruções que motivam")
    func requirementDetails() {
        for environment in [EnvironmentKind.local, .development, .testing, .staging] {
            #expect(engine.evaluate([.write, .ddl], context: context(environment)) == .allow)
        }
        guard case .confirm(let requirement) = engine.evaluate([.read, .destructive, .write, .unknown], context: context(.production)) else {
            Issue.record("esperada confirmação"); return
        }
        #expect(requirement.statements == [1, 2, 3])
        #expect(requirement.risks == [.destructive, .write, .unknown])
        #expect(requirement.mustTypeTargetName == "Vendas Prod")
    }

    @Test("Contornos por comentário e caixa mista continuam destrutivos (NT-SEC)")
    func bypassAttempts() throws {
        for sql in ["/* inofensivo */ DeLeTe FROM t", "-- só leitura\nDROP TABLE t", "WITH x AS (DELETE FROM t RETURNING 1) SELECT * FROM x"] {
            let plan = try ExecuteQueryUseCase().plan(sql, scope: .all, dialect: .postgresql, placeholders: .dollarNumbered, readOnly: false)
            guard case .confirm = engine.evaluate(plan.statements.map(\.risk), context: context(.development)) else {
                Issue.record("não pediu confirmação: \(sql)"); continue
            }
        }
    }

    // MARK: Token na sessão (SQLite real)

    private struct Box {
        let directory: URL
        let session: DatabaseSession
        let tab = TabID.generate()
        static func make(_ policy: OperationPolicyContext, lifetime: Duration = .seconds(60)) async throws -> Box {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rsk-policy-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("t.db").path
            FileManager.default.createFile(atPath: path, contents: nil)
            // Preparação direto pelo driver (fora da política da sessão em teste).
            let setup = try await SQLiteDriver().open(.file(path: path, readOnly: false), options: OpenOptions())
            _ = try await setup.execute(BoundStatement(sql: "CREATE TABLE t (a INTEGER)"), limits: .default)
            _ = try await setup.execute(BoundStatement(sql: "INSERT INTO t VALUES (1)"), limits: .default)
            await setup.close()
            var limits = SessionRegistry.Limits()
            limits.confirmationLifetime = lifetime
            let registry = SessionRegistry(limits: limits)
            let window = WindowID.generate()
            let id = try await registry.open(window: window, profileID: .generate(), factory: SQLiteDriver(),
                                             target: .file(path: path, readOnly: false), policy: policy)
            let box = Box(directory: directory, session: try await registry.session(id, for: window))
            return box
        }
        func plan(_ sql: String) throws -> ExecutionPlan {
            try ExecuteQueryUseCase().plan(sql, scope: .all, dialect: .sqlite, placeholders: .question, readOnly: false)
        }
        func cleanup() async {
            await session.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("Sem token, a sessão recusa (contornar a UI não basta); com token válido executa uma vez")
    func tokenRequiredAndSingleUse() async throws {
        let box = try await Box.make(context(.development))
        let destructive = try box.plan("DELETE FROM t").statements
        await #expect(throws: RSKeeperError.confirmationRequired) {
            _ = try await box.session.executeScript(destructive, tab: box.tab, executionID: .generate())
        }
        let token = try await box.session.confirm(destructive, tab: box.tab)
        let outcome = try await box.session.executeScript(destructive, tab: box.tab, executionID: .generate(), confirmation: token)
        #expect(outcome.succeeded)
        // Replay com outro ExecutionID: token já consumido.
        await #expect(throws: RSKeeperError.confirmationRequired) {
            _ = try await box.session.executeScript(destructive, tab: box.tab, executionID: .generate(), confirmation: token)
        }
        await box.cleanup()
    }

    @Test("Token não vale para outra aba, outro digest (instrução ou parâmetro) nem depois de expirar")
    func tokenScope() async throws {
        let box = try await Box.make(context(.development), lifetime: .milliseconds(300))
        let delete = try box.plan("DELETE FROM t").statements
        let other = try box.plan("DROP TABLE t").statements

        let forOtherTab = try await box.session.confirm(delete, tab: TabID.generate())
        await #expect(throws: RSKeeperError.confirmationRequired) {
            _ = try await box.session.executeScript(delete, tab: box.tab, executionID: .generate(), confirmation: forOtherTab)
        }
        let forDelete = try await box.session.confirm(delete, tab: box.tab)
        await #expect(throws: RSKeeperError.confirmationRequired) {
            _ = try await box.session.executeScript(other, tab: box.tab, executionID: .generate(), confirmation: forDelete)
        }
        let paramA = [PlannedStatement(statement: BoundStatement(sql: "DELETE FROM t WHERE a = ? OR 1 = 1", bindings: [.int(1)]), risk: .destructive, sourceRange: 0..<1)]
        let paramB = [PlannedStatement(statement: BoundStatement(sql: "DELETE FROM t WHERE a = ? OR 1 = 1", bindings: [.int(2)]), risk: .destructive, sourceRange: 0..<1)]
        let forParamA = try await box.session.confirm(paramA, tab: box.tab)
        await #expect(throws: RSKeeperError.confirmationRequired) {
            _ = try await box.session.executeScript(paramB, tab: box.tab, executionID: .generate(), confirmation: forParamA)
        }
        let expiring = try await box.session.confirm(delete, tab: box.tab)
        try await Task.sleep(for: .milliseconds(400))
        await #expect(throws: RSKeeperError.confirmationRequired) {
            _ = try await box.session.executeScript(delete, tab: box.tab, executionID: .generate(), confirmation: expiring)
        }
        await box.cleanup()
    }

    @Test("Produção: destrutivo exige o nome digitado; escrita exige confirmação; somente leitura recusa antes")
    func production() async throws {
        let box = try await Box.make(context(.production))
        let delete = try box.plan("DELETE FROM t").statements
        await #expect(throws: RSKeeperError.self) { _ = try await box.session.confirm(delete, tab: box.tab, typedTargetName: "vendas prod") }
        await #expect(throws: RSKeeperError.self) { _ = try await box.session.confirm(delete, tab: box.tab) }
        let token = try await box.session.confirm(delete, tab: box.tab, typedTargetName: "Vendas Prod")
        #expect(try await box.session.executeScript(delete, tab: box.tab, executionID: .generate(), confirmation: token).succeeded)
        let insert = try box.plan("INSERT INTO t VALUES (2)").statements
        await #expect(throws: RSKeeperError.confirmationRequired) {
            _ = try await box.session.executeScript(insert, tab: box.tab, executionID: .generate())
        }
        #expect(await box.session.evaluate(try box.plan("SELECT 1; BEGIN; COMMIT").statements) == .allow)
        await box.cleanup()

        let readOnly = try await Box.make(OperationPolicyContext(environment: .local, readOnly: true, targetName: "x"))
        await #expect(throws: RSKeeperError.readOnly) {
            _ = try await readOnly.session.executeScript(readOnly.plan("INSERT INTO t VALUES (3)").statements, tab: readOnly.tab, executionID: .generate())
        }
        await readOnly.cleanup()
    }
}
