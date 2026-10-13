// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Pacote local único com os módulos de biblioteca do RSKeeper (docs/native/02 §7).
//
// Grafo de dependências (README §4 do blueprint; validado por scripts/check-boundaries.sh):
//   Domain        → —
//   SQLKit        → Domain
//   Security      → Domain
//   Persistence   → Domain, Security
//   DriversCore   → Domain, SQLKit
//   Application   → Domain, SQLKit, DriversCore, Persistence, Security
//   DesignSystem  → —
//   SQLEditor     → DesignSystem, SQLKit
//   DataGrid      → DesignSystem, Domain
//   Features      → Application, DesignSystem, SQLEditor, DataGrid
//   Testing       → Domain, DriversCore, Application, Persistence   (só testes)
//
// Drivers concretos (SQLite/PostgreSQL/MySQL) entram na Onda 1. Módulos da expansão
// (Analysis, DataTools, ERDiagram, Assist) não existem nesta onda.
//
// Warnings como erro NÃO são definidos aqui (sem `unsafeFlags`, decisão E-2):
// são aplicados na linha de comando — ver docs/build.md.

let package = Package(
    name: "RSKeeperKit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "RSKeeperDomain", targets: ["RSKeeperDomain"]),
        .library(name: "RSKeeperSQLKit", targets: ["RSKeeperSQLKit"]),
        .library(name: "RSKeeperSecurity", targets: ["RSKeeperSecurity"]),
        .library(name: "RSKeeperPersistence", targets: ["RSKeeperPersistence"]),
        .library(name: "RSKeeperDriversCore", targets: ["RSKeeperDriversCore"]),
        .library(name: "RSKeeperApplication", targets: ["RSKeeperApplication"]),
        .library(name: "RSKeeperDesignSystem", targets: ["RSKeeperDesignSystem"]),
        .library(name: "RSKeeperSQLEditor", targets: ["RSKeeperSQLEditor"]),
        .library(name: "RSKeeperDataGrid", targets: ["RSKeeperDataGrid"]),
        .library(name: "RSKeeperFeatures", targets: ["RSKeeperFeatures"]),
        .library(name: "RSKeeperTesting", targets: ["RSKeeperTesting"]),
    ],
    targets: [
        // MARK: Núcleo não visual

        // Tipos de valor do domínio; sem I/O, sem actors, sem SwiftUI/AppKit.
        .target(
            name: "RSKeeperDomain"
        ),
        // Processamento de SQL independente de UI e de driver. Funções puras.
        .target(
            name: "RSKeeperSQLKit",
            dependencies: ["RSKeeperDomain"]
        ),
        // Keychain, security-scoped bookmarks, redação e logging com privacidade.
        .target(
            name: "RSKeeperSecurity",
            dependencies: ["RSKeeperDomain"]
        ),
        // Banco local (GRDB entra na W0-T22), migrações e repositórios.
        .target(
            name: "RSKeeperPersistence",
            dependencies: ["RSKeeperDomain", "RSKeeperSecurity"]
        ),
        // Protocolos de driver, capacidades e tipos de resultado.
        .target(
            name: "RSKeeperDriversCore",
            dependencies: ["RSKeeperDomain", "RSKeeperSQLKit"]
        ),
        // Casos de uso, actors de sessão, políticas e estado observável por janela.
        .target(
            name: "RSKeeperApplication",
            dependencies: [
                "RSKeeperDomain",
                "RSKeeperSQLKit",
                "RSKeeperDriversCore",
                "RSKeeperPersistence",
                "RSKeeperSecurity",
            ]
        ),

        // MARK: UI

        // Tokens, estilos e componentes básicos (SwiftUI e AppKit).
        .target(
            name: "RSKeeperDesignSystem",
            resources: [.process("Resources")]
        ),
        // Editor SQL (vazio na Onda 0 — decisão E-1; implementação após o SPK-N01).
        .target(
            name: "RSKeeperSQLEditor",
            dependencies: ["RSKeeperDesignSystem", "RSKeeperSQLKit"]
        ),
        // Grade de dados (vazio na Onda 0 — decisão E-1; implementação após o SPK-N02).
        .target(
            name: "RSKeeperDataGrid",
            dependencies: ["RSKeeperDesignSystem", "RSKeeperDomain"]
        ),
        // Telas e fluxos SwiftUI. Nunca importa drivers, GRDB nem Security.
        .target(
            name: "RSKeeperFeatures",
            dependencies: [
                "RSKeeperApplication",
                "RSKeeperDesignSystem",
                "RSKeeperSQLEditor",
                "RSKeeperDataGrid",
            ]
        ),

        // MARK: Testes

        // Utilitários só de teste (fakes, fixtures). Nunca é dependência de alvo de produção.
        .target(
            name: "RSKeeperTesting",
            dependencies: [
                "RSKeeperDomain",
                "RSKeeperDriversCore",
                "RSKeeperApplication",
                "RSKeeperPersistence",
            ]
        ),
        .testTarget(
            name: "RSKeeperDomainTests",
            dependencies: ["RSKeeperDomain", "RSKeeperTesting"]
        ),
        .testTarget(
            name: "RSKeeperSQLKitTests",
            dependencies: ["RSKeeperSQLKit"]
        ),
        .testTarget(
            name: "RSKeeperSecurityTests",
            dependencies: ["RSKeeperSecurity"]
        ),
        .testTarget(
            name: "RSKeeperPersistenceTests",
            dependencies: ["RSKeeperPersistence", "RSKeeperTesting"]
        ),
        .testTarget(
            name: "RSKeeperDriversCoreTests",
            dependencies: ["RSKeeperDriversCore", "RSKeeperTesting"]
        ),
        .testTarget(
            name: "RSKeeperApplicationTests",
            dependencies: ["RSKeeperApplication", "RSKeeperTesting"]
        ),
        .testTarget(
            name: "RSKeeperDesignSystemTests",
            dependencies: ["RSKeeperDesignSystem"]
        ),
        .testTarget(
            name: "RSKeeperFeaturesTests",
            dependencies: ["RSKeeperFeatures"]
        ),
        // Testes de arquitetura (fronteiras de módulo, regras de migração). Leem arquivos
        // do repositório; não dependem de nenhum módulo de produção.
        .testTarget(
            name: "ArchitectureTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
