import Foundation
import Synchronization
import Testing
import RSKeeperApplication
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperTesting

/// Relógio manual para TTL.
final class ManualClock: Sendable {
    private let current = Mutex(ContinuousClock.now)
    func advance(_ duration: Duration) { current.withLock { $0 = $0 + duration } }
    var now: ContinuousClock.Instant { current.withLock { $0 } }
}

/// NST-07-03 (núcleo) — ResultStore: páginas, orçamento, LRU e expiração (W1-T09).
@Suite("ResultStore (W1-T09; DR-08/09/10)")
struct ResultStoreTests {
    private let columns = [ResultColumn(name: "id", nativeTypeName: "int8", portableType: .bigint),
                           ResultColumn(name: "nome", nativeTypeName: "text", portableType: .text)]

    private func batch(_ rows: Int, textSize: Int = 10) -> RowBatch {
        RowBatch(columns: [(0..<rows).map { .int(Int64($0)) }, (0..<rows).map { _ in .text(String(repeating: "x", count: textSize)) }])
    }

    @Test("Páginas por linhas e por bytes; hasMore; fora do intervalo é validação")
    func paging() async throws {
        var limits = ResultStore.Limits()
        limits.pageBytes = 1_000
        let store = ResultStore(limits: limits)
        let summary = await store.store(tab: .generate(), columns: columns, batch: batch(500), truncation: nil)
        let first = try await store.page(summary.id, offset: 0, limit: 10)
        #expect(first.rowCount == 10 && first.hasMore && first.columns[0].first == .int(0))
        let byBytes = try await store.page(summary.id, offset: 100, limit: 1_000)        // 18 bytes/linha → ~55 linhas
        #expect(byBytes.rowCount < 100 && byBytes.rowCount > 0 && byBytes.hasMore)
        let last = try await store.page(summary.id, offset: 495, limit: 10)
        #expect(last.rowCount == 5 && !last.hasMore)
        await #expect(throws: RSKeeperError.self) { _ = try await store.page(summary.id, offset: 501, limit: 1) }
    }

    @Test("Orçamento da janela: LRU despeja abas inativas, nunca a ativa; acesso ao despejado → .evicted")
    func windowBudget() async throws {
        var limits = ResultStore.Limits()
        limits.windowBytes = 30_000
        let store = ResultStore(limits: limits)
        let active = TabID.generate(), old = TabID.generate(), other = TabID.generate()
        await store.setActiveTab(active)
        let activeResult = await store.store(tab: active, columns: columns, batch: batch(1_000), truncation: nil)  // ~18 KB
        let oldResult = await store.store(tab: old, columns: columns, batch: batch(500), truncation: nil)          // ~9 KB
        _ = try await store.page(activeResult.id, offset: 0, limit: 1)                                              // ativa é a mais recente em uso
        let newest = await store.store(tab: other, columns: columns, batch: batch(500), truncation: nil)          // estoura → despeja a inativa mais antiga
        #expect(await store.storedBytes <= 30_000)
        await #expect(throws: RSKeeperError.notFound(.evicted)) { _ = try await store.summary(oldResult.id) }
        #expect(try await store.summary(activeResult.id).rowCount == 1_000)
        #expect(try await store.summary(newest.id).rowCount == 500)
    }

    @Test("TTL de 30 min sem acesso → .expired; acesso renova; nunca reexecuta (só responde)")
    func idleExpiry() async throws {
        let clock = ManualClock()
        let store = ResultStore(now: { clock.now })
        let tab = TabID.generate()
        let kept = await store.store(tab: tab, columns: columns, batch: batch(10), truncation: nil)
        let stale = await store.store(tab: TabID.generate(), columns: columns, batch: batch(10), truncation: nil)
        clock.advance(.seconds(20 * 60))
        _ = try await store.page(kept.id, offset: 0, limit: 1)
        clock.advance(.seconds(15 * 60))
        await #expect(throws: RSKeeperError.notFound(.expired)) { _ = try await store.summary(stale.id) }
        #expect(try await store.summary(kept.id).rowCount == 10)
    }

    @Test("Nova execução e fechamento da aba liberam os resultados dela; o orçamento do processo é devolvido")
    func releaseOnNewExecutionAndClose() async throws {
        let budget = ProcessResultBudget()
        let store = ResultStore(budget: budget)
        let tab = TabID.generate()
        let first = await store.store(tab: tab, columns: columns, batch: batch(100), truncation: nil)
        #expect(await budget.usedBytes == first.byteCount)
        await store.beginExecution(tab: tab)
        await #expect(throws: RSKeeperError.notFound(.unknown)) { _ = try await store.summary(first.id) }
        _ = await store.store(tab: tab, columns: columns, batch: batch(10), truncation: .maxRows(10))
        await store.release(tab: tab)
        #expect(await store.storedBytes == 0)
        #expect(await budget.usedBytes == 0)
    }

    @Test("Orçamento do processo: acima do teto, a próxima execução trunca mais cedo e avisa")
    func processBudget() async {
        let budget = ProcessResultBudget(limit: 100_000)
        let store = ResultStore(budget: budget)
        _ = await store.store(tab: .generate(), columns: columns, batch: batch(5_000), truncation: nil)  // ~90 KB
        let (limits, reduced) = await budget.limits(for: .default)
        #expect(reduced)
        #expect(limits.maxBytes < ReadLimits.default.maxBytes && limits.maxRows == ReadLimits.default.maxRows)
        let (fresh, notReduced) = await ProcessResultBudget().limits(for: .default)
        #expect(!notReduced && fresh.maxBytes == ReadLimits.default.maxBytes)
    }

    @Test("NT-PERF (núcleo): 50.000 × 50 guardado e paginado sem travar; memória perto do payload")
    func largeResult() async throws {
        let columns = (0..<50).map { ResultColumn(name: "c\($0)", nativeTypeName: "text", portableType: .text) }
        let rows = 50_000
        let batch = RowBatch(columns: (0..<50).map { column in (0..<rows).map { .text("v\($0 % 997)-\(column)") } })
        let before = MemoryProbe.footprint()
        let store = ResultStore()
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            let summary = await store.store(tab: .generate(), columns: columns, batch: batch, truncation: .maxRows(rows))
            for offset in stride(from: 0, to: rows, by: 5_000) { _ = try await store.page(summary.id, offset: offset, limit: 100) }
        }
        #expect(elapsed < .seconds(2), "guardar e paginar levou \(elapsed)")
        #expect(MemoryProbe.footprint() - before < 600 * 1024 * 1024)
    }
}
