// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Pacote local único com os módulos de biblioteca do RSKeeper (docs/native/02 §7).
// Nesta etapa (W0-T03) existem apenas RSKeeperDomain e RSKeeperTesting; os demais
// alvos entram nas tarefas seguintes da Onda 0, em ordem de dependência.
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
    ],
    targets: [
        // Tipos de valor do domínio; sem I/O, sem actors, sem SwiftUI/AppKit.
        .target(
            name: "RSKeeperDomain"
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
    ],
    swiftLanguageModes: [.v6]
)
