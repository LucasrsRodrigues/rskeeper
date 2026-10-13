# Build e testes

## Pacote `RSKeeperKit`

Os módulos de biblioteca ficam num pacote local único, `Packages/RSKeeperKit`, conforme `docs/native/02-module-boundaries.md` §7 do repositório de investigação. O índice está em [ADR-INDEX.md](ADR-INDEX.md).

| Configuração | Valor | Onde |
|---|---|---|
| `swift-tools-version` | 6.2 | Primeira linha do `Package.swift` |
| Plataforma | `.macOS(.v26)` (deployment target macOS 26.0, D-N1) | `platforms` |
| Modo de linguagem | Swift 6 (`swiftLanguageModes: [.v6]`), com checagem de concorrência completa | `Package.swift` |

## Warnings como erro (decisão E-2)

Os warnings são tratados como **erro**, mas isso **não** fica no `Package.swift`. Lá, `unsafeFlags` impediria o uso do pacote como dependência e o SwiftPM o restringe. O modo é aplicado **na linha de comando**, em todo build e teste local e no CI:

```sh
# Pacote (SwiftPM)
swift build --package-path Packages/RSKeeperKit -Xswiftc -warnings-as-errors
swift test  --package-path Packages/RSKeeperKit -Xswiftc -warnings-as-errors

# Projeto Xcode (a partir da W0-T08)
xcodebuild ... build SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

O CI (W0-T16) usa exatamente esses comandos. Build sem a flag não vale como validação.

## Atalhos dos comandos

| Atalho | Comando |
|---|---|
| `[test-kit]` | `swift test --package-path Packages/RSKeeperKit -Xswiftc -warnings-as-errors` |
| Plataforma declarada | `swift package --package-path Packages/RSKeeperKit dump-package \| jq '.platforms'` |
