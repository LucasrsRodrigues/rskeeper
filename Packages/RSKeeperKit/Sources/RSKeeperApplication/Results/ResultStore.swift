import RSKeeperDomain
import RSKeeperDriversCore

/// Resumo de um resultado guardado (03 §4.4).
public struct ResultSummary: Sendable, Hashable {
    public let id: ResultID
    public let tab: TabID
    public let columns: [ResultColumn]
    public let rowCount: Int
    public let truncation: TruncationReason?
    public let byteCount: Int
}

/// Página colunar (`columns[coluna][linha]`).
public struct ResultPage: Sendable, Hashable {
    public let offset: Int
    public let columns: [[CellValue]]
    public let hasMore: Bool
    public var rowCount: Int { columns.first?.count ?? 0 }
}

/// Orçamento de payload de resultados do processo inteiro [META 1,5 GiB], compartilhado pelas janelas.
/// Acima dele, novas execuções truncam mais cedo e avisam (03 §13).
public actor ProcessResultBudget {
    public let limit: Int
    private var used: [ResultID: Int] = [:]

    public init(limit: Int = 1_536 * 1024 * 1024) { self.limit = limit }

    public var usedBytes: Int { used.values.reduce(0, +) }

    /// Limites de leitura para a próxima execução: `maxBytes` nunca passa do que resta no processo.
    /// `reduced` = a UI avisa que o resultado pode vir truncado antes do normal.
    public func limits(for base: ReadLimits) -> (limits: ReadLimits, reduced: Bool) {
        let remaining = max(64 * 1024, limit - usedBytes)
        guard remaining < base.maxBytes else { return (base, false) }
        return (ReadLimits(maxRows: base.maxRows, maxBytes: remaining, maxCellBytes: base.maxCellBytes, deadline: base.deadline), true)
    }

    func charge(_ id: ResultID, _ bytes: Int) { used[id] = bytes }
    func refund(_ id: ResultID) { used[id] = nil }
}

/// Guarda os resultados de uma janela (NST-07-03; DR-08/09/10; ADR-N18).
///
/// - Páginas colunares, limitadas por bytes [META 2 MiB] (`hasMore`).
/// - Orçamento por janela [META 512 MiB]: despejo LRU de resultados de abas **inativas**, nunca da ativa.
/// - TTL [META 30 min sem acesso]; nova execução ou fechamento da aba liberam os resultados dela.
/// - Acesso a resultado liberado → `.notFound(.expired | .evicted)`. **Nunca reexecuta.**
public actor ResultStore {
    public struct Limits: Sendable {
        public var windowBytes = 512 * 1024 * 1024
        public var pageBytes = 2 * 1024 * 1024
        public var idleLifetime: Duration = .seconds(30 * 60)
        /// Quantos IDs liberados guardar para responder "expirado/despejado" em vez de "inexistente".
        public var tombstones = 2_000
        public init() {}
    }

    private struct Entry {
        let summary: ResultSummary
        let columns: [[CellValue]]
        var lastAccess: ContinuousClock.Instant
    }

    private let limits: Limits
    private let budget: ProcessResultBudget
    private let now: @Sendable () -> ContinuousClock.Instant
    private var entries: [ResultID: Entry] = [:]
    private var released: [ResultID: NotFoundReason] = [:]
    private var releasedOrder: [ResultID] = []
    private var activeTab: TabID?

    public init(limits: Limits = Limits(), budget: ProcessResultBudget = ProcessResultBudget(),
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.limits = limits
        self.budget = budget
        self.now = now
    }

    /// Aba visível: seus resultados nunca são despejados por LRU.
    public func setActiveTab(_ tab: TabID?) { activeTab = tab }

    public var storedBytes: Int { entries.values.reduce(0) { $0 + $1.summary.byteCount } }

    /// Nova execução na aba: libera os resultados anteriores dela (gatilho "nova execução").
    public func beginExecution(tab: TabID) async {
        for (id, entry) in entries where entry.summary.tab == tab { await drop(id, reason: .unknown) }
    }

    /// Guarda um conjunto de resultado e devolve o resumo. Aplica TTL e o orçamento da janela.
    public func store(tab: TabID, columns: [ResultColumn], batch: RowBatch, truncation: TruncationReason?) async -> ResultSummary {
        await expireIdle()
        let id = ResultID.generate()
        let bytes = batch.estimatedByteCount
        let summary = ResultSummary(id: id, tab: tab, columns: columns, rowCount: batch.rowCount, truncation: truncation, byteCount: bytes)
        entries[id] = Entry(summary: summary, columns: batch.columns, lastAccess: now())
        await budget.charge(id, bytes)
        await enforceWindowBudget(keeping: id)
        return summary
    }

    public func summary(_ id: ResultID) async throws(RSKeeperError) -> ResultSummary {
        await expireIdle()
        return try touch(id).summary
    }

    /// Página a partir de `offset`, com no máximo `limit` linhas e `pageBytes` bytes.
    public func page(_ id: ResultID, offset: Int, limit: Int) async throws(RSKeeperError) -> ResultPage {
        await expireIdle()
        let entry = try touch(id)
        let total = entry.summary.rowCount
        guard offset >= 0, offset <= total else { throw .validation(RedactedMessage(alreadyRedacted: "Página fora do resultado.")) }
        var end = min(total, offset + max(0, limit))
        var bytes = 0
        for row in offset..<end {
            let rowBytes = entry.columns.reduce(0) { $0 + $1[row].estimatedByteCount }
            if bytes + rowBytes > limits.pageBytes, row > offset { end = row; break }
            bytes += rowBytes
        }
        return ResultPage(offset: offset, columns: entry.columns.map { Array($0[offset..<end]) }, hasMore: end < total)
    }

    /// Descarte explícito ou fechamento da aba.
    public func release(tab: TabID) async {
        for (id, entry) in entries where entry.summary.tab == tab { await drop(id, reason: .unknown) }
    }

    /// Fechamento da janela: devolve todo o orçamento.
    public func releaseAll() async {
        for id in Array(entries.keys) { await drop(id, reason: .unknown) }
    }

    // MARK: Interno

    private func touch(_ id: ResultID) throws(RSKeeperError) -> Entry {
        guard var entry = entries[id] else { throw .notFound(released[id] ?? .unknown) }
        entry.lastAccess = now()
        entries[id] = entry
        return entry
    }

    private func expireIdle() async {
        let cutoff = now() - limits.idleLifetime
        for (id, entry) in entries where entry.lastAccess < cutoff { await drop(id, reason: .expired) }
    }

    /// LRU sobre abas inativas até caber no teto da janela. A aba ativa e o resultado recém-guardado ficam.
    private func enforceWindowBudget(keeping newest: ResultID) async {
        var used = storedBytes
        guard used > limits.windowBytes else { return }
        let candidates = entries.values
            .filter { $0.summary.id != newest && $0.summary.tab != activeTab }
            .sorted { $0.lastAccess < $1.lastAccess }
        for entry in candidates where used > limits.windowBytes {
            used -= entry.summary.byteCount
            await drop(entry.summary.id, reason: .evicted)
        }
    }

    private func drop(_ id: ResultID, reason: NotFoundReason) async {
        guard entries.removeValue(forKey: id) != nil else { return }
        await budget.refund(id)
        // "Inexistente" para descarte explícito; expirado/despejado são lembrados para a UI explicar.
        guard reason != .unknown else { return }
        released[id] = reason
        releasedOrder.append(id)
        if releasedOrder.count > limits.tombstones { released[releasedOrder.removeFirst()] = nil }
    }
}
