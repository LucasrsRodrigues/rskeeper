import Foundation
import Testing
import RSKeeperDomain
import RSKeeperDriversCore
@testable import RSKeeperApplication
import RSKeeperTesting

private struct FixedResolver: TargetResolving {
    func resolve(_ profile: ConnectionProfile) async throws(RSKeeperError) -> ResolvedTarget {
        .server(host: "memoria", port: 1, user: nil, password: nil, database: nil)
    }
}

/// O driver em memória usa o id "inmemory"; o perfil de teste aponta para ele.
private func profile() -> ConnectionProfile {
    ConnectionProfile(name: "Memória", driverID: DriverID(rawValue: "inmemory"),
                      target: .server(host: "memoria", port: 1, user: nil, password: nil))
}

@Suite("Aplicação — retry (NT-UNIT-10)")
struct RetryPolicyTests {
    private let lost = RSKeeperError.connection(RedactedMessage(alreadyRedacted: "socket fechado"))

    @Test("Leitura idempotente repete no máximo uma vez, só em erro transitório")
    func idempotentReadRetriesOnce() {
        #expect(RetryPolicy.decide(.metadataRead, error: lost, attempts: 1, sentToServer: true) == .retryOnce)
        #expect(RetryPolicy.decide(.metadataRead, error: lost, attempts: 2, sentToServer: true) == .fail(lost))
        #expect(RetryPolicy.decide(.pageRead, error: .timeout, attempts: 1, sentToServer: true) == .retryOnce)
        #expect(RetryPolicy.decide(.execute(risk: .read), error: .readOnly, attempts: 1, sentToServer: true) == .fail(.readOnly))
    }

    @Test("Escrita nunca repete; perda após envio vira desfecho desconhecido")
    func writesNeverRetry() {
        for operation: RetryPolicy.Operation in [.execute(risk: .write), .execute(risk: .destructive), .applyChanges, .ddl, .commit] {
            #expect(RetryPolicy.decide(operation, error: lost, attempts: 1, sentToServer: true) == .outcomeUnknown(.connectionLost))
            #expect(RetryPolicy.decide(operation, error: .timeout, attempts: 1, sentToServer: true) == .outcomeUnknown(.timeoutAfterSend))
            #expect(RetryPolicy.decide(operation, error: lost, attempts: 1, sentToServer: false) == .fail(lost))
        }
        #expect(RetryPolicy.decide(.commit, error: .cancelled, attempts: 1, sentToServer: true) == .outcomeUnknown(.cancelledDuringCommit))
    }
}

@Suite("Aplicação — conectar e estado observável (NT-CONC-01/03)")
struct ApplicationLayerTests {
    @Test("Fluxo conectar fim a fim com o fake, sem UI")
    @MainActor
    func connectEndToEnd() async throws {
        let sessions = SessionRegistry()
        let useCase = ConnectUseCase(drivers: DriverRegistry([InMemoryDriver()]), sessions: sessions, resolver: FixedResolver())
        let model = WindowModel(connectUseCase: useCase, sessions: sessions)
        let p = profile()
        model.connect(p)
        #expect(model.status == .connecting(p.id))
        await model.waitForConnection()
        guard case .connected(let sessionID, p.id) = model.status else { Issue.record("status: \(model.status)"); return }
        #expect(try await sessions.session(sessionID, for: model.windowID).profileID == p.id)
        #expect(model.stateUpdates == 2)                    // connecting → connected: uma atribuição por transição
        await model.closeWindow()
        #expect(await sessions.openSessionCount == 0)
    }

    @Test("Aceite 1: cancelar a Task cancela a operação no fake (abertura lenta)")
    @MainActor
    func cancellingConnectCancelsInDriver() async throws {
        let sessions = SessionRegistry()
        let driver = InMemoryDriver(script: .init(openDelay: .seconds(10)))
        let model = WindowModel(connectUseCase: ConnectUseCase(drivers: DriverRegistry([driver]), sessions: sessions, resolver: FixedResolver()),
                                sessions: sessions)
        let clock = ContinuousClock()
        let start = clock.now
        model.connect(profile())
        try await Task.sleep(for: .milliseconds(50))
        model.cancelConnect()
        #expect(model.status == .disconnected)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await sessions.openSessionCount == 0)
        #expect(clock.now - start < .seconds(2))
    }

    @Test("Driver desconhecido falha com .unsupported e perfil inválido com .validation")
    func connectValidation() async {
        let sessions = SessionRegistry()
        let useCase = ConnectUseCase(drivers: DriverRegistry([InMemoryDriver()]), sessions: sessions, resolver: FixedResolver())
        var unknown = profile()
        unknown.driverID = .postgresql
        await #expect(throws: RSKeeperError.self) { _ = try await useCase.connect(unknown, window: .generate()) }
        var invalid = profile()
        invalid.target = .server(host: "memoria", port: 0, user: nil, password: nil)
        do {
            _ = try await useCase.connect(invalid, window: .generate())
            Issue.record("esperado erro de validação")
        } catch {
            if case .validation = error {} else { Issue.record("erro inesperado: \(error)") }
        }
    }

    @Test("NT-CONC-01: operações de sessão terminam com o MainActor bloqueado")
    func sessionOperationsDoNotNeedMainActor() async throws {
        let sessions = SessionRegistry()
        let useCase = ConnectUseCase(drivers: DriverRegistry([InMemoryDriver(script: .init(delay: .milliseconds(20)))]),
                                     sessions: sessions, resolver: FixedResolver())
        let window = WindowID.generate()
        let mainBlocked = Task { @MainActor in
            blockCurrentThread(seconds: 1.5)                  // bloqueio artificial, só em teste
        }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let start = clock.now
        let sessionID = try await useCase.connect(profile(), window: window)
        let session = try await sessions.session(sessionID, for: window)
        for _ in 0..<5 {
            _ = try await session.execute(BoundStatement(sql: "SELECT 1"), tab: .generate(), executionID: .generate())
        }
        await sessions.closeWindow(window)
        let elapsed = clock.now - start
        #expect(elapsed < .milliseconds(1_200), "terminou em \(elapsed) com o MainActor bloqueado")
        await mainBlocked.value
    }

    @Test("NT-CONC-03: cancelar antes, durante e depois — desfecho coerente e sem vazamento de conexão")
    func cancellationRaces() async throws {
        let log = InMemoryDriverLog()
        let sessions = SessionRegistry(limits: .init(maxConnectionsPerSession: 2))
        let window = WindowID.generate()
        let id = try await sessions.open(window: window, profileID: .generate(),
                                         factory: InMemoryDriver(script: .init(delay: .milliseconds(150)), log: log),
                                         target: .server(host: "m", port: 1, user: nil, password: nil, database: nil),
                                         policy: .init(environment: .local, readOnly: false, targetName: "teste"))
        let session = try await sessions.session(id, for: window)
        let tab = TabID.generate()

        // Antes de começar: a Task já nasce cancelada.
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.execute(BoundStatement(sql: "antes"), tab: tab, executionID: .generate())
        }
        await #expect(throws: RSKeeperError.cancelled) { _ = try await before.value }

        // Durante.
        let during = Task { try await session.execute(BoundStatement(sql: "durante"), tab: tab, executionID: .generate()) }
        try await Task.sleep(for: .milliseconds(40))
        during.cancel()
        await #expect(throws: RSKeeperError.cancelled) { _ = try await during.value }

        // Depois de concluir: cancelar não muda o desfecho registrado.
        let afterID = ExecutionID.generate()
        let after = Task { try await session.execute(BoundStatement(sql: "depois"), tab: tab, executionID: afterID) }
        _ = try await after.value
        after.cancel()
        await session.cancel(afterID)
        guard case .success = await session.outcome(of: afterID) else { Issue.record("desfecho deveria ser sucesso"); return }

        // Nenhum lease vazou: duas execuções simultâneas cabem no orçamento de 2.
        async let a = session.execute(BoundStatement(sql: "x"), tab: .generate(), executionID: .generate())
        async let b = session.execute(BoundStatement(sql: "y"), tab: .generate(), executionID: .generate())
        _ = try await (a, b)
        await sessions.closeWindow(window)
        let events = await log.events
        let opened = events.filter { if case .opened = $0 { true } else { false } }.count
        let closed = events.filter { if case .closed = $0 { true } else { false } }.count
        #expect(opened == closed, "toda conexão aberta foi fechada (\(opened) abertas, \(closed) fechadas)")
    }
}

/// Bloqueia a thread atual de forma síncrona (só para simular o MainActor ocupado no NT-CONC-01).
private func blockCurrentThread(seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}
