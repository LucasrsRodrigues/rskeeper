# Toolchain

| Item | Valor fixado | Onde |
|---|---|---|
| Xcode | **27.0** (correspondência exata) | `.xcode-version` |
| Swift | **6.4** (major.minor) | `EXPECTED_SWIFT_VERSION` em `scripts/check-toolchain.sh` |
| Deployment target | macOS 26.0 | Configurado a partir da W0-T03/W0-T08 |
| Modo de linguagem | Swift 6, concorrência estrita | Configurado a partir da W0-T03 |

Valores observados na máquina de referência em 2026-10-13: Xcode 27.0 (build 27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1), SDK macOS 27.0, macOS 26.6.2, arm64.

## Verificação

```sh
scripts/check-toolchain.sh
```

| Código de saída | Significado |
|---|---|
| 0 | Toolchain conforme |
| 1 | Divergência de versão. A mensagem informa o valor encontrado e o esperado |
| 2 | Erro de ambiente: `.xcode-version` ausente ou vazio, `xcodebuild` ou `swift` ausente, saída ilegível |

Para simular uma divergência, por exemplo em teste ou CI:

```sh
RSK_EXPECTED_XCODE=99.0 scripts/check-toolchain.sh   # sai com 1
RSK_EXPECTED_SWIFT=5.10 scripts/check-toolchain.sh   # sai com 1
```

O script não consulta nem depende da arquitetura da máquina (arm64 ou x86_64), porque o suporte a Intel ainda está pendente (D-N8).

## Atualização do toolchain

1. Abrir um PR dedicado que altera `.xcode-version` e `EXPECTED_SWIFT_VERSION`.
2. Atualizar este documento com os valores observados.
3. Corrigir no mesmo PR os warnings novos da versão nova, porque warnings são tratados como erros.
4. Atualizar a imagem ou o runner de CI para a mesma versão.

## CI

O script é o **primeiro passo** do job de CI. O workflow é criado na W0-T16.
