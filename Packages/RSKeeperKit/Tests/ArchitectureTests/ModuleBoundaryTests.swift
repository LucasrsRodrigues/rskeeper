import Foundation
import Testing

/// NT-UNIT-15 — fronteiras de módulo (W0-T09).
@Suite("Fronteiras de módulo (NT-UNIT-15)")
struct ModuleBoundaryTests {
    @Test("Todo módulo de Sources/ tem regra e nenhuma regra ativa aponta para módulo inexistente")
    func everyModuleHasRules() throws {
        let rules = try RepositoryPaths.loadRules()
        let modules = Set(try RepositoryPaths.sourceModules())
        for module in modules {
            #expect(rules.modules[module] != nil, "módulo \(module) sem regra em docs/module-rules.json")
        }
        for (name, rule) in rules.modules where rule.prospective != true {
            #expect(modules.contains(name), "regra ativa para módulo inexistente: \(name)")
        }
    }

    @Test("Os imports de produção respeitam docs/module-rules.json")
    func productionImportsRespectRules() throws {
        let rules = try RepositoryPaths.loadRules()
        let modules = try RepositoryPaths.sourceModules()
        var all: [BoundaryViolation] = []
        for module in modules {
            let directory = RepositoryPaths.packageRoot.appendingPathComponent("Sources/\(module)")
            let files = try RepositoryPaths.swiftFiles(under: directory)
            all += ImportScanner.violations(module: module, sources: files, rules: rules, knownModules: Set(modules))
        }
        #expect(all.isEmpty, "violações:\n\(all.map(\.description).joined(separator: "\n"))")
    }

    @Test("O app (App/Sources) não importa GRDB nem drivers")
    func appTargetImports() throws {
        let rules = try RepositoryPaths.loadRules()
        let files = try RepositoryPaths.swiftFiles(under: RepositoryPaths.repositoryRoot.appendingPathComponent("App/Sources"))
        let forbidden: Set<String> = ["GRDB", "PostgresNIO", "MySQLNIO", "NIOCore", "Electron"]
        let violations = files.flatMap { file in
            ImportScanner.imports(in: file.contents)
                .filter { forbidden.contains($0.module) || rules.externalForbiddenEverywhere.contains($0.module) }
                .map { "\(file.file):\($0.line) importa \($0.module)" }
        }
        #expect(violations.isEmpty, "\(violations)")
    }

    // MARK: Violações propositais (aceite 3: "um PR de teste com violação proposital falha")

    @Test("Detecta Domain importando SwiftUI")
    func detectsDomainImportingSwiftUI() throws {
        let rules = try RepositoryPaths.loadRules()
        let found = ImportScanner.violations(
            module: "RSKeeperDomain",
            sources: [("Fixture.swift", "import Foundation\nimport SwiftUI\n")],
            rules: rules, knownModules: [])
        #expect(found.map(\.importedModule) == ["SwiftUI"])
    }

    @Test("Detecta Features importando GRDB dentro de #if canImport")
    func detectsConditionalImport() throws {
        let rules = try RepositoryPaths.loadRules()
        let source = """
        #if canImport(GRDB)
            @preconcurrency import GRDB
        #endif
        """
        let found = ImportScanner.violations(module: "RSKeeperFeatures", sources: [("Fixture.swift", source)],
                                             rules: rules, knownModules: [])
        #expect(found.map(\.importedModule) == ["GRDB"])
    }

    @Test("Detecta Features importando RSKeeperSecurity e driver")
    func detectsInternalViolations() throws {
        let rules = try RepositoryPaths.loadRules()
        let source = "@testable import RSKeeperSecurity\nimport struct RSKeeperDriverSQLite.Driver\n"
        let found = ImportScanner.violations(module: "RSKeeperFeatures", sources: [("Fixture.swift", source)],
                                             rules: rules, knownModules: ["RSKeeperSecurity"])
        #expect(Set(found.map(\.importedModule)) == ["RSKeeperSecurity", "RSKeeperDriverSQLite"])
    }

    @Test("Detecta módulo interno fora de allowedImports (Domain importando SQLKit)")
    func detectsUpwardInternalImport() throws {
        let rules = try RepositoryPaths.loadRules()
        let found = ImportScanner.violations(module: "RSKeeperDomain", sources: [("Fixture.swift", "import RSKeeperSQLKit\n")],
                                             rules: rules, knownModules: ["RSKeeperSQLKit"])
        #expect(found.count == 1)
    }

    @Test("O scanner reconhece as formas de import")
    func scannerRecognizesImportForms() {
        let source = """
        import Foundation
        @_exported import RSKeeperDomain
        @preconcurrency import Dispatch
        import struct Foundation.URL
        // import SwiftUI (comentário não conta)
        let text = "import AppKit"
        """
        #expect(ImportScanner.imports(in: source).map(\.module) == ["Foundation", "RSKeeperDomain", "Dispatch", "Foundation"])
    }
}
