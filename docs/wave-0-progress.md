# Onda 0 — registro de progresso

Registro operacional da execução autônoma da Onda 0 (Fase 5). **Não substitui os testes automatizados**: todo item "concluído" cita o comando que o verificou. O fechamento formal está em [wave-0-exit.md](wave-0-exit.md).

Toolchain: Xcode 27.0 (27A266a), Swift 6.4, SDK macOS 27.0; host macOS 26.6.2 arm64.

## Tarefas (32/32)

| Tarefa | Estado | Commit | Verificação |
|---|---|---|---|
| W0-T01 Repositório e higiene | Concluída | 4934681 | `scripts/ci/hygiene.sh` 0 |
| W0-T02 Toolchain | Concluída | f4c10a0 | `scripts/check-toolchain.sh` (0; 1 em divergência; 2 em ambiente) |
| W0-T03 Pacote + Domain | Concluída | 63e13a5 | `[test-kit]` 0 avisos |
| W0-T04 SQLKit + Security | Concluída | 868fb75 | `[test-kit]`; build isolado por alvo |
| W0-T05..T07 Demais alvos | Concluída | 88f0f7d | `[test-kit]`; `dump-package` = README §4 |
| W0-T08/T10/T11 Xcode, ambientes, entitlements | Concluída | ff58ab0 | 6 builds (Dev/Test/Release × sandbox YES/NO), 0 avisos; `codesign` flags `adhoc,runtime` |
| W0-T09 Fronteiras | Concluída | 5b7670d | `scripts/check-boundaries.sh` 0; violação proposital → 1 (`scripts/ci/negative-checks.sh`) |
| W0-T12/T13 Guarda de ambiente e raiz única | Concluída | 642854d | `EnvironmentGuardTests`; `scripts/ci/smoke-guard.sh` (exit 78) |
| W0-T14/T15 OSLog e diagnóstico | Concluída | 64d0aeb, c53588b | `LoggingTests` (OSLogStore), `DiagnosticsExporterTests`; `scripts/ci/log-privacy.sh` (NT-SEC-20) |
| W0-T16 CI | Concluída (local) | d773885, 621713f | `.github/workflows/ci.yml` + `scripts/ci/*`; **não executado no GitHub** (sem push) |
| W0-T17 Tipos de domínio | Concluída | 5f3f333 | `DomainInvariantTests` |
| W0-T18 Contratos e driver em memória | Concluída; contrato v1 na T32 | a653c4f, b4de2c4 | `DriverContractTests`, `ContractRevisionTests` |
| W0-T19 Sessões | Concluída | 4bf02a9 | `SessionConcurrencyTests` (NT-CONC-02/04/05) |
| W0-T20 Conectar, WindowModel, retry | Concluída | 93d5a96 | `ApplicationLayerTests` (NT-CONC-01/03, NT-UNIT-10) |
| W0-T21 Bookmarks, painel, URLs | Concluída | e5085c6 | `FileAccessTests` (NT-SEC-07) |
| W0-T22/T23 Banco local e migrações | Concluída | ce64bd6 | `MigrationTests`, `MigrationRulesTests` (NT-MIG-01, 03…07) |
| W0-T24 SecretStore | Concluída | 2be9ee6 | `SecretStoreTests` (NT-SEC-02/03/04/15) |
| W0-T25 Tokens e temas | Concluída | 49b24f5 | `TokenTests` (NT-A11Y-04) |
| W0-T26/T27 Componentes e padrões | Concluída | 869be30 | `ComponentLogicTests`; galeria no menu Debug |
| W0-T28 String Catalog | Concluída | 869be30, 4dbc376 | `LocalizationTests`; XCUITest em pt-BR e en |
| W0-T29 Cenas | Concluída | 4dbc376 | XCUITest (Conexões e workspace vazio); `scripts/ci/fs-footprint.sh` (0 rede) |
| W0-T30 Snapshots | Concluída | 869be30 | `SnapshotTests` (NT-SNAP-01) + teste de sensibilidade do comparador |
| W0-T31 XCUITest de fumaça | Concluída | 3d3e277, ca151e0 | `scripts/ci/test-app.sh` YES e NO |
| W0-T32 Portão de saída | Concluído com pendências registradas | ver wave-0-exit.md | `scripts/ci/collect-evidence.sh` |

## Decisões tomadas

| ID | Decisão | Motivo |
|---|---|---|
| W0-D01 | `OTHER_CODE_SIGN_FLAGS = --options=runtime` | O Xcode desliga o Hardened Runtime com assinatura ad hoc; a flag o mantém sem certificados |
| W0-D02 | `ENABLE_DEBUG_DYLIB = NO` | Com Hardened Runtime + ad hoc, a validação de bibliotecas recusou o `.debug.dylib` ("different Team IDs") |
| W0-D03 | `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` no Release | O Release recebia `get-task-allow`, incompatível com notarização |
| W0-D04 | Fontes do app em `App/Sources`, recursos em `App/Resources` | Pastas sincronizadas do Xcode sem exceções |
| W0-D05 | Primeiro token de cor já na W0-T07 | Catálogo vazio não gera `Assets.car` |
| W0-D06 | `RSK_SANDBOX = YES` como padrão | SPK-N07 APROVADO recomendou sandbox ligado |
| W0-D07 | `PhysicalConnection` é referência `AnyObject & Sendable` | A posse exclusiva fica no `ConnectionLease ~Copyable`, não no protocolo |
| W0-D08 | Transação manual guardada como referência no actor da sessão | Uma conexão por aba em modo Manual (alinhado ao SPK-N05, opção A) |
| W0-D09 | Testes do Keychain no SwiftPM com keychain baseado em arquivo | O data protection keychain exige entitlement restrito (SPK-N07) |
| W0-D10 | `teal-600 = #147E84` | O `onAccent` claro dava 4,47:1; agora ≥ 4,5:1 (NT-A11Y-04) |
| W0-D11 | Gate de avisos por log no CI (`rsk_check_warnings`) | Avisos `#ActorIsolatedCall` não foram promovidos a erro por `SWIFT_TREAT_WARNINGS_AS_ERRORS`; a flag na linha de comando conflita com o `-suppress-warnings` do GRDB |
| W0-D12 | Hardened Runtime desligado **só** no bundle de XCUITest | O runner ad hoc recusava carregá-lo (Team ID); o app mantém Hardened Runtime |
| W0-D13 | Recusa da guarda verificada por script, não por XCUITest | O runner não executa binário com sandbox como filho (SIGTRAP em `_libsecinit_appsandbox`) |
| W0-D14 | Snapshots próprios (E-6), referências fora do bundle de teste | Sem dependência externa; comparação após o mesmo caminho PNG nos dois lados |
| W0-D15 | Contrato de driver v1: `BoundStatement.executionID` | Cancelamento guardado do PostgreSQL (SPK-N03) |

## Spikes

Resumo e regras em [spikes/README.md](spikes/README.md).

| Spike | Estado | Veredito |
|---|---|---|
| SPK-N07 | Concluído | APROVADO — sandbox ligado |
| SPK-N05 | Concluído | APROVADO — GRDB 7.11.1; ADR-N21 opção A |
| SPK-N03 | Concluído | APROVADO com condições — PostgresNIO 1.33.1 só como transporte |
| SPK-N08 | Concluído | Opção A reprovada; híbrido aprovado (ADR-N11) |
| SPK-N01 | Em andamento | — |
| SPK-N02 | Em andamento | — |

## Inconsistências do plano encontradas

| ID | Inconsistência | Tratamento |
|---|---|---|
| W0-I01 | O plano fala em "12 alvos (11 bibliotecas + Testing)"; o README §4 sem drivers e sem o App dá 10 bibliotecas + Testing | Implementado conforme o README §4 |
| W0-I02 | Projeto Xcode sem template: não há XcodeGen/Tuist na máquina | `project.pbxproj` escrito à mão, validado por `plutil -lint` e `xcodebuild -list` |
| W0-I03 | O plano pede a recusa da guarda "por XCUITest"; o runner não consegue executar o binário com sandbox | Verificação por `scripts/ci/smoke-guard.sh` no mesmo job (W0-D13) |
