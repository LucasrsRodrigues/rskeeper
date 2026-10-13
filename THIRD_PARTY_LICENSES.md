# Licenças de terceiros

| Dependência | Versão | Licença | Uso |
|---|---|---|---|
| [grdb.swift](https://github.com/groue/GRDB.swift) | 7.11.1 (exata) | MIT | RSKeeperPersistence |
| [postgres-nio](https://github.com/vapor/postgres-nio) | 1.33.1 (exata) | MIT | RSKeeperDriverPostgreSQL |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.3 (exata) | Apache-2.0 | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |
| [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) | 1.1.7 (exata) | Apache-2.0 | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 (exata) | Apache-2.0 | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |
| [swift-collections](https://github.com/apple/swift-collections) | 1.7.3 (exata) | Apache-2.0 | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |
| [swift-crypto](https://github.com/apple/swift-crypto) | 4.5.2 (exata) | Apache-2.0 + código embutido: ISC, OpenSSL | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |
| [swift-log](https://github.com/apple/swift-log) | 1.16.1 (exata) | Apache-2.0 | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |
| [swift-metrics](https://github.com/apple/swift-metrics) | 2.12.0 (exata) | Apache-2.0 | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |
| [swift-nio](https://github.com/apple/swift-nio) | 2.104.0 (exata) | Apache-2.0 | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |
| [swift-nio-ssl](https://github.com/apple/swift-nio-ssl) | 2.37.5 (exata) | Apache-2.0 + código embutido: ISC, OpenSSL | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |
| [swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services) | 1.28.0 (exata) | Apache-2.0 | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |
| [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) | 2.12.1 (exata) | Apache-2.0 | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |
| [swift-system](https://github.com/apple/swift-system) | 1.8.1 (exata) | Apache-2.0 | RSKeeperDriverPostgreSQL (transitiva da PostgresNIO) |

O registro verificável fica em `docs/third-party-licenses.json`. O `scripts/license-audit.sh` falha se uma dependência do `Package.resolved` não estiver registrada, tiver outra versão, usar licença fora da allowlist (MIT, BSD, Apache-2.0, ISC) ou embutir código com licença fora de `allowedEmbeddedLicenses`.

## Código embutido: BoringSSL

`swift-nio-ssl` e `swift-crypto` (dependências obrigatórias da PostgresNIO) contêm código do BoringSSL, sob a combinação das licenças **ISC** e **OpenSSL/SSLeay**. As duas são permissivas, mas a OpenSSL/SSLeay exige aviso de atribuição na distribuição.

> **Pendente de confirmação do responsável antes de qualquer distribuição** (W1-T04, 2026-10-13). Nesta onda não há distribuição.

Fontes e ícones do sistema (SF Pro, SF Mono, SF Symbols) são usados pelas APIs da Apple e não são redistribuídos.
