# Spikes técnicos da onda 0

Os spikes rodaram num repositório **descartável e separado** (`RSKeeper-spikes/`, git próprio), com dados sintéticos e bancos temporários. **Nenhum protótipo foi incorporado a este repositório.** Aqui ficam só as conclusões que viram regra de implementação; os relatórios completos e as medições ficam no repositório de spikes (`reports/SPK-N0x.md`).

| Spike | Tema | Veredito | ADR afetada | Desbloqueia |
|---|---|---|---|---|
| SPK-N07 | Sandbox, entitlements, Keychain, bookmarks | **APROVADO** | ADR-N07 → sandbox **ligado** (variante A) | NST-03-03, NST-00-02, NST-10-04 |
| SPK-N05 | SQLite via GRDB | **APROVADO** | ADR-N16 (SQLite) confirmada; ADR-N21 → opção A | NST-04-02 |
| SPK-N03 | PostgreSQL via PostgresNIO | **APROVADO com condições** | ADR-N16 (PostgreSQL) confirmada com 6 condições | NST-04-03 (escopo maior) |
| SPK-N08 | Layout de quatro regiões | **Opção A reprovada**; híbrido recomendado | ADR-N11 → `NSSplitViewController` + SwiftUI | NST-05-01 |
| SPK-N01 | Editor SQL (TextKit 2) | ver seção abaixo | ADR-N08 | NST-07-01 |
| SPK-N02 | Grade `NSTableView` | **APROVADO condicional** | ADR-N09 mantida, com 4 requisitos | NST-08-01 |

## SPK-N07 — sandbox e entitlements (APROVADO)

- **Sandbox ligado** em produção (`RSK_SANDBOX=YES` é o padrão). A variante sem sandbox continua compilando no CI até a remoção (R-W0-05).
- Entitlements finais (variante A): `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, `network.client`. Nada além disso; o CI compara com a allowlist (`scripts/ci/package-adhoc.sh`).
- **Keychain:** usar o keychain baseado em arquivo (`kSecUseDataProtectionKeychain = false`). O data protection keychain exige entitlement restrito (`keychain-access-groups` / `application-identifier`) com provisioning profile; sem ele dá `-34018`, com ou sem sandbox. Em assinatura ad hoc, o requisito designado é o CDHash: **cada build nova é negada (`-25293`) para os itens da build anterior** e, com interação, mostraria o diálogo de ACL. Com Developer ID deve ficar estável [A VALIDAR com certificado real].
- **Bookmarks:** um bookmark criado sem sandbox **não** resolve com escopo na variante com sandbox (erro 259). Por isso a decisão vale **antes** do primeiro release.
- **SQLite do usuário:** `-wal`, `-shm` e `-journal` via *related items* (`CFBundleDocumentTypes` com `NSIsRelatedItemType=true` para os sufixos de cada extensão suportada) ou grant da pasta como alternativa; só o grant do arquivo não basta.
- **SSH:** o socket do `ssh-agent` do sistema (launchd) aceita `connect` dentro do sandbox; agentes de terceiros com socket na pasta do usuário são negados; `~/.ssh` não é legível sem grant explícito.
- **Processos:** executáveis em `/bin`, `/usr/bin` e `/Applications` rodam (presos ao sandbox); Homebrew é negado. A mensagem do `Process` ("arquivo não existe") mascara a negação → diagnosticar por `errno`.
- **Rede:** sem `network.client`, todo `connect` TCP dá EPERM; `network.server` fica ausente (túnel SSH em processo, SPK-N06).
- **Containers `.test`:** não são removíveis por `rm`; a limpeza de testes atua dentro do container.
- Não validado (exige certificado real): Developer ID, notarização e container de produção → NST-14-01 (onda 4).

## SPK-N05 — SQLite via GRDB (APROVADO)

- GRDB **7.11.1** fixada (`exact:`), MIT; build com `-warnings-as-errors` sem avisos no spike (`Row`, `RowCursor` e `Database` não são `Sendable` e o compilador impede o vazamento). Usa a `libsqlite3` do sistema: comportamentos da Apple (`PERSIST_WAL`, URI) pedem teste de regressão a cada macOS.
- **Cancelamento:** `interrupt()` com pior caso de 10,45 ms (p50 < 0,3 ms), conexão reutilizável em 100% dos casos. O cancelamento de `Task` já é integrado nas APIs `async` do GRDB 7 (`sqlite3_interrupt` no `onCancel`). Mapear `CancellationError` e `SQLITE_INTERRUPT` para `.cancelled`. Sem processo XPC.
- **Arquivos do usuário: só `DatabaseQueue`.** O `DatabasePool` em leitura e escrita converte o arquivo para WAL de forma persistente; fica restrito ao banco interno do app. Nunca executar `PRAGMA journal_mode` em arquivo do usuário.
- **Somente leitura exige três camadas:** `SQLITE_OPEN_READONLY`, `PRAGMA query_only` e, no driver, rejeição de `Statement.isReadonly == false`, mais `ATTACH` e `PRAGMA query_only` pelo lexer. Nenhuma camada sozinha cobre o corpus (`VACUUM INTO`, `PRAGMA query_only=0; VACUUM INTO`, `ATTACH`).
- **ADR-N21 / PD-02 → opção A:** uma conexão por aba com transação Manual ou execução ativa (`allowsUnsafeTransactions = true` só nelas), mais uma conexão de metadados somente leitura, dentro do orçamento da sessão. A opção B não isola (uma aba fazia COMMIT do trabalho da outra). `busyMode = .timeout(250…1000 ms)`; `SQLITE_BUSY`/`SQLITE_LOCKED` → `.busy`.
- **Execução:** só `Row.fetchCursor` com parada em `maxRows + 1` e `maxBytes`, copiando para `CellValue`; `fetchAll` proibido no caminho de execução (parada em 14 ms, +10 MB sobre 5 M linhas).
- Depois de `.cancelled` ou erro em sessão Manual, consultar `sqlite3_get_autocommit` e emitir `transactionEnded` se a transação sumiu.
- Arquivo WAL sem sidecars aberto em somente leitura falha com `SQLITE_CANTOPEN` → fallback com mensagem clara.

## SPK-N03 — PostgreSQL via PostgresNIO (APROVADO com condições)

PostgresNIO **1.33.1** fixada, usada **só** como transporte (`PostgresConnection`); `PostgresClient` descartado (vaza estado de transação entre leases). O driver implementa:

1. **Cancelamento próprio:** `pg_cancel_backend` numa conexão auxiliar efêmera, guardado pelo marcador `/*rsk:exec=<ExecutionID>*/` no início de cada execução (sem o guarda, o cancel atingiu a consulta seguinte em até 57% das corridas). `Task.cancel()` não cancela no servidor.
2. **Pool próprio** com sonda `DISCARD ALL` na devolução; `25001`/`25P02` → `ROLLBACK` + aviso.
3. **Decodificador próprio** de OID + bytes binários para `CellValue` (os resultados vêm sempre em binário — R-NDRV-09).
4. **Divisor de instruções** obrigatório (só protocolo estendido: `SELECT 1; SELECT 2` dá `42601`).
5. **`COPY … TO STDOUT / FROM STDIN` bloqueados** quando digitados (derrubam a conexão).
6. **Conexão fechada:** checar `isClosed` antes de `query()` — em conexão fechada a chamada trava para sempre (R-NDRV-08). Prazos com continuação não estruturada.

TLS: mínimo TLS 1.2; regra de SNI (DNS → host; IP → `tlsServerName = nil`; nunca IP em `tlsServerName`). Truncamento em `maxRows`: parar, cancelar guardado, sondar antes de devolver, destruir se a sonda não concluir.

## SPK-N08 — layout de quatro regiões (opção A reprovada; híbrido aprovado)

- A opção A (`NavigationSplitView` + `.inspector`) respeita mínimos e máximos, mas falhou em 4 critérios: em janela estreita a janela trava na largura das colunas em vez de reduzi-las; 2 avisos `Unable to simultaneously satisfy constraints` por execução e saltos de largura da janela; sem persistência nativa do inspetor; ordem de Tab errada entre regiões.
- **ADR-N11 → híbrido:** `NSSplitViewController` define as colunas e cada painel é SwiftUI num `NSHostingController` (`sizingOptions = []`). Trilho de 40 pt fora do split. Sidebar 180–420, inspetor 240–520, conteúdo ≥ 400. Persistência por `autosaveName` com `WindowID` ou em `RSKeeperPersistence`. Regras de recolhimento sempre adiadas um ciclo (mudar `isCollapsed` durante o layout gera recursão). Foco entre regiões por `makeFirstResponder` (F6).
- Medido no protótipo: 0 avisos de layout, ordem de Tab correta, persistência exata das larguras, redimensionamento com p95 de 5,6 ms por passo (proxy de 60 fps).
- [A VALIDAR] arrasto real com mouse, live resize pela borda, frame pacing com Instruments, várias janelas com autosave.
- A W0-T29 não usa o layout (workspace vazio), então a onda 0 não é afetada; a NST-05-01 (onda 1) parte do híbrido.

## SPK-N02 — grade `NSTableView` (APROVADO condicional)

`NSTableView` view-based dentro de SwiftUI aguenta 1.000.000 de linhas × 200 colunas, **desde que** o driver da grade cumpra quatro requisitos (emendas à ADR-N09). A versão ingênua reprova (1,2 s até a primeira página).

1. **Virtualização horizontal manual:** o delegate devolve `nil` para colunas fora da área visível ±1 e recarrega só as colunas que entram ou saem. O `NSTableView` cria por padrão uma view para cada coluna de cada linha visível.
2. **Célula leve** que desenha a string; `NSTextField` só durante a edição, iniciada por `makeFirstResponder` (o `editColumn` não inicia com a célula leve).
3. **Uma camada por linha** (`canDrawSubviewsIntoLayer = true` no `NSTableRowView`).
4. **Proibido:** `gridStyleMask` vertical (layout O(n²), quadros de 70–80 ms). **Obrigatório:** `sizeThatFits` no `NSViewRepresentable`.

Medido com 200 colunas: 0 quadros perdidos a 60 Hz; primeira página em 90 ms (meta 100, no limite); pico de 288 MB com cache LRU de 128 MB (meta 300, no limite; a meta "teto do cache + 20 MB" do doc 09 §4 **não** foi atingida e precisa ser recalibrada); 689 views criadas no total; seleção de 500 mil linhas em 24 ms.

- SwiftUI `Table` **rejeitada** (5,5 s e 955 MB para 1M × 200; ~25 fps); cell-based também (~10 fps).
- Teclado: só ↑/↓ nativos funcionam como esperado → mapa de teclado próprio (09 §3.6).
- Acessibilidade: a célula leve precisa expor papel e valor manualmente; `accessibilityRowCount()` devolve 0.
- [INCONCLUSIVO] VoiceOver real e mapa de teclado completo; [A VALIDAR] 120 Hz com Instruments, IME, copiar TSV, reordenar colunas (mapear posição exibida → índice do modelo).
- Para o SPK-N09: página de 500 × 200 ≈ 4 MB em ~4 ms; pré-busca de ±1 página basta.

## Revisão dos contratos da W0-T17/T18 (W0-T32)

Os contratos de driver (`RSKeeperDriversCore/Protocols`) foram revisados contra os SPK-N03 e N05.

| Achado do spike | Contrato atual | Ação |
|---|---|---|
| N03: cancelamento guardado precisa identificar a execução | `BoundStatement` não carregava a execução | **Alterado (v1):** `BoundStatement.executionID: ExecutionID?` (padrão `nil`; compatível) + teste |
| N03: `Task.cancel()` não cancela no PostgreSQL | `CancelMode.server` sem regra | Documentado no tipo: o driver garante que o cancel atinja só a execução alvo |
| N05: cancel da `Task` já chega a `sqlite3_interrupt` | `CancelHandle` | Documentado: o handle serve a prazos e a "cancelar tudo"; depois de `.cancelled`, consultar `transactionState()` |
| N05: rollback implícito após erro/cancel | `transactionState()` já existe | Sem mudança; o driver SQLite o implementa com `sqlite3_get_autocommit` |
| N03: sonda `DISCARD ALL` na devolução | `resetSession()` já existe | Sem mudança; é o ponto de implementação |
| N03/N05: truncamento em `maxRows + 1` e `maxBytes` | `ReadLimits` + `StatementOutcome.rows(truncated:)` | Sem mudança |
| N03: divisor de instruções e bloqueio de `COPY` | `BoundStatement` = "instrução única já separada" | Sem mudança no contrato; implementação no `RSKeeperSQLKit` (onda 1) |
| N03: conexão fechada trava `query()` (R-NDRV-08) | `DriverError.connection` | Sem mudança; regra de implementação do driver PostgreSQL |
| N05: `CancellationError` → `.cancelled` | `DriverError.cancelled` | Sem mudança; mapeamento no driver |

Nenhum driver real foi implementado na onda 0 (fora de escopo).
