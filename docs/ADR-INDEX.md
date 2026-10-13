# Índice de decisões de arquitetura

As ADRs completas, os requisitos e o backlog ficam no **repositório de investigação**, que é separado deste repositório e não é copiado para cá, porque contém evidências e capturas do produto original.

- **Blueprint:** `docs/native/` no repositório de investigação.
- **ADRs:** `docs/native/14-architecture-decisions.md`.
- **Plano da Onda 0:** `docs/native/23-wave-0-execution-plan.md`.

As ADRs que valerem para o código passam a ser registradas aqui, em formato próprio, à medida que forem implementadas.

## Decisões de plataforma aprovadas

| ID | Decisão | Status |
|---|---|---|
| D-N1 | macOS 26.0; Swift 6 estrito; SwiftUI + AppKit; arm64 prioritário | Aprovada |
| D-N2 | Site próprio; Developer ID; Hardened Runtime; notarização; sem licenciamento comercial | Aprovada |
| D-N3 | Bundle IDs `app.rskeeper.*` | Provisória (desenvolvimento) |
| D-N5 | Verificação da marca "RSKeeper" | Pendente (antes de publicar) |
| D-N6 | Telemetria | Nenhuma |
| D-N8 | Suporte a Intel | Pendente |
| D-N9 | Mecanismo de atualização | Pendente |

## ADRs nativas (títulos)

Os vereditos dos spikes e as regras que eles impõem estão em [spikes/README.md](spikes/README.md).

| ID | Decisão |
|---|---|
| ADR-N01 | Swift 6 + SwiftUI como base; AppKit só onde justificado |
| ADR-N02 | macOS mínimo e arquiteturas |
| ADR-N03 | Modularização em pacotes SPM com regras de fronteira verificadas no CI |
| ADR-N04 | Swift Concurrency com actors por sessão; MainActor só para UI; sem XPC na v1 |
| ADR-N05 | Persistência local com GRDB e `DatabaseMigrator` |
| ADR-N06 | Segredos no Keychain |
| ADR-N07 | App Sandbox **ligado** (SPK-N07 APROVADO, variante A) + Hardened Runtime + security-scoped bookmarks; keychain baseado em arquivo |
| ADR-N08 | Editor SQL próprio: `NSTextView` + TextKit 2 + lexer próprio como rendering attributes (SPK-N01, alternativa A; CodeEditSourceEditor rejeitado) |
| ADR-N09 | Data grid em `NSTableView` view-based (SPK-N02 APROVADO condicional: virtualização horizontal, célula leve, camada por linha, sem grade vertical) |
| ADR-N10 | Árvore de schemas em `NSOutlineView` |
| ADR-N11 | Layout **híbrido**: `NSSplitViewController` + painéis SwiftUI (SPK-N08 reprovou `NavigationSplitView` + `.inspector`) |
| ADR-N12 | Barra de abas própria em SwiftUI |
| ADR-N13 | Command Palette em SwiftUI |
| ADR-N14 | JSON Viewer híbrido |
| ADR-N15 | Menus e drag-and-drop a partir de um modelo único de comandos |
| ADR-N16 | Drivers: GRDB 7.11.1 (SPK-N05 APROVADO), PostgresNIO 1.33.1 só como transporte (SPK-N03 APROVADO com condições), MySQLNIO (condicionado ao SPK-N04) |
| ADR-N17 | Processamento de SQL próprio (`RSKeeperSQLKit`) |
| ADR-N18 | Resultados paginados e colunares, com orçamento de memória |
| ADR-N19 | Sem retry automático de escrita; desfecho desconhecido explícito |
| ADR-N20 | Política de segurança SQL |
| ADR-N21 | Posse de conexões, pool e transações por aba; SQLite na opção A (SPK-N05); pool PostgreSQL próprio (SPK-N03) |
| ADR-N22 | Isolamento de ambientes por bundle ID, container e serviço de Keychain |
| ADR-N23 | Logging com OSLog e privacidade; sem crash reporter próprio |
| ADR-N24 | Sem licenciamento, edições, plugins ou nuvem na v1 |
| ADR-N25 | Testes com Swift Testing e XCTest/XCUITest |
| ADR-N26…N33 | Expansão (ondas 5–6): motor de políticas, módulos novos, LLM opcional, plano normalizado, `SchemaModel`, workspaces lógicos, snapshots cifrados, Job Center |
