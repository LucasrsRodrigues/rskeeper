# Onda 1 — plano de execução (fatia vertical)

**Status: PROPOSTA, aguardando aprovação.** Este plano segue o formato do plano da Onda 0. A fonte das histórias e dos critérios de aceite é o backlog e o roadmap do blueprint: `docs/native/11` §4 e `docs/native/15` "Onda 1", no repositório de investigação. Aqui ficam só a quebra em tarefas, a ordem, as emendas dos spikes e as decisões pendentes.

**Objetivo:** provar a arquitetura de ponta a ponta no fluxo **conectar → explorar → abrir tabela → consultar**, com SQLite e PostgreSQL, usando só o teclado.

**Escopo:** 22 histórias, 140 pontos.
- NST-01-05, 02-03;
- NST-03-01…05;
- NST-04-01, 04-02, 04-03, 04-05;
- NST-05-01…03, 06-01;
- NST-07-01…04;
- NST-08-01, 08-02;
- NST-13-01.

**Fora do escopo:** MySQL, TLS e SSH (as linhas do formulário aparecem desabilitadas), autocomplete, edição de dados, transações manuais na UI, histórico, consultas salvas, Command Palette e estrutura de tabela. Tudo isso é das ondas 2 e 3.

## 0. Emendas dos spikes ao backlog

O texto do backlog foi escrito antes dos spikes. Onde ele diverge, **valem os vereditos** registrados em [spikes/README.md](spikes/README.md):

| História | Texto do backlog | Vale (spike) |
|---|---|---|
| NST-04-02 | "`DatabaseQueue`/`DatabasePool` por arquivo" | **Só `DatabaseQueue`** para arquivos do usuário; somente leitura em 3 camadas; nunca `PRAGMA journal_mode` (N05) |
| NST-04-03 | "`PostgresClient` como pool"; "cancel request do protocolo" | **`PostgresConnection` + pool próprio** com sonda `DISCARD ALL`; cancelamento por `pg_cancel_backend` guardado pelo marcador `/*rsk:exec=<id>*/`; decodificador binário próprio; guarda de `isClosed`; `COPY` bloqueado (N03) |
| NST-03-03 | — | `CFBundleDocumentTypes` com `NSIsRelatedItemType` para `-wal`, `-shm` e `-journal`; grant de pasta como alternativa (N07) |
| NST-05-01 | "`NavigationSplitView` + `.inspector`" | **`NSSplitViewController`** com painéis SwiftUI (`sizingOptions = []`); trilho fora do split; recolher adiado um ciclo (N08) |
| NST-07-01 | "tree-sitter ou CodeEditSourceEditor" | **Lexer do `RSKeeperSQLKit`** como rendering attributes, só no viewport; quebra de linha suave como padrão; linha do cursor para acessibilidade por tabela de linhas (N01) |
| NST-08-01 | "`NSTableView` view-based" | Mais os 4 requisitos: virtualização horizontal, célula leve, uma camada por linha, sem grade vertical; mapa de teclado próprio (N02) |
| NST-07-04 | `RiskPolicy` (5 pts) | `OperationPolicyEngine` central, com políticas fixas por ambiente (Fase 4.2, 8 pts) |

## 1. Tarefas

As tarefas estão agrupadas em quatro trilhas. Cada uma termina com testes verdes, zero avisos e um commit.

### Trilha A — SQL e drivers

| Tarefa | História | Entrega | Testes principais |
|---|---|---|---|
| W1-T01 | NST-04-05 | `SQLLexer` por dialeto (SQLite e PG: aspas, comentários aninhados, `$tag$`, `E'…'`), `StatementSplitter`, `RiskClassifier` (6 valores), `ParameterScanner`, `ConnectionURLParser` | Corpus por dialeto; propriedade "dividir e juntar preserva o texto"; contornos (comentário, caixa mista, CTE com `DELETE`, `COPY`) |
| W1-T02 | NST-04-01 | Contrato de execução em stream (lotes colunares), `MetadataProvider` completo, declaração de capacidades (`explain`, `health`, `introspection`); **suíte de conformidade** em `RSKeeperTesting`, aplicada também ao `InMemoryDriver` | NT-DRV: conexão, metadados, truncamento durante a leitura, cancelamento, consulta após cancelar, quoting, bind, erros |
| W1-T03 | NST-04-02 | Novo alvo `RSKeeperDriverSQLite` (GRDB), com regras de fronteira atualizadas | Conformidade completa; 5 M de linhas sob o teto; `journal_mode` inalterado; isolamento entre abas; corpus de somente leitura |
| W1-T04 | NST-04-03 | Novo alvo `RSKeeperDriverPostgreSQL` (PostgresNIO 1.33.1 exato), com as 6 condições do N03 e a regra de SNI e TLS 1.2 (TLS só na onda 2) | Conformidade contra PG real; cancelamento em corrida (marcador); vazamento de `BEGIN`; tipos (`numeric`, `int8`, `jsonb`, `bytea`, `timestamptz`, arrays); matriz 14, 16 e 17 |
| W1-T05 | NST-00-04 (crit. 2) | Infraestrutura de PostgreSQL para testes (ver **D-W1-1**); job de drivers do CI **ativado** | O job roda a conformidade nas 3 versões |

### Trilha B — aplicação e persistência

| Tarefa | História | Entrega | Testes principais |
|---|---|---|---|
| W1-T06 | NST-02-03 | `ProfileRepository`, `FolderRepository`, `PinRepository`; `ValueObservation` no MainActor; `expectedRevision` obrigatório | Repositórios em memória; conflito de revisão; observação entre janelas |
| W1-T07 | NST-07-02 | `ExecuteQueryUseCase`; `DatabaseSession.execute(statements:tab:mode:)`; parada na primeira falha com status por instrução; idempotência por `ExecutionID` | Segunda execução na mesma aba → `busy`; ID repetido; desfecho `committed` sim, não ou desconhecido |
| W1-T08 | NST-07-04 | `OperationPolicyEngine` + `ConfirmationToken` (60 s, consumo atômico, digest) | Matriz ambiente × risco × somente leitura; replay, outra aba e outro digest; chamada direta sem UI bloqueada |
| W1-T09 | NST-07-03 (núcleo) | `actor ResultStore` por janela: páginas colunares, orçamento em 3 níveis, expiração com motivo | Expiração e LRU; memória sob o teto com 50.000 × 50 |
| W1-T10 | NST-01-05 | `DraftAutosaver` (debounce de 1 s e no encerramento); `SessionLost` em `AsyncStream`; restauração no boot | `kill -9` durante a edição → texto restaurado; transação interrompida nunca aparece como ativa |
| W1-T11 | NST-13-01 | `CommandRegistry` (id, título, atalho, habilitação) + `Commands` roteados por `focusedSceneValue` | Habilitação por estado; roteamento com duas janelas |

### Trilha C — interface

| Tarefa | História | Entrega |
|---|---|---|
| W1-T12 | NST-03-01 | Tela de conexão: sidebar (fixadas, salvas, recentes, com contadores), filtro, boas-vindas, barra de cor do rótulo, teclado |
| W1-T13 | NST-03-02 | Seletor de driver (só os registrados), com busca e teclado |
| W1-T14 | NST-03-03 | Formulário SQLite: painel e arraste, bookmark, somente leitura, related items no `Info.plist` |
| W1-T15 | NST-03-04 | Formulário de servidor (ordem de campos do CAP-01; TLS e SSH desabilitados), importação de URL; a senha colada vai só para o rascunho de segredo |
| W1-T16 | NST-03-05 | Testar e conectar: `TestConnectionUseCase`, timeout de 15 s, cancelar, erros distintos, troca para o workspace e título da janela |
| W1-T17 | NST-05-01 | Shell híbrido de quatro regiões: larguras persistidas por janela, recolher, regras de janela estreita, foco por F6 |
| W1-T18 | NST-05-02 | Explorador em `NSOutlineView`: carga sob demanda, cache por (sessão, database, schema), filtro, type-select, 10.000 tabelas sem travar |
| W1-T19 | NST-05-03 | Barra de status e menu de conexão (desconectar, trocar, salvar); ambiente em texto |
| W1-T20 | NST-06-01 | Barra de abas (`query` e `table`): ponto de não salvo, ⌘T e ⌘W, confirmação ao fechar, transbordo |
| W1-T21 | NST-07-01 | Editor TextKit 2: realce pelo lexer, régua, linha atual, `NSTextFinder`, undo, estado vazio com atalhos do registro, acessibilidade |
| W1-T22 | NST-08-01 | Grade: os 4 requisitos do N02, mapa de teclado próprio, cópia em TSV, CSV, JSON e Markdown, acessibilidade da célula leve |
| W1-T23 | NST-07-03 (UI) | Painel de resultados: vários conjuntos, contagens e tempo, truncamento, "Resultado liberado" sem reexecução, copiar erro |
| W1-T24 | NST-08-02 | Aba de tabela: paginação (100 linhas, no máximo 1.000), ordenação no servidor, cabeçalho com tipo e chave primária, ⌘⌥← e ⌘⌥→ |

### Trilha D — portão

| Tarefa | Entrega |
|---|---|
| W1-T25 | XCUITest ponta a ponta **só com teclado**, com SQLite e PG: criar perfil, conectar, explorar, abrir tabela, ordenar, executar tudo, a atual e a seleção, cancelar |
| W1-T26 | Bancada NT-PERF: grade de 50.000 × 30, tecla com 5 MB, cancelamento ≤ 1 s, hangs acima de 250 ms (os números do CI são indicativos; fps exato fica no Instruments, manual) |
| W1-T27 | Portão de saída (`docs/wave-1-exit.md`), com a coleta de evidências ampliada e a atualização da matriz de paridade **só** pelas linhas cobertas por esses testes |

## 2. Ordem e dependências

```
A: T01 ─► T02 ─► T03 ─┬─► T04 ─► T05
                      │
B: T06   T07 ─► T08   T09   T10   T11        (T07 precisa de T01 e T02)
                      │
C: T12 ─► T13 ─► T14 ─► T15 ─► T16 (precisa de T03 e T04)
   T17 ─► T18 (precisa de T03) ─► T19 ─► T20 ─► T21 ─► T22 ─► T23 ─► T24
D: T25 ─► T26 ─► T27  (depois de tudo)
```

**Caminho crítico:** T01 → T02 → T03 → T04, T07 → T21 → T22 → T23 → T24 → T25. O editor (13 pts) e a grade (13 pts) são os itens mais caros e começam assim que o shell (T17) existir.

## 3. Decisões que dependem de você

| ID | Decisão | Recomendação |
|---|---|---|
| **D-W1-1** | Como rodar o PostgreSQL de teste. Os runners macOS do GitHub **não têm Docker**, e os testes do driver precisam de macOS (o pacote é só macOS 26) | **Local:** Docker Desktop (já instalado; o N03 usou), containers `--rm` e só dados sintéticos. **CI:** PostgreSQL 14, 16 e 17 via Homebrew no runner macOS, cada versão numa porta e num diretório temporário. Nenhum serviço externo |
| **D-W1-2** | Dependências novas da PostgresNIO (swift-nio, nio-ssl, nio-transport-services, swift-crypto, swift-log, swift-collections, swift-atomics, swift-service-lifecycle, swift-metrics etc.) | Aceitar com **versões exatas** no `Package.resolved`; todas Apache-2.0 ou MIT, registradas na auditoria de licenças antes do primeiro commit |
| **D-W1-3** | Menus sem captura (split button, botão de conexão, nova aba) | Seguir como `[DECISÃO]` do backlog, com itens mínimos, e ajustar se as capturas chegarem |
| **D-W1-4** | Critérios que exigem validação manual (VoiceOver nos 4 fluxos e fps no Instruments) | Checklist manual no portão de saída, como na Onda 0; o portão só é "aprovado" com ele feito |

## 4. Portão de saída

Igual ao de `docs/native/15` "Onda 1":
1. ponta a ponta só com teclado;
2. NT-DRV completo nos dois drivers;
3. NT-PERF;
4. NT-CONC: isolamento entre janelas, uma execução por aba, token de risco;
5. recuperação depois de `kill -9`;
6. paridade atualizada só pelos testes.

Também precisam passar as pendências manuais da Onda 0 (P-04).

## 5. Riscos

| Risco | Mitigação |
|---|---|
| Editor e grade mais caros que o previsto | Escopo mínimo do backlog; os protótipos dos spikes N01 e N02 servem de **referência de medida**, não são copiados (regra dos spikes) |
| Cancelamento PG atingindo a consulta errada | Marcador guardado + teste de corrida com 1.000 repetições na conformidade |
| Tempo de CI alto (5 M de linhas, 3 versões de PG) | O truncamento de 5 M roda só no job de drivers; o resto usa fixtures menores |
| PostgresNIO com avisos de concorrência no Swift 6.4 | O N03 mediu 0 avisos; `@preconcurrency` só com registro (R-W0-01) |
| Homebrew sem uma das versões antigas de PG no runner | Fixar as fórmulas `postgresql@14/16/17`; se faltar uma, o job falha cedo com mensagem clara |
