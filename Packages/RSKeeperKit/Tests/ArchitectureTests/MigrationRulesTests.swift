import Foundation
import Testing

/// NT-MIG-05 (parte estática) — migrações só executam SQL no próprio banco (lição U-22).
@Suite("Regras das migrações (NT-MIG-05, estático)")
struct MigrationRulesTests {
    /// Símbolos de I/O proibidos em arquivos de migração.
    static let forbiddenSymbols = ["FileManager", "FileHandle", "Process", "NSTask", "URL(", "fopen", "unlink", "remove(",
                                   "truncate", "OSLog", "Logger(", "NSWorkspace", "posix_spawn", "system("]
    static let allowedImports: Set<String> = ["GRDB"]

    static var migrationsDirectory: URL {
        RepositoryPaths.packageRoot.appendingPathComponent("Sources/RSKeeperPersistence/Migrations")
    }

    static func violations(in source: String, file: String) -> [String] {
        var found: [String] = []
        for (module, line) in ImportScanner.imports(in: source) where !allowedImports.contains(module) {
            found.append("\(file):\(line) importa \(module)")
        }
        let code = source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        for (index, line) in code.enumerated() {
            for symbol in forbiddenSymbols where line.contains(symbol) {
                found.append("\(file): linha de código \(index + 1) usa \(symbol)")
            }
        }
        return found
    }

    @Test("Arquivos de Migrations/ só importam GRDB e não usam I/O")
    func migrationsHaveNoIO() throws {
        let files = try RepositoryPaths.swiftFiles(under: Self.migrationsDirectory)
        #expect(!files.isEmpty)
        let all = files.flatMap { Self.violations(in: $0.contents, file: $0.file) }
        #expect(all.isEmpty, "\(all.joined(separator: "\n"))")
    }

    @Test("Detecta migração que importa Foundation e apaga arquivos (violação proposital)")
    func detectsForbiddenMigration() {
        let bad = """
        import GRDB
        import Foundation
        enum V9 { static func migrate(_ db: Database) throws {
            try FileManager.default.removeItem(atPath: "/Users/x/Library/Logs/main.log")
        } }
        """
        let found = Self.violations(in: bad, file: "V9.swift")
        #expect(found.contains { $0.contains("importa Foundation") })
        #expect(found.contains { $0.contains("FileManager") })
    }
}
