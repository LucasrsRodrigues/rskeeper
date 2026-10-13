# Onda 1 — registro de progresso

Plano: [wave-1-plan.md](wave-1-plan.md). Toolchain: Xcode 27.0, Swift 6.4. CI: runner próprio ([ci-runner.md](ci-runner.md)).

## Tarefas

| Tarefa | Estado | Verificação |
|---|---|---|
| W1-T01 SQLKit (NST-04-05) | Concluída | `RSKeeperSQLKitTests`: corpus por dialeto, propriedade de partição (500 casos × 2), 5 MB < 3 s |
| W1-T02 Contrato de stream e conformidade (NST-04-01) | Concluída | `ConformanceTests`: 8 verificações obrigatórias no driver em memória; 4 puladas com motivo (exigem SQL real); teste de sensibilidade |

## Decisões

| ID | Decisão | Motivo |
|---|---|---|
| W1-D01 | Closures de `Task` sem typed throws (`throws(DriverError)`); o erro é normalizado depois com `DriverError.normalized` | O compilador Swift 6.4 travou no IRGen com `Task { () throws(DriverError) -> T in … }` (crash do `swift-frontend`) |
| W1-D02 | `PhysicalConnection` refina `MetadataProvider`; `execute` tem implementação padrão sobre `stream` | A sessão dedica uma conexão a metadados (SPK-N05); um só caminho de leitura com limites |
| W1-D03 | `BatchAccumulator` único para `maxRows`/`maxBytes` | Truncamento idêntico em todos os drivers; a linha `maxRows + 1` só prova que há mais |
| W1-D04 | `SET`/`RESET` de sessão classificados como `transactionControl`; `SET ROLE`/`SESSION AUTHORIZATION` como `unknown` | Executam sem atrito em produção (como a tabela DR-11 trata controle de transação), são recusados em somente leitura; troca de papel exige confirmação |

## Achados

- O CI no runner próprio, com árvore limpa, encontrou 4 avisos em `ComponentTests` que o build incremental escondia (corrigido; registrado em wave-0-exit.md).
