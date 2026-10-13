import RSKeeperDomain
import RSKeeperDriversCore

/// Sessão de banco: dona das conexões físicas de uma conexão aberta (docs/native/03 §9–§12).
///
/// - Uma execução ativa por aba (DR-20): a segunda é `.conflict(.busy)`, sem fila.
/// - Transação manual por aba usa conexão exclusiva; metadados e outras abas nunca a usam.
/// - Orçamento de conexões: esgotado → `.conflict(.connectionLimit)` imediato (DR-19).
/// - Deduplicação por `ExecutionID` (DR-06): repetir um ID terminal devolve o desfecho registrado.
/// - Fechar: cancelar → rollback → desconectar, nesta ordem (NT-CONC-04; divergência de U-07).
public actor DatabaseSession {
    public nonisolated let id: SessionID
    public nonisolated let window: WindowID
    public nonisolated let profileID: ProfileID

    private let factory: any DriverFactory
    private let target: ResolvedTarget
    private let options: OpenOptions
    private let maxConnections: Int

    private var idle: [any PhysicalConnection] = []
    private var openCount = 0
    private var busyTabs: Set<TabID> = []
    private var manualTransactions: [TabID: any PhysicalConnection] = [:]
    private var running: [ExecutionID: (tab: TabID, connection: any PhysicalConnection)] = [:]
    private var finished: [ExecutionID: Result<StatementOutcome, RSKeeperError>] = [:]
    private var finishedOrder: [ExecutionID] = []
    private let finishedCapacity: Int
    private var closed = false

    init(id: SessionID, window: WindowID, profileID: ProfileID, factory: any DriverFactory,
         target: ResolvedTarget, options: OpenOptions, maxConnections: Int, finishedCapacity: Int) {
        self.id = id
        self.window = window
        self.profileID = profileID
        self.factory = factory
        self.target = target
        self.options = options
        self.maxConnections = maxConnections
        self.finishedCapacity = finishedCapacity
    }

    /// Abre a primeira conexão (valida credenciais e alcance).
    func connect() async throws(RSKeeperError) {
        let connection = try await openConnection()
        idle.append(connection)
    }

    // MARK: Execução

    /// Executa uma instrução na aba. Nunca roda no MainActor (actor próprio).
    public func execute(_ statement: BoundStatement, tab: TabID, executionID: ExecutionID,
                        limits: ReadLimits = .default) async throws(RSKeeperError) -> StatementOutcome {
        guard !closed else { throw .notFound(.unknown) }
        if let previous = finished[executionID] { return try previous.get() }      // DR-06
        guard running[executionID] == nil else { throw .conflict(.duplicateID) }
        guard !busyTabs.contains(tab) else { throw .conflict(.busy) }               // DR-20
        busyTabs.insert(tab)
        defer { busyTabs.remove(tab) }

        let usesManualTransaction = manualTransactions[tab] != nil
        let lease: ConnectionLease
        if let transactionConnection = manualTransactions[tab] {
            lease = ConnectionLease(connection: transactionConnection, owner: .transaction(tab))
        } else {
            lease = try await acquire(owner: .execution(executionID))
        }
        let connection = lease.connection
        running[executionID] = (tab, connection)

        let result: Result<StatementOutcome, RSKeeperError>
        do {
            let outcome = try await withTaskCancellationHandler {
                try await connection.execute(statement, limits: limits)
            } onCancel: {
                let handle = connection.cancelHandle()
                Task { await handle?.cancel() }
            }
            result = .success(outcome)
        } catch let error as DriverError {
            result = .failure(error.applicationError)
        } catch is CancellationError {
            result = .failure(.cancelled)
        } catch {
            result = .failure(.internal(RedactedMessage(alreadyRedacted: "Falha inesperada na execução.")))
        }
        running[executionID] = nil

        if usesManualTransaction {
            _ = consume lease                       // a conexão continua presa à transação da aba
        } else {
            await release(lease, discard: isCancellation(result))
        }
        remember(executionID, result)
        return try result.get()
    }

    /// Cancela uma execução em curso pelo ID (o lease só é liberado depois que ela termina; DR-18).
    public func cancel(_ executionID: ExecutionID) async {
        guard let entry = running[executionID] else { return }
        await entry.connection.cancelHandle()?.cancel()
    }

    /// Desfecho registrado de uma execução terminal (DR-06), se ainda em memória.
    public func outcome(of executionID: ExecutionID) -> Result<StatementOutcome, RSKeeperError>? { finished[executionID] }

    public func isRunning(_ executionID: ExecutionID) -> Bool { running[executionID] != nil }

    // MARK: Transação manual por aba

    public func beginTransaction(tab: TabID) async throws(RSKeeperError) {
        guard !closed else { throw .notFound(.unknown) }
        guard manualTransactions[tab] == nil else { throw .conflict(.transactionActive) }
        guard !busyTabs.contains(tab) else { throw .conflict(.busy) }
        let lease = try await acquire(owner: .transaction(tab))
        let connection = lease.take()
        do {
            _ = try await connection.execute(BoundStatement(sql: "BEGIN"), limits: .default)
        } catch {
            await destroy(connection)
            throw error.applicationError
        }
        manualTransactions[tab] = connection
    }

    public func commit(tab: TabID) async throws(RSKeeperError) { try await finishTransaction(tab: tab, sql: "COMMIT") }

    public func rollback(tab: TabID) async throws(RSKeeperError) { try await finishTransaction(tab: tab, sql: "ROLLBACK") }

    public func hasTransaction(tab: TabID) -> Bool { manualTransactions[tab] != nil }

    private func finishTransaction(tab: TabID, sql: String) async throws(RSKeeperError) {
        guard let connection = manualTransactions[tab] else { throw .notFound(.unknown) }
        guard !busyTabs.contains(tab) else { throw .conflict(.busy) }               // commit conta como execução
        busyTabs.insert(tab)
        defer { busyTabs.remove(tab) }
        do {
            _ = try await connection.execute(BoundStatement(sql: sql), limits: .default)
        } catch {
            manualTransactions[tab] = nil
            await destroy(connection)
            // Falha no COMMIT: desfecho desconhecido, nunca sucesso presumido (DR-05/07).
            throw sql == "COMMIT" ? .outcomeUnknown(.connectionLost) : error.applicationError
        }
        manualTransactions[tab] = nil
        await release(ConnectionLease(connection: connection, owner: .transaction(tab)), discard: false)
    }

    // MARK: Encerramento

    /// Fecha a sessão: cancela execuções, desfaz transações manuais e desconecta, nesta ordem.
    public func close() async {
        guard !closed else { return }
        closed = true
        for (_, entry) in running { await entry.connection.cancelHandle()?.cancel() }
        await waitForRunningToFinish(timeout: .seconds(5))
        for (_, connection) in manualTransactions {
            try? await connection.resetSession()                                    // rollback (DR-17)
        }
        let all = idle + Array(manualTransactions.values) + running.values.map(\.connection)
        manualTransactions.removeAll()
        idle.removeAll()
        var seen: Set<ObjectIdentifier> = []
        for connection in all where seen.insert(ObjectIdentifier(connection)).inserted {
            await connection.close()
        }
        openCount = 0
    }

    public var isClosed: Bool { closed }

    /// Espera as execuções canceladas terminarem antes do rollback (ordem do NT-CONC-04).
    /// O actor é reentrante: enquanto esta função aguarda, `execute` retoma e remove a entrada.
    /// Estourado o prazo [META 5 s], segue o encerramento e as conexões são destruídas.
    private func waitForRunningToFinish(timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !running.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Pool

    private func acquire(owner: LeaseOwner) async throws(RSKeeperError) -> ConnectionLease {
        if let connection = idle.popLast() { return ConnectionLease(connection: connection, owner: owner) }
        guard openCount < maxConnections else { throw .conflict(.connectionLimit) }   // DR-19: sem fila
        return ConnectionLease(connection: try await openConnection(), owner: owner)
    }

    private func openConnection() async throws(RSKeeperError) -> any PhysicalConnection {
        openCount += 1
        do {
            return try await factory.open(target, options: options)
        } catch {
            openCount -= 1
            throw error.applicationError
        }
    }

    /// Devolve ao pool após `resetSession` (DR-17) ou destrói se o estado não for comprovadamente limpo.
    private func release(_ lease: consuming ConnectionLease, discard: Bool) async {
        let connection = lease.take()
        guard !closed, !discard else { await destroy(connection); return }
        do {
            try await connection.resetSession()
            idle.append(connection)
        } catch {
            await destroy(connection)
        }
    }

    private func destroy(_ connection: any PhysicalConnection) async {
        await connection.close()
        openCount = max(0, openCount - 1)
    }

    private func isCancellation(_ result: Result<StatementOutcome, RSKeeperError>) -> Bool {
        if case .failure(.cancelled) = result { return true }
        return false
    }

    private func remember(_ executionID: ExecutionID, _ result: Result<StatementOutcome, RSKeeperError>) {
        finished[executionID] = result
        finishedOrder.append(executionID)
        if finishedOrder.count > finishedCapacity {
            finished[finishedOrder.removeFirst()] = nil
        }
    }
}
