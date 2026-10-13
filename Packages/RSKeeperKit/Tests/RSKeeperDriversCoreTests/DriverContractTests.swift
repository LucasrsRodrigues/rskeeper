import Testing
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperTesting

@Suite("DriversCore — contratos e driver em memória (W0-T18)")
struct DriverContractTests {
    private let target = ResolvedTarget.server(host: "memoria", port: 1, user: nil, password: SecretValue("s3nh@"), database: nil)

    @Test("Abrir, executar (resposta fixa) e fechar")
    func openExecuteClose() async throws {
        let rows = StatementOutcome.rows(columns: [ResultColumn(name: "n", nativeTypeName: "int", portableType: .int)],
                                         firstBatch: RowBatch(rows: [[.int(1)], [.int(2)]], columnCount: 1),
                                         truncated: nil, rowCount: 2)
        let log = InMemoryDriverLog()
        let driver = InMemoryDriver(script: .init(responses: ["SELECT n": rows]), log: log)
        let connection = try await driver.open(target, options: OpenOptions())
        guard case .rows(_, let batch, nil, 2) = try await connection.execute(BoundStatement(sql: "SELECT n"), limits: .default) else {
            Issue.record("resposta inesperada"); return
        }
        #expect(batch.columns == [[.int(1), .int(2)]])
        await connection.close()
        #expect(await log.events == [.opened, .executed("SELECT n"), .closed])
    }

    @Test("maxRows é aplicado e marca truncamento")
    func maxRowsTruncates() async throws {
        let many = RowBatch(rows: (0..<10).map { [.int(Int64($0))] }, columnCount: 1)
        let rows = StatementOutcome.rows(columns: [], firstBatch: many, truncated: nil, rowCount: 10)
        let connection = try await InMemoryDriver(script: .init(responses: ["q": rows])).open(target, options: OpenOptions())
        let limits = ReadLimits(maxRows: 3, maxBytes: 1024, maxCellBytes: 64)
        guard case .rows(_, let batch, .maxRows(3), 3) = try await connection.execute(BoundStatement(sql: "q"), limits: limits) else {
            Issue.record("esperado truncamento"); return
        }
        #expect(batch.rowCount == 3)
    }

    @Test("Cancelar a Task cancela a execução no fake (cooperativo)")
    func cancellationIsCooperative() async throws {
        let log = InMemoryDriverLog()
        let connection = try await InMemoryDriver(script: .init(delay: .seconds(30)), log: log).open(target, options: OpenOptions())
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { try await connection.execute(BoundStatement(sql: "SELECT pg_sleep(30)"), limits: .default) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: DriverError.cancelled) { _ = try await task.value }
        #expect(clock.now - start < .seconds(2))
        #expect(await log.events.contains(.cancelled("SELECT pg_sleep(30)")))
    }

    @Test("A alça de cancelamento interrompe a execução em curso")
    func cancelHandleInterrupts() async throws {
        let connection = try await InMemoryDriver(script: .init(delay: .seconds(30))).open(target, options: OpenOptions())
        let task = Task { try await connection.execute(BoundStatement(sql: "longa"), limits: .default) }
        try await Task.sleep(for: .milliseconds(50))
        await connection.cancelHandle()?.cancel()
        await #expect(throws: DriverError.cancelled) { _ = try await task.value }
    }

    @Test("Uma segunda execução simultânea na mesma conexão é .busy")
    func secondExecutionIsBusy() async throws {
        let connection = try await InMemoryDriver(script: .init(delay: .milliseconds(300))).open(target, options: OpenOptions())
        let first = Task { try await connection.execute(BoundStatement(sql: "a"), limits: .default) }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: DriverError.busy) { _ = try await connection.execute(BoundStatement(sql: "b"), limits: .default) }
        _ = try await first.value
    }

    @Test("resetSession desfaz transação aberta (DR-17)")
    func resetRollsBackOpenTransaction() async throws {
        let log = InMemoryDriverLog()
        let connection = try await InMemoryDriver(log: log).open(target, options: OpenOptions())
        _ = try await connection.execute(BoundStatement(sql: "BEGIN"), limits: .default)
        #expect(await connection.transactionState() == .inTransaction)
        try await connection.resetSession()
        #expect(await connection.transactionState() == .idle)
        #expect(await log.events.suffix(2) == [.rolledBack, .reset])
    }

    @Test("SecretValue nunca aparece em description")
    func secretValueIsOpaque() {
        let secret = SecretValue("s3nh@")
        #expect("\(secret)" == "<secret>")
        #expect(String(reflecting: secret) == "<secret>")
        #expect(secret.reveal() == "s3nh@")
    }

    @Test("Dialeto ANSI duplica aspas, rejeita NUL e qualifica parte a parte")
    func ansiQuoting() throws {
        let dialect = ANSIDialect()
        #expect(try dialect.quoteIdentifier(#"a"b"#) == #""a""b""#)
        #expect(throws: DriverError.self) { try dialect.quoteIdentifier("a\u{0}b") }
        let ref = EntityRef(schema: SchemaRef(database: nil, name: "Public"), name: "Tabela.X")
        #expect(try dialect.qualified(ref) == #""Public"."Tabela.X""#)
    }

    @Test("Erros de driver mapeiam para RSKeeperError redigido (NST-01-01 crit. 2)")
    func driverErrorMapping() {
        #expect(DriverError.readOnly.applicationError == .readOnly)
        #expect(DriverError.busy.applicationError == .conflict(.busy))
        #expect(DriverError.outcomeUnknown(phase: .commit).applicationError == .outcomeUnknown(.cancelledDuringCommit))
        let message = RedactedMessage(alreadyRedacted: "duplicada")
        #expect(DriverError.driver(code: "23505", message).applicationError == .driver(code: "23505", message: message))
        #expect(CancelMode.killSession.discardsTransaction)
        #expect(!CancelMode.server.discardsTransaction)
    }
}
