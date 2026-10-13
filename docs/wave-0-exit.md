# Onda 0 — portão de saída (W0-T32)

**Status: PARCIAL.** As 32 tarefas estão implementadas e a sequência inteira do CI passou localmente. O portão **não** é declarado aprovado por três motivos:

1. O pipeline nunca rodou no GitHub Actions, porque não houve push.
2. Há validações manuais pendentes (seção 3).

Os seis spikes estão concluídos.

Evidência: `scripts/ci/collect-evidence.sh`, execução `20261013-192116`.
- Commit `5f00962`, árvore limpa, derived data apagado antes.
- Host macOS 26.6.2 arm64, Xcode 27.0 (27A266a), Swift 6.4 (swiftlang-6.4.0.34.1).
- **19/19 etapas PASS.** Os logs completos ficam em `.build/evidence/<data>/` (fora do git).

## 1. Checklist do §4 do plano

| # | Critério | Resultado | Evidência |
|---|---|---|---|
| 1 | `[build]` verde em Dev, Test e Release × `RSK_SANDBOX` YES/NO, zero avisos (NT-CONC-11) | **OK** | 6× `build: OK` + `ci: zero avisos em fontes próprias` |
| 2 | `[test-kit]` e `[test-app]` verdes; testes obrigatórios | **OK** (ver §2) | 115 testes Swift Testing; 3 XCUITests × 2 variantes; `smoke-guard` |
| 3 | Fronteiras rejeitam violação proposital | **OK** | `negative-checks`: `RSKeeperSQLKit declara [RSKeeperDomain,RSKeeperSecurity]; esperado [RSKeeperDomain]` |
| 4 | Auditoria de licenças ativa; `Package.resolved` versionado com versões exatas | **OK** | `license-audit: OK (1 dependência)` (GRDB 7.11.1, MIT); uma pin desconhecida é reprovada |
| 5 | Janela Conexões e workspace vazio; sem rede no boot; sem arquivos fora da raiz e da allowlist | **OK**, com limite (§3) | XCUITest; `footprint: OK 0 conexões de rede`; raiz 0700 |
| 6 | Artefato ad hoc com Hardened Runtime (`codesign -dv`) e entitlements = allowlist | **OK** | `flags=0x10002(adhoc,runtime)`; 4 entitlements na variante com sandbox, nenhum na direta; sem `get-task-allow` |
| 7 | SPK-N07 e N05 concluídos, com ADR-N07 e N21 atualizadas; N03, N08, N01 e N02 com status explícito | **OK**: os seis concluídos | [spikes/README.md](spikes/README.md), [ADR-INDEX.md](ADR-INDEX.md) |
| 8 | Nenhum ativo do Beekeeper (higiene verde) | **OK** | `hygiene: OK`; uma violação injetada é reprovada |

Contratos da T17/T18 revisados à luz dos SPK-N03/N05: contrato v1 com `BoundStatement.executionID` (tabela em [spikes/README.md](spikes/README.md#revisão-dos-contratos-da-w0-t17t18-w0-t32)).

## 2. Testes obrigatórios

| Teste | Onde |
|---|---|
| NT-UNIT-01 | `DomainInvariantTests` |
| NT-UNIT-10 | `ApplicationLayerTests` |
| NT-UNIT-12 | `LoggingTests` |
| NT-UNIT-15 | `ModuleBoundaryTests` + `scripts/check-boundaries.sh` |
| NT-CONC-01, 03 | `ApplicationLayerTests` |
| NT-CONC-02, 04, 05 | `SessionConcurrencyTests` |
| NT-MIG-01, 03…07 | `MigrationTests`, `MigrationRulesTests` |
| NT-SEC-01 | `LoggingTests`, `DiagnosticsExporterTests` |
| NT-SEC-02, 03, 04, 15 | `SecretStoreTests` |
| NT-SEC-05 (versão da onda 0) | `scripts/ci/package-adhoc.sh` |
| NT-SEC-07 | `FileAccessTests` |
| NT-SEC-14 | `EnvironmentGuardTests` + `scripts/ci/smoke-guard.sh` |
| NT-SEC-17 | `scripts/license-audit.sh` + `negative-checks` |
| NT-SEC-20 | `scripts/ci/log-privacy.sh` (`app.started environment=prod sweptTemporaryFiles=0 <private>`) |
| NT-SEC-22 | `EnvironmentGuardTests` |
| NT-SNAP-01 | `SnapshotTests` (paleta, controles e padrões, claro e escuro) |
| NT-A11Y-04 | `TokenTests` |

**Cobertura de linhas do pacote** (`swift test --enable-code-coverage` + `llvm-cov`, sem testes e dependências): **94,7%** de 2.557 linhas.

| Módulo | Cobertura |
|---|---|
| Domain | 98,8% |
| Persistence | 99,1% |
| Testing | 99,1% |
| DesignSystem | 95,2% |
| Security | 94,0% |
| Application | 91,6% |
| DriversCore | 85,7% |
| Features | 0% (só o `NSOpenPanel`, sem teste automatizável) |

O app (`App/`) não entra nessa medição; ele é coberto pelos XCUITests.

## 3. Pendências e limites conhecidos

| ID | Pendência | Impacto | Próximo passo |
|---|---|---|---|
| P-01 | **Atualizado em 2026-10-13:** o CI rodou no GitHub e falhou no job toolchain, porque a imagem `macos-26` só tem Xcode 26.0.1…26.6, sem Xcode 27. Decisão pendente: runner próprio, esperar a imagem ou outro toolchain | Os scripts são os mesmos e passam localmente; o YAML não foi exercitado | Push autorizado → primeira execução → ajustar runner e Xcode |
| P-02 | ~~SPK-N01 em andamento~~ **Resolvida:** alternativa A aprovada | — | — |
| P-03 | `fs-footprint` só detecta caminhos **novos** com "rskeeper" no nome, até profundidade 4 em `~/Library`; escritas em arquivos já existentes não são vistas | Cobertura parcial do item 5 | Ampliar com `fs_usage` ou Endpoint Security na onda 1 |
| P-04 | Validações manuais: VoiceOver, host macOS 26.0 exato (só 26.6.2 testado), Intel (D-N8), prompts do Keychain em runner de CI (R-W0-03) | Fora do alcance não interativo | Checklist manual antes do portão da onda 1 |
| P-05 | As referências de snapshot dependem da máquina (fontes e versão do SO) | Podem divergir em outro host | Regravar com `RSK_RECORD_SNAPSHOTS=1` no runner de referência |
| P-06 | O NT-SEC-20 executa o app Release, que cria o container `app.rskeeper.RSKeeper` na máquina de desenvolvimento | Sem dados reais; só a raiz vazia | Aceito |
| P-07 | Limpeza manual do SPK-N07: dois containers vazios `app.rskeeper.spike.n07.sandbox*` (o `rm` não remove containers) | Nenhum | O usuário arrasta-os ao Lixo |
| P-08 | `LICENSE` é placeholder; D-N3 (bundle IDs) e D-N5 (marca) estão pendentes | Bloqueia publicação, não desenvolvimento | Decisão do responsável |

## 4. Preparação da onda 1

Desbloqueadas:
- **NST-04-02:** SQLite, pelas regras do SPK-N05.
- **NST-04-03:** PostgreSQL, com escopo maior pelo SPK-N03: pool próprio, cancelamento guardado, decodificador binário, divisor de instruções.
- **NST-05-01:** layout híbrido (SPK-N08).
- **NST-08-01:** grade com 4 requisitos (SPK-N02).
- **NST-03-03** e **NST-10-04:** sandbox (SPK-N07).

A **NST-07-01** também fica desbloqueada: editor próprio em TextKit 2 (SPK-N01). O job de drivers em containers já está definido no CI e deve ser ativado junto com a NST-04-02/03.
