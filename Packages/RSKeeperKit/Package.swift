// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Pacote local único com os módulos de biblioteca do RSKeeper (docs/native/02 §7).
// Alvos entram em ordem de dependência ao longo da Onda 0:
// W0-T03 Domain, Testing · W0-T04 SQLKit, Security · demais nas tarefas seguintes.
//
// Warnings como erro NÃO são definidos aqui (sem `unsafeFlags`, decisão E-2):
// são aplicados na linha de comando — ver docs/build.md.

let package = Package(
    name: "RSKeeperKit",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "RSKeeperDomain", targets: ["RSKeeperDomain"]),
        .library(name: "RSKeeperSQLKit", targets: ["RSKeeperSQLKit"]),
        .library(name: "RSKeeperSecurity", targets: ["RSKeeperSecurity"]),
    ],
    targets: [
        // Tipos de valor do domínio; sem I/O, sem actors, sem SwiftUI/AppKit.
        .target(
            name: "RSKeeperDomain"
        ),
        // Processamento de SQL independente de UI e de driver (lexer, divisor,
        // classificador de risco, parâmetros, quoting, URL). Funções puras.
        .target(
            name: "RSKeeperSQLKit",
            dependencies: ["RSKeeperDomain"]
        ),
        // Keychain, security-scoped bookmarks, redação e logging com privacidade.
        .target(
            name: "RSKeeperSecurity",
            dependencies: ["RSKeeperDomain"]
        ),
        // Utilitários só de teste (fakes, fixtures). Nunca é dependência de alvo de produção.
        .target(
            name: "RSKeeperTesting",
            dependencies: ["RSKeeperDomain"]
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
    ],
    swiftLanguageModes: [.v6]
)
