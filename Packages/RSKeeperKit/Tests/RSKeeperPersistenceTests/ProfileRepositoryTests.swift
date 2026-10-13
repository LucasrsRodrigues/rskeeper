import Foundation
import Testing
import RSKeeperDomain
@testable import RSKeeperPersistence
import RSKeeperSecurity

/// NST-02-03 — repositório de perfis, pastas e fixadas (W1-T06).
@Suite("Repositório de perfis (W1-T06, NST-02-03)", .serialized)
struct ProfileRepositoryTests {
    private struct Box {
        let base: URL
        let database: AppDatabase
        let repository: ProfileRepository
        static func make() async throws -> Box {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rsk-repo-\(UUID().uuidString)")
            let database = try await MigrationRunner(root: DataRoot(url: base.appendingPathComponent("root")), appVersion: "0.0.1").open()
            return Box(base: base, database: database, repository: ProfileRepository(database: database))
        }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    private func sqlite(_ name: String, folder: FolderID? = nil) -> ConnectionProfile {
        let grant = FileGrant(id: UUID(), displayPath: "/tmp/\(name).db")
        return ConnectionProfile(name: name, driverID: .sqlite, folderID: folder, target: .file(grant, openMode: .readWrite))
    }

    private func postgres(_ name: String) -> ConnectionProfile {
        ConnectionProfile(name: name, driverID: .postgresql, labelColor: .teal, environment: .production, environmentConfirmed: true,
                          target: .server(host: "db.exemplo.invalid", port: 5432, user: "app", password: .prompt),
                          tls: TLSOptions(mode: .verifyFull), defaultDatabase: "vendas", driverOptions: ["application_name": .string("rsk")])
    }

    @Test("Criar, ler, atualizar e excluir; ida e volta preserva todos os campos")
    func crudRoundTrip() async throws {
        let box = try await Box.make()
        defer { box.cleanup() }
        let original = postgres("Produção")
        try await box.repository.insert(original)
        let read = try await box.repository.profile(original.id)
        #expect(read.name == original.name && read.environment == .production && read.target == original.target)
        #expect(read.tls == original.tls && read.driverOptions == original.driverOptions && read.labelColor == .teal)
        var edited = read
        edited.name = "Produção (leitura)"
        edited.readOnly = true
        let saved = try await box.repository.update(edited, expectedRevision: read.revision)
        #expect(saved.revision == read.revision + 1)
        #expect(try await box.repository.profile(original.id).readOnly)
        try await box.repository.delete(original.id, expectedRevision: saved.revision)
        await #expect(throws: RSKeeperError.notFound(.unknown)) { _ = try await box.repository.profile(original.id) }
    }

    @Test("Duas janelas editam a mesma versão: a segunda recebe conflito de revisão (DR-27)")
    func revisionConflict() async throws {
        let box = try await Box.make()
        defer { box.cleanup() }
        let profile = sqlite("Local")
        try await box.repository.insert(profile)
        var windowA = try await box.repository.profile(profile.id)
        var windowB = windowA
        windowA.name = "Local A"
        windowB.name = "Local B"
        try await box.repository.update(windowA, expectedRevision: windowA.revision)
        await #expect(throws: RSKeeperError.conflict(.staleRevision)) {
            try await box.repository.update(windowB, expectedRevision: windowB.revision)
        }
        await #expect(throws: RSKeeperError.conflict(.staleRevision)) {
            try await box.repository.delete(profile.id, expectedRevision: windowB.revision)
        }
        #expect(try await box.repository.profile(profile.id).name == "Local A")
    }

    @Test("Nome único por pasta, sem distinguir maiúsculas")
    func uniqueName() async throws {
        let box = try await Box.make()
        defer { box.cleanup() }
        try await box.repository.insert(sqlite("Vendas"))
        await #expect(throws: RSKeeperError.self) { try await box.repository.insert(sqlite("vendas")) }
        let folder = ProfileFolder(name: "Clientes")
        try await box.repository.insertFolder(folder)
        try await box.repository.insert(sqlite("Vendas", folder: folder.id))           // outra pasta: permitido
    }

    @Test("Usar a conexão a põe em recentes sem mudar a revisão (F-CONN-07); fixar e desafixar")
    func recentAndPinned() async throws {
        let box = try await Box.make()
        defer { box.cleanup() }
        let a = sqlite("A"), b = sqlite("B"), c = sqlite("C")
        for profile in [a, b, c] { try await box.repository.insert(profile) }
        try await box.repository.recordUse(a.id, at: Date(timeIntervalSince1970: 100))
        try await box.repository.recordUse(c.id, at: Date(timeIntervalSince1970: 200))
        try await box.repository.setPinned(b.id, true)
        try await box.repository.setPinned(a.id, true)
        let sidebar = try await box.repository.sidebar()
        #expect(sidebar.recent.map(\.name) == ["C", "A"])
        #expect(sidebar.pinned.map(\.name) == ["B", "A"])
        #expect(sidebar.saved.map(\.name) == ["A", "B", "C"])
        #expect(try await box.repository.profile(a.id).revision == 0, "uso e fixação não mudam a revisão")
        try await box.repository.setPinned(b.id, false)
        #expect(try await box.repository.sidebar().pinned.map(\.name) == ["A"])
        // Editar o perfil não desfaz a fixação.
        var edited = try await box.repository.profile(a.id)
        edited.name = "A2"
        try await box.repository.update(edited, expectedRevision: edited.revision)
        #expect(try await box.repository.sidebar().pinned.map(\.name) == ["A2"])
    }

    @Test("Excluir pasta devolve os perfis à raiz, sem apagá-los")
    func deleteFolderKeepsProfiles() async throws {
        let box = try await Box.make()
        defer { box.cleanup() }
        let folder = ProfileFolder(name: "Pasta")
        try await box.repository.insertFolder(folder)
        let profile = sqlite("Dentro", folder: folder.id)
        try await box.repository.insert(profile)
        try await box.repository.deleteFolder(folder.id)
        #expect(try await box.repository.profile(profile.id).folderID == nil)
        await #expect(throws: RSKeeperError.validation(RedactedMessage(alreadyRedacted: "O nome da pasta não pode ser vazio."))) {
            try await box.repository.renameFolder(folder.id, to: "  ")
        }
    }

    @Test("Mudança feita por uma 'janela' chega à observação de outra sem recarga (aceite 4)")
    func observationAcrossWindows() async throws {
        let box = try await Box.make()
        defer { box.cleanup() }
        let otherWindow = ProfileRepository(database: box.database)
        var iterator = otherWindow.sidebarUpdates().makeAsyncIterator()
        #expect(try await iterator.next()?.saved.isEmpty == true)
        try await box.repository.insert(sqlite("Nova"))
        var seen: ConnectionSidebarContent?
        while let next = try await iterator.next() {
            seen = next
            if !next.saved.isEmpty { break }
        }
        #expect(seen?.saved.map(\.name) == ["Nova"])
    }

    @Test("Banco em modo somente leitura recusa escrita com .readOnly")
    func readOnlyDatabase() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rsk-repo-ro-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = DataRoot(url: base.appendingPathComponent("root"))
        _ = try await MigrationRunner(root: root, migrations: MigrationCatalog.standard + [Migration(identifier: "v9_futura") { _ in }], appVersion: "9").open()
        let older = try await MigrationRunner(root: root, appVersion: "0.0.1").open()        // banco mais novo → só leitura
        await #expect(throws: RSKeeperError.readOnly) { try await ProfileRepository(database: older).insert(sqlite("X")) }
    }
}
