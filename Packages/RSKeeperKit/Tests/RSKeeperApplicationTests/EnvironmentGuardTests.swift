import Foundation
import Testing
@testable import RSKeeperApplication
import RSKeeperSecurity

/// NT-SEC-14 / NT-SEC-22 (nível unitário; o lançamento real do app é verificado na W0-T31).
@Suite("Ambiente — guarda fail-closed (NT-SEC-14/22)")
struct EnvironmentGuardTests {
    private let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var support: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }
    private var protected: [URL] { AppEnvironment.defaultProtectedRoots(home: home, bundleIDBase: "app.rskeeper.RSKeeper") }

    private func makeTempDir() throws -> URL {
        let dir = temp.appendingPathComponent("rsk-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func resolve(_ env: String, _ args: [String]) throws(AppEnvironment.GuardError) -> AppEnvironment {
        try AppEnvironment.resolve(environmentName: env, arguments: args, temporaryDirectory: temp,
                                   applicationSupport: support, protectedRoots: protected)
    }

    @Test("Test sem -RSKeeperDataRoot recusa iniciar")
    func testRequiresDataRoot() {
        #expect(throws: AppEnvironment.GuardError.missingDataRoot) { try resolve("test", []) }
        #expect(throws: AppEnvironment.GuardError.missingDataRoot) { try resolve("test", ["-RSKeeperDataRoot"]) }
    }

    @Test("Test com raiz fora do temporário recusa iniciar")
    func testRejectsNonTemporaryRoot() {
        #expect(throws: AppEnvironment.GuardError.self) { try resolve("test", ["-RSKeeperDataRoot", home.path]) }
        #expect(throws: AppEnvironment.GuardError.self) { try resolve("test", ["-RSKeeperDataRoot", temp.path]) }
    }

    @Test("Test com raiz de Dev/Produção — inclusive via symlink no temporário — recusa iniciar")
    func testRejectsProtectedRootViaSymlink() throws {
        let link = try makeTempDir().appendingPathComponent("aponta-para-producao")
        let productionRoot = support.appendingPathComponent("RSKeeper", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: productionRoot)
        defer { try? FileManager.default.removeItem(at: link.deletingLastPathComponent()) }
        // A raiz resolvida sai do temporário: recusada (fail-closed) antes mesmo da checagem de sobreposição.
        #expect(throws: AppEnvironment.GuardError.self) { try resolve("test", ["-RSKeeperDataRoot", link.path]) }
    }

    @Test("Raiz temporária que contém uma raiz protegida é recusada")
    func testRejectsAncestorOfProtectedRoot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeProtected = dir.appendingPathComponent("Library/Application Support/RSKeeper", isDirectory: true)
        #expect(throws: AppEnvironment.GuardError.dataRootOverlapsProtectedRoot(AppEnvironment.canonical(dir).path)) {
            try AppEnvironment.resolve(environmentName: "test", arguments: ["-RSKeeperDataRoot", dir.path],
                                       temporaryDirectory: temp, applicationSupport: support, protectedRoots: [fakeProtected])
        }
    }

    @Test("Test com raiz temporária válida é aceito")
    func testAcceptsTemporaryRoot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = try resolve("test", ["-RSKeeperDataRoot", dir.path])
        #expect(env.kind == .test)
        #expect(env.dataRoot.url.path == AppEnvironment.canonical(dir).path)
    }

    @Test("Nome relativo vira subdiretório do temporário do processo; barras e .. são recusados")
    func relativeNameUsesProcessTemporary() throws {
        let env = try resolve("test", ["-RSKeeperDataRoot", "execucao-123"])
        #expect(env.dataRoot.url.path == AppEnvironment.canonical(temp.appendingPathComponent("execucao-123")).path)
        #expect(throws: AppEnvironment.GuardError.self) { try resolve("test", ["-RSKeeperDataRoot", "../fuga"]) }
        #expect(throws: AppEnvironment.GuardError.self) { try resolve("test", ["-RSKeeperDataRoot", ".."]) }
        #expect(throws: AppEnvironment.GuardError.self) { try resolve("test", ["-RSKeeperDataRoot", "a/b"]) }
    }

    @Test("Dev e Release ignoram -RSKeeperDataRoot (NT-SEC-22)")
    func devAndReleaseIgnoreArgument() throws {
        for name in ["dev", "prod"] {
            let env = try resolve(name, ["-RSKeeperDataRoot", "/tmp/qualquer"])
            #expect(env.ignoredDataRootArgument)
            #expect(env.dataRoot == DataRoot.standard(for: AppEnvironmentKind(rawValue: name)!, applicationSupport: support))
            #expect(!env.dataRoot.url.path.hasPrefix("/tmp"))
        }
    }

    @Test("Ambiente desconhecido falha")
    func unknownEnvironmentFails() {
        #expect(throws: AppEnvironment.GuardError.unknownEnvironment("staging")) { try resolve("staging", []) }
    }
}

@Suite("Caminhos — raiz única por ambiente (W0-T13)")
struct DataRootTests {
    @Test("Raízes distintas por ambiente e caminhos derivados dentro da raiz")
    func rootsPerEnvironment() {
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support", isDirectory: true)
        let roots = AppEnvironmentKind.allCases.map { DataRoot.standard(for: $0, applicationSupport: support) }
        #expect(Set(roots.map(\.url)).count == 3)
        let dev = DataRoot.standard(for: .dev, applicationSupport: support)
        #expect(dev.url.lastPathComponent == "RSKeeper Dev")
        for derived in dev.managedDirectories + [dev.databaseFile] {
            #expect(derived.path.hasPrefix(dev.url.path + "/"))
        }
    }

    @Test("Variante com sandbox: Application Support do container")
    func sandboxVariant() {
        let container = URL(fileURLWithPath: "/Users/x/Library/Containers/app.rskeeper.RSKeeper.dev/Data/Library/Application Support")
        let root = DataRoot.standard(for: .dev, applicationSupport: container)
        #expect(root.url.path.contains("/Containers/app.rskeeper.RSKeeper.dev/"))
    }

    @Test("prepare() cria diretórios 0700 e sweep limpa tmp/")
    func prepareAndSweep() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rsk-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = DataRoot(url: base)
        try root.prepare()
        for directory in [root.url] + root.managedDirectories {
            let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
            #expect(mode == 0o700, "\(directory.lastPathComponent) com modo \(String(mode ?? 0, radix: 8))")
        }
        FileManager.default.createFile(atPath: root.temporaryDirectory.appendingPathComponent("sobra.partial").path, contents: Data())
        #expect(try root.sweepTemporaryFiles() == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.temporaryDirectory.path).isEmpty)
        #expect(root.contains(root.databaseFile))
        #expect(!root.contains(URL(fileURLWithPath: "/etc/hosts")))
    }
}
