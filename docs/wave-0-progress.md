# Onda 0 — registro de progresso

Registro operacional da execução autônoma da Onda 0 (Fase 5). **Não substitui os testes automatizados**: todo item "concluído" cita o comando que o verificou.

Toolchain: Xcode 27.0 (27A266a), Swift 6.4, SDK macOS 27.0; host macOS 26.6.2 arm64.

## Tarefas

| Tarefa | Estado | Commit | Verificação |
|---|---|---|---|
| W0-T01 Repositório e higiene | Concluída | 4934681 | `git ls-files \| grep -Ei 'beekeeper\|bks\|asar\|evidence'` vazio |
| W0-T02 Toolchain | Concluída | f4c10a0 | `scripts/check-toolchain.sh` (0; 1 em divergência; 2 em ambiente) |
| W0-T03 Pacote + Domain | Concluída | 63e13a5 | `[test-kit]` 0 warnings |
| W0-T04 SQLKit + Security | Concluída | 868fb75 | `[test-kit]`; build isolado por alvo |
| W0-T05..T07 Demais alvos | Concluída | 88f0f7d | `[test-kit]`; `dump-package` = README §4 |
| W0-T08/T10/T11 Xcode, ambientes, entitlements | Concluída | ff58ab0 | 6 builds (Dev/Test/Release × sandbox YES/NO) exit 0, 0 warnings de fonte; `codesign` flags `adhoc,runtime`; app abriu 1 janela, 0 conexões |
| W0-T09 Fronteiras | Concluída | (este commit) | `scripts/check-boundaries.sh` 0; cópia com violação proposital → 1 |

## Decisões tomadas

| ID | Decisão | Motivo |
|---|---|---|
| W0-D01 | `OTHER_CODE_SIGN_FLAGS = --options=runtime` | O Xcode desliga o Hardened Runtime com assinatura ad hoc; a flag o mantém para validar a W0-T11 sem certificados |
| W0-D02 | `ENABLE_DEBUG_DYLIB = NO` | Com Hardened Runtime + ad hoc, a validação de bibliotecas recusou `RSKeeper Dev.debug.dylib` ("different Team IDs"); o app não iniciava |
| W0-D03 | `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` no Release | O Release recebia `get-task-allow`, incompatível com notarização |
| W0-D04 | Fontes do app em `App/Sources`, recursos em `App/Resources` | Pastas sincronizadas do Xcode (objectVersion 77) sem exceções; difere dos caminhos do plano (`App/*.swift`) só na subpasta |
| W0-D05 | Primeiro token de cor (`accent`) já na W0-T07 | Catálogo vazio não gera `Assets.car`; sem ele o aceite "recursos via Bundle.module" não é verificável |
| W0-D06 | `RSK_SANDBOX = YES` como padrão | SPK-N07 APROVADO recomendou sandbox ligado (relatório em RSKeeper-spikes/reports/SPK-N07.md) |

## Spikes

| Spike | Estado | Veredito |
|---|---|---|
| SPK-N07 | Concluído | APROVADO — sandbox ligado; keychain baseado em arquivo (data protection exige provisioning profile: -34018); grant de pasta ou related items para `-wal`/`-shm` |

## Inconsistências do plano encontradas

| ID | Inconsistência | Tratamento |
|---|---|---|
| W0-I01 | O plano fala em "12 alvos (11 bibliotecas + Testing)"; o README §4 sem drivers e sem o App dá 10 bibliotecas + Testing | Implementado conforme o README §4 |
| W0-I02 | Projeto Xcode sem template: não há XcodeGen/Tuist na máquina | `project.pbxproj` escrito à mão, validado por `plutil -lint` e `xcodebuild -list` |
