# Onda 1 — registro de progresso

Plano: [wave-1-plan.md](wave-1-plan.md). Toolchain: Xcode 27.0, Swift 6.4. CI: runner próprio ([ci-runner.md](ci-runner.md)).

## Tarefas

| Tarefa | Estado | Verificação |
|---|---|---|
| W1-T01 SQLKit (NST-04-05) | Concluída | `RSKeeperSQLKitTests`: corpus por dialeto, propriedade de partição (500 casos × 2), 5 MB < 3 s |
| W1-T02 Contrato de stream e conformidade (NST-04-01) | Concluída | `ConformanceTests`: 8 verificações obrigatórias no driver em memória; 4 puladas com motivo (exigem SQL real); teste de sensibilidade |
| W1-T04 Driver PostgreSQL (NST-04-03) | Concluída | `RSKeeperDriverPostgreSQLTests` contra PG 14.24, 16.15 e 17.11: **12/12 × 3** verificações de conformidade; corrida de cancelamento (60× por versão, com controle positivo); tipos binários; `COPY` bloqueado; estados de transação; erros de conexão; metadados |
| W1-T05 PostgreSQL de teste e job de drivers | Concluída | `scripts/ci/pg-test.sh`, `scripts/ci/test-drivers.sh` (falha se uma suíte de driver for pulada); job `drivers-containers` ativado no CI |
| W1-T06 Repositórios de perfis, pastas e fixadas (NST-02-03) | Concluída | `ProfileRepositoryTests` (7): ida e volta, conflito de revisão, nome único por pasta, recentes sem mudar revisão, fixar/desafixar, pasta excluída, observação entre "janelas", banco só leitura; migração V2 com dados preservados |
| W1-T07 Executar e cancelar (NST-07-02) | Concluída | `ExecuteQueryTests` (6, com SQLite real): NT-DRV-09 (falha na 2ª de 3), BEGIN…COMMIT/ROLLBACK e ROLLBACK TO, Auto desfaz BEGIN aberto com aviso, DR-06, busy na mesma aba, cancelamento ≤ 1 s pela sessão; plano (atual, seleção, parâmetros, somente leitura, COPY) |
| W1-T08 Confirmação de risco (NST-07-04, ampliada) | Concluída | `PolicyTests`: matriz DR-11 (18 casos), ambientes não produtivos, contornos por comentário/caixa/CTE; token na sessão com SQLite real: sem token recusa, uso único, outra aba, outro digest (instrução e parâmetro), expiração, nome digitado em produção, somente leitura |
| W1-T09 ResultStore (NST-07-03, núcleo) | Concluída | `ResultStoreTests` (6): páginas por linhas e bytes, LRU só em abas inativas (`.evicted`), TTL (`.expired`) com relógio manual, liberação por nova execução e fechamento, orçamento do processo reduz `maxBytes`, 50.000 × 50 em < 2 s |
| W1-T10 Recuperação de falhas e autosave (NST-01-05) | Concluída | `RecoveryTests` (4): debounce/flush/aba fechada; boot depois de encerramento forçado restaura abas e texto não salvo; conexão perdida → evento, recusa até reconectar, escrita não repetida; transação manual nunca "ativa" após queda. PG real: `pg_terminate_backend` → `.connection` em 0,4 s (R-NDRV-08) |
| W1-T11 Comandos e menus (NST-13-01) | Concluída | `CommandRegistryTests` (4): unicidade de IDs e atalhos, atalhos do doc 10 §6.2, habilitação por estado, contexto da janela; XCUITest: sem conexão, "Executar tudo", "Cancelar execução" e "Desconectar" desabilitados, "Nova conexão…" habilitado |
| W1-T03 Driver SQLite (NST-04-02) | Concluída | `RSKeeperDriverSQLiteTests`: **12/12** verificações de conformidade (nenhuma pulada); NT-DRV-12 (journal e sidecars); WAL sem sidecars em somente leitura; isolamento entre conexões; tipos; redação |

## Decisões

| ID | Decisão | Motivo |
|---|---|---|
| W1-D01 | Closures de `Task` sem typed throws (`throws(DriverError)`); o erro é normalizado depois com `DriverError.normalized` | O compilador Swift 6.4 travou no IRGen com `Task { () throws(DriverError) -> T in … }` (crash do `swift-frontend`) |
| W1-D02 | `PhysicalConnection` refina `MetadataProvider`; `execute` tem implementação padrão sobre `stream` | A sessão dedica uma conexão a metadados (SPK-N05); um só caminho de leitura com limites |
| W1-D03 | `BatchAccumulator` único para `maxRows`/`maxBytes` | Truncamento idêntico em todos os drivers; a linha `maxRows + 1` só prova que há mais |
| W1-D04 | `SET`/`RESET` de sessão classificados como `transactionControl`; `SET ROLE`/`SESSION AUTHORIZATION` como `unknown` | Executam sem atrito em produção (como a tabela DR-11 trata controle de transação), são recusados em somente leitura; troca de papel exige confirmação |

| W1-D05 | `allowsUnsafeTransactions = true` em toda conexão do driver SQLite | O driver não conhece o modo da aba; a sessão encerra transações abandonadas no modo Auto com `resetSession` (DR-17). O SPK-N05 sugeria só nas abas em Manual |
| W1-D06 | `foreignKeysEnabled = false` no driver SQLite | O driver não muda o comportamento do arquivo do usuário: chaves estrangeiras como no padrão do SQLite |
| W1-D07 | O driver SQLite declara dependência do `RSKeeperSQLKit` | Camada 3 do somente leitura e tag de comando; as regras de fronteira já permitiam o import |

| W1-D08 | PostgreSQL: instruções que podem devolver linhas usam o `query` assíncrono (contrapressão); as demais, a variante com callback (tag e linhas afetadas) | A PostgresNIO não expõe a tag de comando no `query` assíncrono |
| W1-D09 | Contrato v1.1: `cancelHandle(for: ExecutionID)`; a sessão manda o `ExecutionID` em toda instrução | DR-18: a alça precisa mirar uma execução. A alça genérica atingia a consulta seguinte (achado do teste de corrida) |
| W1-D10 | Licenças de código embutido em lista própria (`allowedEmbeddedLicenses`: ISC, OpenSSL), **pendente de confirmação** | BoringSSL dentro de swift-nio-ssl/swift-crypto; premissa da D-W1-2 ("só Apache-2.0 ou MIT") era imprecisa |

| W1-D11 | Migração V2 `pinned_position` no perfil para as conexões **fixadas** da sidebar; fixar e usar não mudam a revisão | A tabela `pin` da V1 é de entidades do explorador; a NST-03-01 pede conexões fixadas. Organização da sidebar não pode invalidar uma edição em outra janela. O repositório de entidades fixadas fica para quando o explorador tiver fixação (fora dos critérios da onda 1) |

| W1-D12 | Scripts rodam numa única conexão; `committed` decidido pelo estado real de transação, resolvido quando a transação fecha (COMMIT efetiva, ROLLBACK desfaz) | DR-13: "o que foi efetivado" precisa ser verdade, inclusive com BEGIN/COMMIT dentro do script |
| W1-D13 | `PlaceholderStyle` do SQLKit renomeado para `SQLPlaceholderStyle` | Os enums marcadores com o nome do módulo impedem qualificar `Módulo.Tipo`; os dois tipos eram nossos |

| W1-D14 | `SessionRegistry.open` exige `policy:`; a política é reaplicada em `executeScript` | Nenhum chamador pode esquecer o ambiente de produção; contornar a UI não basta. `execute` (instrução única) fica para leituras internas (páginas, metadados) e não passa pela política — risco registrado |

| W1-D15 | Autosave grava também o registro mínimo da aba (`tab`) junto com o rascunho | `draft.tab_id` referencia `tab`, e o critério 2 pede restaurar as abas, não só o texto; `TabKind` mínimo no Domain (consulta, tabela) |

| W1-D16 | ⌘W/⌘T (abas) só entram na W1-T20; F5/⇧F5 ficam com o editor (W1-T21) via `performKeyEquivalent` | Ligar ⌘W antes da barra de abas roubaria o "Fechar janela"; o SwiftUI só aceita um atalho por item de menu |
| W1-D17 | CI enfileira runs (`cancel-in-progress: false`) | Com um runner, cancelar deixava commits enviados sem validação |

## Achados

- O CI no runner próprio, com árvore limpa, encontrou 4 avisos em `ComponentTests` que o build incremental escondia (corrigido; registrado em wave-0-exit.md).
- **Texto com NUL (NT-DRV-04):** o GRDB liga e lê `String` como string C, cortando no primeiro NUL. O driver SQLite liga textos com NUL pelo comprimento e lê texto por `sqlite3_column_bytes`.
- **Cancelamento × stream:** cancelar a `Task` consumidora encerra o `AsyncThrowingStream` sem erro. `StatementOutcome.collect` passou a devolver `.cancelled` nesse caso.
- **PID lido errado (PostgreSQL):** `pg_backend_pid()` decodificado como `String` sobre o formato binário dava lixo; o PID virava 0 e o cancelamento guardado nunca agia. O teste de corrida passava **trivialmente**. Correção: `::text`, conexão recusada sem PID e controle positivo no teste.
- **Suíte de conformidade:** pedia a alça geral antes de a execução começar; corrigida para pedir com a execução em curso, como a sessão faz.
- **Primeiro run completo do CI no GitHub (runner próprio): 16/16 verde** (run 38483217094).
- **Gate mascarado (erro meu):** no commit da W1-T04 rodei `check-boundaries.sh | tail -1`; o pipe escondeu a linha de violação (regra do driver PostgreSQL sem `RSKeeperSQLKit`) e trocou o código de saída pelo do `tail`. O commit dizia "fronteiras OK" sem a verificação ter passado. O CI no GitHub reprovou (run 38486274021); regra corrigida. Desde então os gates rodam sem pipe e com o código de saída conferido.
- **Job de drivers no GitHub:** passou na primeira execução (PostgreSQL 14/16/17 no Docker do runner próprio).
