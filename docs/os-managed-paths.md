# Caminhos de dados (W0-T13)

## Raiz única por ambiente (código do app)

Todo caminho de dados do app deriva de `DataRoot` (`RSKeeperSecurity/Paths/DataRoot.swift`). A raiz é resolvida pela guarda de ambiente (`App/Sources/Bootstrap/EnvironmentGuard.swift`) **antes** de qualquer cena, dado ou log.

| Ambiente | Com sandbox (`RSK_SANDBOX=YES`) | Sem sandbox |
|---|---|---|
| Dev | `~/Library/Containers/app.rskeeper.RSKeeper.dev/Data/Library/Application Support/RSKeeper Dev` | `~/Library/Application Support/RSKeeper Dev` |
| Test | `-RSKeeperDataRoot <nome>` → `<tmp do container>/<nome>`; ou caminho absoluto dentro do temporário | idem, no temporário do sistema |
| Produção | `~/Library/Containers/app.rskeeper.RSKeeper/Data/Library/Application Support/RSKeeper` | `~/Library/Application Support/RSKeeper` |

Os subdiretórios ficam todos com permissão 0700:

| Subdiretório | Conteúdo |
|---|---|
| `data/app.db` | Banco local (GRDB) |
| `backups/` | Backups pré-migração (5 retidos) |
| `drafts/` | Rascunhos |
| `tmp/` | Temporários, varridos no boot |

## Caminhos geridos pelo sistema operacional (allowlist)

O código do app **não** escreve nestes caminhos. O macOS pode criá-los por conta própria, sempre chaveados pelo bundle ID do ambiente. Um teste de isolamento os aceita **só** com o bundle ID do ambiente testado.

| Caminho | Quem cria | Observação |
|---|---|---|
| `~/Library/Containers/<bundle id>/` | Sandbox (variante `YES`) | O container inteiro; a raiz do app fica dentro dele |
| `~/Library/Saved Application State/<bundle id>.savedState` | AppKit (restauração de janelas) | No sandbox fica dentro do container |
| `~/Library/Preferences/<bundle id>.plist` | `UserDefaults` | No sandbox fica dentro do container |
| `~/Library/Caches/<bundle id>/` | Frameworks do sistema | No sandbox fica dentro do container |
| `~/Library/HTTPStorages/<bundle id>` | `URLSession` | Não usado; o app não faz rede no boot |
| `~/Library/Logs/DiagnosticReports/<nome>-*.ips` | ReportCrash | Só em crash; sem dumps de memória do app (ADR-N23) |
| Unified Logging (`/var/db/diagnostics`) | OSLog | Subsistema `app.rskeeper.RSKeeper[.dev\|.test]`; campos dinâmicos `.private` |

Trocar o bundle ID (D-N3) muda todos esses caminhos e o serviço do Keychain. Ver `docs/native/24` DIST-01 no repositório de investigação.
