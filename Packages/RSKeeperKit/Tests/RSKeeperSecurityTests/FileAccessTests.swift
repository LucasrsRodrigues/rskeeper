import Foundation
import Synchronization
import Testing
import RSKeeperDomain
@testable import RSKeeperSecurity

private final class CountingAccess: SecurityScopedAccessing {
    private let counts = Mutex<(start: Int, stop: Int)>((0, 0))
    func startAccessing(_ url: URL) -> Bool { counts.withLock { $0.start += 1 }; return true }
    func stopAccessing(_ url: URL) { counts.withLock { $0.stop += 1 } }
    var snapshot: (start: Int, stop: Int) { counts.withLock { $0 } }
}

private struct Boom: Error {}

@Suite("Arquivos concedidos e URLs externas (W0-T21, NT-SEC-07 parcial)")
struct FileAccessTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rsk-grant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Concessão por bookmark: acesso com start/stop pareados, inclusive em erro")
    func accessIsPaired() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sintetico.sqlite")
        try Data("x".utf8).write(to: file)
        let access = CountingAccess()
        let store = BookmarkStore(storage: InMemoryBookmarkStorage(), appDataRoot: DataRoot(url: dir.appendingPathComponent("app-root")),
                                  access: access)
        let grant = try await store.grant(forUserSelected: file)
        #expect(grant.displayPath == file.path)
        let size = try await store.withAccess(to: grant) { url in try Data(contentsOf: url).count }
        #expect(size == 1)
        await #expect(throws: Boom.self) { try await store.withAccess(to: grant) { _ in throw Boom() } }
        #expect(access.snapshot.start == 2)
        #expect(access.snapshot.stop == 2)
    }

    @Test("Arquivo removido → bookmark inválido → o usuário escolhe de novo")
    func staleBookmarkRequiresNewChoice() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("vai-sumir.sqlite")
        try Data("x".utf8).write(to: file)
        let store = BookmarkStore(storage: InMemoryBookmarkStorage(), appDataRoot: DataRoot(url: dir.appendingPathComponent("root")))
        let grant = try await store.grant(forUserSelected: file)
        try FileManager.default.removeItem(at: file)
        await #expect(throws: FileGrantError.staleOrInvalid) { _ = try await store.withAccess(to: grant) { $0 } }
    }

    @Test("NT-SEC-07: caminho dentro da raiz de dados do app é recusado; concessão desconhecida também")
    func appDataRootIsRejected() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = DataRoot(url: dir)
        try root.prepare()
        let store = BookmarkStore(storage: InMemoryBookmarkStorage(), appDataRoot: root)
        FileManager.default.createFile(atPath: root.databaseFile.path, contents: Data())
        await #expect(throws: FileGrantError.insideAppDataRoot) { _ = try await store.grant(forUserSelected: root.databaseFile) }
        await #expect(throws: FileGrantError.unknownGrant) {
            _ = try await store.withAccess(to: FileGrant(id: UUID(), displayPath: "/etc/hosts")) { $0 }
        }
    }

    @Test("Só https: e mailto: são abertos")
    func externalURLPolicy() {
        #expect(ExternalURLPolicy.isAllowed("https://www.postgresql.org/docs/"))
        #expect(ExternalURLPolicy.isAllowed("mailto:suporte@exemplo.invalid"))
        for rejected in ["http://exemplo.invalid", "file:///etc/passwd", "javascript:alert(1)", "ssh://h", "rskeeper://x",
                         "https://user:pass@exemplo.invalid", "https:///sem-host", "não é url"] {
            #expect(!ExternalURLPolicy.isAllowed(rejected), "\(rejected) deveria ser recusado")
        }
    }
}
