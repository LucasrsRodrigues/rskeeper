# Contribuindo com o RSKeeper

## Fluxo de trabalho

- Trabalho incremental por tarefa do plano da Onda 0 (`W0-Tnn`) e por história do backlog (`NST-EE-NN`).
- Uma tarefa por branch e por pull request; o PR cita o ID da tarefa/história.
- Nenhuma tarefa avança sem autorização explícita da anterior.

## Regras obrigatórias

### Propriedade intelectual
- O RSKeeper é uma implementação independente.
- **Proibido** adicionar código, CSS, ícones (`bk-icons`), fontes, cores de marca, textos, capturas de tela ou qualquer ativo do Beekeeper Studio.
- **Proibido** copiar evidências da investigação (`work/`, `evidence/`), bundles ou ASAR.
- Comportamentos são reimplementados a partir das especificações, nunca do código original.

### Segurança e privacidade
- Nenhum segredo, certificado, chave, perfil de provisionamento ou `.env` no repositório.
- Nenhuma telemetria.
- Desenvolvimento e testes nunca usam o container nem o Keychain de produção, nem dados reais de usuários.
- Testes usam apenas dados sintéticos.

### Dependências
- Toda dependência nova exige verificação de licença (permitidas: MIT, BSD, Apache-2.0, ISC), manutenção e compatibilidade com Swift 6 / macOS 26.0, registrada no PR.
- Versões fixadas; `Package.resolved` versionado (a partir da W0-T03).

### Qualidade
- Swift 6 com concorrência estrita; warnings tratados como erros (a partir da W0-T03).
- Nenhuma operação bloqueante no `MainActor`.

## Verificação de higiene

Antes de abrir um PR:

```sh
git ls-files | grep -Ei 'beekeeper|bks|asar|evidence'   # deve retornar vazio
```
