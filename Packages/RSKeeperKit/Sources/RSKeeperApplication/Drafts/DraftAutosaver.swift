import RSKeeperDomain
import RSKeeperPersistence

/// Autosave de rascunhos (NST-01-05; 03 §15): grava o texto das abas [META 1 s] depois da última
/// edição e imediatamente em `flush()` (perda de foco, fechamento, `applicationWillTerminate`).
/// Com no máximo 1 s de perda, um encerramento forçado (`kill -9`) não perde a consulta.
public actor DraftAutosaver {
    private let repository: DraftRepository
    private let delay: Duration
    private var pending: [TabID: (tab: TabRecord, text: String, savedHash: [UInt8]?)] = [:]
    private var timers: [TabID: Task<Void, Never>] = [:]
    /// Último erro de gravação (a UI mostra "Rascunho não salvo" sem bloquear a edição).
    public private(set) var lastError: RSKeeperError?

    public init(repository: DraftRepository, delay: Duration = .seconds(1)) {
        self.repository = repository
        self.delay = delay
    }

    /// Texto mudou: agenda a gravação (cada edição reinicia o prazo da aba).
    public func textChanged(_ tab: TabRecord, text: String, savedTextHash: [UInt8]?) {
        pending[tab.id] = (tab, text, savedTextHash)
        timers[tab.id]?.cancel()
        let delay = self.delay
        timers[tab.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.write(tab.id)
        }
    }

    /// Grava tudo o que está pendente agora.
    public func flush() async {
        for id in Array(pending.keys) { await write(id) }
    }

    /// Aba fechada: descarta pendência e o registro de recuperação.
    public func tabClosed(_ tab: TabID) async {
        timers[tab]?.cancel()
        timers[tab] = nil
        pending[tab] = nil
        do { try await repository.remove(tab) } catch { lastError = error }
    }

    public var hasPending: Bool { !pending.isEmpty }

    private func write(_ id: TabID) async {
        timers[id] = nil
        guard let item = pending.removeValue(forKey: id) else { return }
        do {
            try await repository.save(item.tab, text: item.text, savedTextHash: item.savedHash)
            lastError = nil
        } catch {
            lastError = error
            if pending[id] == nil { pending[id] = item }          // tenta de novo no próximo flush
        }
    }
}
