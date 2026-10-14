import Testing
@testable import RSKeeperApplication
import RSKeeperDomain
import RSKeeperDriversCore

/// NST-13-01 — registro único de comandos (W1-T11).
@Suite("Registro de comandos (W1-T11, NST-13-01)")
struct CommandRegistryTests {
    @Test("Cada comando declarado uma vez; nenhum atalho com dois donos")
    func uniqueness() {
        let ids = CommandRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(CommandRegistry.shortcutConflicts().isEmpty, "\(CommandRegistry.shortcutConflicts())")
        #expect(CommandRegistry.all.allSatisfy { !$0.title.isEmpty })
    }

    @Test("Atalhos do doc 10 §6.2: ⌘↩/F5, ⌘⇧↩/⇧F5, ⌘., ⌘⌥→/←, ⌃⌘S, ⌘⌥I, F6, ⌘⇧N")
    func shortcuts() {
        func symbols(_ id: CommandID) -> String { CommandRegistry.definition(id)?.shortcut?.description ?? "" }
        #expect(symbols(CommandRegistry.runAll) == "⌘↩")
        #expect(CommandRegistry.definition(CommandRegistry.runAll)?.alternateShortcut?.description == "F5")
        #expect(symbols(CommandRegistry.runCurrent) == "⇧⌘↩")
        #expect(CommandRegistry.definition(CommandRegistry.runCurrent)?.alternateShortcut?.description == "⇧F5")
        #expect(symbols(CommandRegistry.cancel) == "⌘.")
        #expect(symbols(CommandRegistry.nextPage) == "⌥⌘→")
        #expect(symbols(CommandRegistry.toggleSidebar) == "⌃⌘S")
        #expect(symbols(CommandRegistry.toggleInspector) == "⌥⌘I")
        #expect(symbols(CommandRegistry.nextRegion) == "F6")
        #expect(symbols(CommandRegistry.newConnection) == "⇧⌘N")
    }

    @Test("Habilitação pelo estado (crit. 1: comandos de conexão desabilitados sem conexão)")
    func enablement() {
        func enabled(_ id: CommandID, _ context: CommandContext) -> Bool { CommandRegistry.definition(id)!.isEnabled(context) }
        #expect(!enabled(CommandRegistry.disconnect, .none))
        #expect(!enabled(CommandRegistry.runAll, .none))
        #expect(enabled(CommandRegistry.newConnection, .none))
        let query = CommandContext(isConnected: true, activeTab: .query)
        #expect(enabled(CommandRegistry.runAll, query) && enabled(CommandRegistry.disconnect, query))
        #expect(!enabled(CommandRegistry.runCurrent, query), "entre instruções, Executar atual fica indisponível")
        #expect(enabled(CommandRegistry.runCurrent, CommandContext(isConnected: true, activeTab: .query, hasCurrentStatement: true)))
        #expect(!enabled(CommandRegistry.runSelection, query))
        var running = query
        running.isRunning = true
        #expect(!enabled(CommandRegistry.runAll, running) && enabled(CommandRegistry.cancel, running))
        #expect(!enabled(CommandRegistry.nextPage, query))
        #expect(enabled(CommandRegistry.nextPage, CommandContext(isConnected: true, activeTab: .table, canPageForward: true)))
    }

    @Test("A janela informa o contexto pelo estado da conexão")
    @MainActor
    func windowContext() {
        let sessions = SessionRegistry()
        let model = WindowModel(connectUseCase: ConnectUseCase(drivers: DriverRegistry([]), sessions: sessions, resolver: NoResolver()),
                                sessions: sessions)
        #expect(model.commandContext == .none)
    }
}

private struct NoResolver: TargetResolving {
    func resolve(_ profile: ConnectionProfile) async throws(RSKeeperError) -> ResolvedTarget { throw .cancelled }
}
