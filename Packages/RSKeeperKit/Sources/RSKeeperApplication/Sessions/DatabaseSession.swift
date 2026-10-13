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
    private var finishedScripts: [ExecutionID: ScriptOutcome] = [:]
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
        // A instrução leva o ID da execução: o driver marca o envio e a alça cancela só esta (DR-18).
        let statement = BoundStatement(sql: statement.sql, bindings: statement.bindings, executionID: executionID)

        let result: Result<StatementOutcome, RSKeeperError>
        do {
            let outcome = try await withTaskCancellationHandler {
                try await connection.execute(statement, limits: limits)
            } onCancel: {
                let handle = connection.cancelHandle(for: executionID)
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
        await entry.connection.cancelHandle(for: executionID)?.cancel()
    }

    // MARK: Scripts (NST-07-02; DR-13)

    /// Executa as instruções em ordem, numa única conexão, e **para na primeira falha**.
    ///
    /// - Cada instrução recebe `status` e `committed` (sim, não ou desconhecido), conforme o estado
    ///   de transação observado depois dela.
    /// - Em modo Auto, uma transação deixada aberta pelo script é desfeita na devolução, com aviso.
    /// - Repetir o mesmo `ExecutionID` devolve o desfecho registrado, sem reexecutar (DR-06).
    public func executeScript(_ statements: [PlannedStatement], tab: TabID, executionID: ExecutionID,
                              limits: ReadLimits = .default) async throws(RSKeeperError) -> ScriptOutcome {
        guard !closed else { throw .notFound(.unknown) }
        if let previous = finishedScripts[executionID] { return previous }
        guard running[executionID] == nil else { throw .conflict(.duplicateID) }
        guard !statements.isEmpty else { throw .validation(RedactedMessage(alreadyRedacted: "Nenhuma instrução para executar.")) }
        guard !busyTabs.contains(tab) else { throw .conflict(.busy) }               // DR-20
        busyTabs.insert(tab)
        defer { busyTabs.remove(tab) }

        let manual = manualTransactions[tab] != nil
        let lease: ConnectionLease
        if let transactionConnection = manualTransactions[tab] {
            lease = ConnectionLease(connection: transactionConnection, owner: .transaction(tab))
        } else {
            lease = try await acquire(owner: .execution(executionID))
        }
        let connection = lease.connection
        running[executionID] = (tab, connection)

        var reports: [StatementReport] = []
        var outcomes: [StatementOutcome?] = []
        /// Instruções cujas alterações estão numa transação ainda aberta: decididas no fim.
        var pending: Set<Int> = []
        var stop = false
        var cancelled = false
        var lostConnection = false
        for (index, planned) in statements.enumerated() {
            if stop {
                reports.append(StatementReport(index: index, risk: planned.risk, status: .skipped, committed: .no))
                outcomes.append(nil)
                continue
            }
            let statement = BoundStatement(sql: planned.statement.sql, bindings: planned.statement.bindings, executionID: executionID)
            do {
                let outcome = try await withTaskCancellationHandler {
                    try await connection.execute(statement, limits: limits)
                } onCancel: {
                    let handle = connection.cancelHandle(for: executionID)
                    Task { await handle?.cancel() }
                }
                let affected: Int? = if case .affected(let count) = outcome { count } else { nil }
                let committed = await commitState(after: planned.risk, on: connection, manual: manual)
                reports.append(StatementReport(index: index, risk: planned.risk, status: .ok, committed: committed ?? .no,
                                               affectedRows: affected))
                if committed == nil {
                    pending.insert(index)
                } else if !pending.isEmpty, !manual {
                    // A transação aberta pelo script acabou de fechar: COMMIT efetiva as pendentes; ROLLBACK as desfaz.
                    let effective: CommitState = Self.endsByRollback(planned.statement.sql) ? .no : .yes
                    for pendingIndex in pending {
                        let old = reports[pendingIndex]
                        reports[pendingIndex] = StatementReport(index: old.index, risk: old.risk, status: old.status,
                                                                committed: effective, affectedRows: old.affectedRows)
                    }
                    pending.removeAll()
                }
                outcomes.append(outcome)
            } catch {
                let failure = DriverError.normalized(error)
                stop = true
                if case .cancelled = failure { cancelled = true }
                if case .connection = failure { lostConnection = true }
                let status: StatementStatus = cancelled ? .cancelled : .failed(failure.applicationError)
                // Queda de conexão no meio de uma escrita: não dá para saber se efetivou (DR-05/07).
                let committed: CommitState = lostConnection && planned.risk != .read ? .unknown : .no
                reports.append(StatementReport(index: index, risk: planned.risk, status: status, committed: committed))
                outcomes.append(nil)
            }
        }
        running[executionID] = nil

        var rolledBack = false
        if !manual, !lostConnection, await connection.transactionState() != .idle {
            // Modo Auto: transação aberta pelo script é desfeita na devolução (DR-17), com aviso.
            rolledBack = true
        }
        // Pendentes que sobraram: a transação continuou aberta até o fim (desfeita) ou caiu junto com a conexão.
        for pendingIndex in pending {
            let old = reports[pendingIndex]
            reports[pendingIndex] = StatementReport(index: old.index, risk: old.risk, status: old.status,
                                                    committed: lostConnection ? .unknown : .no, affectedRows: old.affectedRows)
        }
        if manual {
            _ = consume lease
        } else {
            await release(lease, discard: cancelled || lostConnection)
        }
        let result = ScriptOutcome(reports: reports, outcomes: outcomes, autoRolledBackTransaction: rolledBack)
        rememberScript(executionID, result)
        return result
    }

    /// `ROLLBACK`/`ABORT` encerram desfazendo; `ROLLBACK TO SAVEPOINT` não encerra a transação.
    private static func endsByRollback(_ sql: String) -> Bool {
        let words = sql.uppercased().split(whereSeparator: { $0.isWhitespace || $0 == ";" }).prefix(2).map(String.init)
        guard let first = words.first, first == "ROLLBACK" || first == "ABORT" else { return false }
        return words.count < 2 || words[1] != "TO"
    }

    /// `nil` = pendente (transação aberta pelo script; decidido quando ela fechar).
    private func commitState(after risk: StatementRisk, on connection: any PhysicalConnection, manual: Bool) async -> CommitState? {
        if risk == .read { return .no }                                              // nada a efetivar
        if manual { return .no }                                                     // efetiva só no COMMIT da aba
        return await connection.transactionState() == .idle ? .yes : nil
    }

    public func scriptOutcome(of executionID: ExecutionID) -> ScriptOutcome? { finishedScripts[executionID] }

    private func rememberScript(_ executionID: ExecutionID, _ outcome: ScriptOutcome) {
        finishedScripts[executionID] = outcome
        finishedOrder.append(executionID)
        if finishedOrder.count > finishedCapacity {
            let evicted = finishedOrder.removeFirst()
            finished[evicted] = nil
            finishedScripts[evicted] = nil
        }
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
        for (executionID, entry) in running { await entry.connection.cancelHandle(for: executionID)?.cancel() }
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
            let evicted = finishedOrder.removeFirst()
            finished[evicted] = nil
            finishedScripts[evicted] = nil
        }
    }
}
