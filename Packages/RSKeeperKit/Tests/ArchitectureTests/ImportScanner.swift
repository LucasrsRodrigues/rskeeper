import Foundation

/// Regras de fronteira lidas de `docs/module-rules.json` (W0-T09).
struct ModuleRules: Decodable {
    struct Module: Decodable {
        var prospective: Bool?
        var declaredDependencies: [String]
        var allowedImports: [String]
        var forbiddenImports: [String]
        var externalDependencies: [String]?
    }

    var externalForbiddenEverywhere: [String]
    var modules: [String: Module]
}

/// Uma violação de fronteira encontrada na varredura de imports.
struct BoundaryViolation: Equatable, CustomStringConvertible {
    var module: String
    var file: String
    var line: Int
    var importedModule: String
    var reason: String

    var description: String { "\(module): \(file):\(line) importa \(importedModule) — \(reason)" }
}

/// Varre fontes Swift em busca de `import`, inclusive dentro de `#if canImport(...)`,
/// `@testable import`, `@_exported import` e `import struct X.Y`.
enum ImportScanner {
    /// Retorna os módulos importados com o número da linha.
    static func imports(in source: String) -> [(module: String, line: Int)] {
        var result: [(String, Int)] = []
        let pattern = #"^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let moduleRange = Range(match.range(at: 1), in: line) {
                result.append((String(line[moduleRange]), index + 1))
            }
        }
        return result
    }

    /// Avalia as regras para um módulo a partir de pares (arquivo, conteúdo).
    static func violations(
        module: String,
        sources: [(file: String, contents: String)],
        rules: ModuleRules,
        knownModules: Set<String>
    ) -> [BoundaryViolation] {
        guard let rule = rules.modules[module] else {
            return [BoundaryViolation(module: module, file: "-", line: 0, importedModule: "-",
                                      reason: "módulo sem regra em docs/module-rules.json")]
        }
        var found: [BoundaryViolation] = []
        for source in sources {
            for (imported, line) in imports(in: source.contents) {
                if rules.externalForbiddenEverywhere.contains(imported) || rule.forbiddenImports.contains(imported) {
                    found.append(.init(module: module, file: source.file, line: line,
                                       importedModule: imported, reason: "import proibido"))
                } else if imported.hasPrefix("RSKeeper"), knownModules.contains(imported) || rules.modules[imported] != nil,
                          !rule.allowedImports.contains(imported) {
                    found.append(.init(module: module, file: source.file, line: line,
                                       importedModule: imported, reason: "módulo interno fora de allowedImports"))
                }
            }
        }
        return found
    }
}

/// Localização dos arquivos do repositório a partir deste arquivo de teste.
enum RepositoryPaths {
    /// `<repo>/Packages/RSKeeperKit/Tests/ArchitectureTests/ImportScanner.swift` → `<repo>`
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ArchitectureTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // RSKeeperKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // <repo>
    }

    static var packageRoot: URL { repositoryRoot.appendingPathComponent("Packages/RSKeeperKit") }
    static var rulesFile: URL { repositoryRoot.appendingPathComponent("docs/module-rules.json") }

    static func loadRules() throws -> ModuleRules {
        try JSONDecoder().decode(ModuleRules.self, from: Data(contentsOf: rulesFile))
    }

    /// Diretórios de `Sources/` do pacote (um por módulo).
    static func sourceModules() throws -> [String] {
        let sources = packageRoot.appendingPathComponent("Sources")
        return try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// Fontes `.swift` de um diretório, recursivamente.
    static func swiftFiles(under directory: URL) throws -> [(file: String, contents: String)] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: ""),
                          try String(contentsOf: url, encoding: .utf8)))
        }
        return files.sorted { $0.0 < $1.0 }
    }
}
