# RSKeeper

Cliente de banco de dados nativo para macOS, escrito em Swift 6 com SwiftUI e AppKit.

> **Estado:** Onda 0, tarefa **W0-T01** (repositório e higiene). Ainda não há código de aplicação, projeto Xcode nem dependências.

## Plataforma (decisões aprovadas)

| Item | Valor |
|---|---|
| Deployment target | macOS 26.0 (D-N1) |
| Linguagem | Swift 6, concorrência estrita |
| UI | SwiftUI + AppKit |
| Arquitetura de desenvolvimento | Apple silicon (arm64) prioritário; suporte a Intel pendente (D-N8) — não presumir arm64 exclusivo |
| Distribuição | Site próprio, fora da Mac App Store; Developer ID, Hardened Runtime, notarização (D-N2) |
| App Sandbox | Decisão técnica pendente (SPK-N07) |
| Atualização automática | Não implementada (D-N9 pendente) |
| Telemetria | **Nenhuma** |
| Licenciamento comercial / pagamentos | Não existe |

### Bundle IDs (provisórios — D-N3)

| Ambiente | Bundle ID |
|---|---|
| Produção | `app.rskeeper.RSKeeper` |
| Desenvolvimento | `app.rskeeper.RSKeeper.dev` |
| Testes | `app.rskeeper.RSKeeper.test` |

O nome **RSKeeper** é de trabalho; a verificação de marca (D-N5) é obrigatória antes de qualquer publicação.

## Origem e regras de propriedade intelectual

O RSKeeper é uma implementação **independente**. O planejamento (requisitos, arquitetura, backlog) foi produzido num repositório de investigação separado, que **não** faz parte deste repositório.

Este repositório **nunca** deve conter:

- código, CSS, ícones (incluindo `bk-icons`), fontes, cores de marca, textos ou outros ativos do Beekeeper Studio;
- evidências da investigação (`work/`, `evidence/`), bundles, ASAR ou capturas de tela do produto original;
- dados reais de usuários, credenciais, chaves ou certificados.

Veja [CONTRIBUTING.md](CONTRIBUTING.md) e o índice de decisões em [docs/ADR-INDEX.md](docs/ADR-INDEX.md).

## Licença

Ainda não definida — ver [LICENSE](LICENSE).
