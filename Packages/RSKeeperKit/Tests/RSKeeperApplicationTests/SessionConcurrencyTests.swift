import Testing
import RSKeeperDomain
import RSKeeperDriversCore
@testable import RSKeeperApplication
import RSKeeperTesting

private let target = ResolvedTarget.server(host: "memoria", port: 1, user: nil, password: nil, database: nil)

private func openSession(_ registry: SessionRegistry, window: WindowID, driver: InMemoryDriver) async throws -> DatabaseSession {
    let id = try await registry.open(window: window, profileID: .generate(), factory: driver, target: target, policy: .init(environment: .local, readOnly: false, targetName: "teste"))
    return try await registry.session(id, for: window)
}

@Suite("Sessões — concorrência (NT-CONC-02/04/05)")
struct SessionConcurrencyTests {
    @Test("NT-CONC-02: segunda execução na mesma aba é recusada como ocupada; outra aba roda")
    func secondExecutionInSameTabIsBusy() async throws {
        let registry = SessionRegistry()
        let session = try await openSession(registry, window: .generate(), driver: InMemoryDriver(script: .init(delay: .milliseconds(400))))
        let tab = TabID.generate()
        let first = Task { try await session.execute(BoundStatement(sql: "SELECT 1"), tab: tab, executionID: .generate()) }
        try await Task.sleep(for: .milliseconds(80))
        await #expect(throws: RSKeeperError.conflict(.busy)) {
            _ = try await session.execute(BoundStatement(sql: "SELECT 2"), tab: tab, executionID: .generate())
        }
        // Outra aba não é bloqueada.
        _ = try await session.execute(BoundStatement(sql: "SELECT 3"), tab: .generate(), executionID: .generate())
        _ = try await first.value
    }

    @Test("NT-CONC-02: commit conta como execução na aba")
    func commitCountsAsExecution() async throws {
        let registry = SessionRegistry()
        let session = try await openSession(registry, window: .generate(), driver: InMemoryDriver(script: .init(delay: .milliseconds(300))))
        let tab = TabID.generate()
        try await session.beginTransaction(tab: tab)
        let running = Task { try await session.execute(BoundStatement(sql: "UPDATE t SET x = 1"), tab: tab, executionID: .generate()) }
        try await Task.sleep(for: .milliseconds(80))
        await #expect(throws: RSKeeperError.conflict(.busy)) { try await session.commit(tab: tab) }
        _ = try await running.value
        try await session.commit(tab: tab)
        #expect(await session.hasTransaction(tab: tab) == false)
    }

    @Test("NT-CONC-04: fechar a janela cancela, faz rollback e desconecta, nesta ordem")
    func closingWindowCancelsRollsBackDisconnects() async throws {
        let log = InMemoryDriverLog()
        let registry = SessionRegistry()
        let window = WindowID.generate()
        let session = try await openSession(registry, window: window, driver: InMemoryDriver(script: .init(delay: .milliseconds(200)), log: log))
        let transactionTab = TabID.generate()
        try await session.beginTransaction(tab: transactionTab)                // BEGIN leva 200 ms
        let longRunning = Task {
            try await session.execute(BoundStatement(sql: "SELECT longa"), tab: .generate(), executionID: .generate())
        }
        try await Task.sleep(for: .milliseconds(60))
        await registry.closeWindow(window)
        await #expect(throws: RSKeeperError.self) { _ = try await longRunning.value }

        let events = await log.events
        // A conexão da transação é a que recebeu o rollback; ela só pode fechar depois dele.
        let rollbackIndex = try #require(events.firstIndex { if case .rolledBack = $0 { true } else { false } })
        guard case .rolledBack(let transactionConnection) = events[rollbackIndex] else { return }
        let cancelIndex = try #require(events.firstIndex(of: .cancelled("SELECT longa")))
        let transactionClose = try #require(events.firstIndex(of: .closed(transactionConnection)))
        #expect(cancelIndex < rollbackIndex, "cancelar antes do rollback")
        #expect(rollbackIndex < transactionClose, "rollback antes de desconectar")
        let opened = events.filter { if case .opened = $0 { true } else { false } }.count
        let closed = events.filter { if case .closed = $0 { true } else { false } }.count
        #expect(opened == closed, "toda conexão aberta foi fechada")
        #expect(await registry.openSessionCount == 0)
        #expect(await session.isClosed)
    }

    @Test("NT-CONC-05: sessão de uma janela não é acessível pela outra")
    func sessionsAreScopedByWindow() async throws {
        let registry = SessionRegistry()
        let windowA = WindowID.generate()
        let windowB = WindowID.generate()
        let id = try await registry.open(window: windowA, profileID: .generate(), factory: InMemoryDriver(), target: target, policy: .init(environment: .local, readOnly: false, targetName: "teste"))
        await #expect(throws: RSKeeperError.notFound(.otherWindow)) { _ = try await registry.session(id, for: windowB) }
        #expect(await registry.sessions(of: windowB).isEmpty)
        await registry.closeWindow(windowB)                                   // não afeta A
        #expect(await registry.sessions(of: windowA) == [id])
        await #expect(throws: RSKeeperError.notFound(.otherWindow)) { try await registry.close(id, for: windowB) }
    }

    @Test("DR-06: repetir um ExecutionID terminal devolve o desfecho, sem executar de novo")
    func executionIDDeduplication() async throws {
        let log = InMemoryDriverLog()
        let registry = SessionRegistry()
        let session = try await openSession(registry, window: .generate(), driver: InMemoryDriver(log: log))
        let executionID = ExecutionID.generate()
        let tab = TabID.generate()
        _ = try await session.execute(BoundStatement(sql: "INSERT 1"), tab: tab, executionID: executionID)
        _ = try await session.execute(BoundStatement(sql: "INSERT 1"), tab: tab, executionID: executionID)
        #expect(await log.events.filter { $0 == .executed("INSERT 1") }.count == 1)
    }

    @Test("DR-19: orçamento de conexões esgotado falha na hora, sem fila")
    func connectionBudgetFailsFast() async throws {
        let registry = SessionRegistry(limits: .init(maxConnectionsPerSession: 1))
        let session = try await openSession(registry, window: .generate(), driver: InMemoryDriver(script: .init(delay: .milliseconds(300))))
        let first = Task { try await session.execute(BoundStatement(sql: "a"), tab: .generate(), executionID: .generate()) }
        try await Task.sleep(for: .milliseconds(80))
        await #expect(throws: RSKeeperError.conflict(.connectionLimit)) {
            _ = try await session.execute(BoundStatement(sql: "b"), tab: .generate(), executionID: .generate())
        }
        _ = try await first.value
    }

    @Test("Falha ao conectar não deixa sessão registrada")
    func failedOpenLeavesNoSession() async throws {
        let registry = SessionRegistry()
        let driver = InMemoryDriver(script: .init(failOpen: .authentication))
        await #expect(throws: RSKeeperError.self) {
            _ = try await registry.open(window: .generate(), profileID: .generate(), factory: driver, target: target, policy: .init(environment: .local, readOnly: false, targetName: "teste"))
        }
        #expect(await registry.openSessionCount == 0)
    }

    @Test("Conexão de execução cancelada é destruída, não devolvida ao pool (AR-MEM-08)")
    func cancelledConnectionIsDiscarded() async throws {
        let log = InMemoryDriverLog()
        let registry = SessionRegistry()
        let session = try await openSession(registry, window: .generate(), driver: InMemoryDriver(script: .init(delay: .seconds(10)), log: log))
        let executionID = ExecutionID.generate()
        let task = Task { try await session.execute(BoundStatement(sql: "SELECT longa"), tab: .generate(), executionID: executionID) }
        try await Task.sleep(for: .milliseconds(60))
        await session.cancel(executionID)
        await #expect(throws: RSKeeperError.cancelled) { _ = try await task.value }
        #expect(await log.events.contains { if case .closed = $0 { true } else { false } })
        #expect(await session.isRunning(executionID) == false)
    }
}
