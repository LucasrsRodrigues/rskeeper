import AppKit
import Foundation
import Testing
@testable import RSKeeperFeatures
import RSKeeperApplication
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperDriverSQLite

/// NST-05-02 — a `NSOutlineView` do explorador fora da tela, sobre SQLite real (W1-T18).
@Suite("Explorador — árvore (W1-T18)", .serialized)
@MainActor
struct ExplorerOutlineTests {
    private func model() async throws -> (ExplorerModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rsk-outline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("t.db").path
        FileManager.default.createFile(atPath: path, contents: nil)
        let setup = try await SQLiteDriver().open(.file(path: path, readOnly: false), options: OpenOptions())
        _ = try await setup.execute(BoundStatement(sql: "CREATE TABLE pedidos (id INTEGER PRIMARY KEY, cliente TEXT)"), limits: .default)
        await setup.close()
        let registry = SessionRegistry()
        let window = WindowID.generate()
        let id = try await registry.open(window: window, profileID: .generate(), factory: SQLiteDriver(),
                                         target: .file(path: path, readOnly: false), policy: .init(environment: .local, readOnly: false, targetName: "t"))
        let session = try await registry.session(id, for: window)
        return (ExplorerModel(service: ExplorerService(session: session)) { _ in }, directory)
    }

    @Test("Expandir a tabela carrega e mostra as colunas")
    func expandShowsColumns() async throws {
        let (model, directory) = try await model()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.load()
        let outline = ExplorerOutline(model: model)
        let coordinator = outline.makeCoordinator()
        let view = NSOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        view.addTableColumn(column)
        view.outlineTableColumn = column
        view.dataSource = coordinator
        view.delegate = coordinator
        coordinator.outline = view
        coordinator.reloadIfNeeded(revision: model.revision, filter: model.filter)
        #expect(view.numberOfRows == 2, "main expandido com pedidos")
        let entityNode = try #require(view.item(atRow: 1) as? ExplorerNode)
        view.expandItem(entityNode)
        for _ in 0..<50 where view.numberOfRows < 4 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(view.numberOfRows == 4, "pedidos expandido com id e cliente; linhas: \(view.numberOfRows)")
    }
}
