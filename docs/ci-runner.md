# Runner de CI próprio

As imagens macOS do GitHub não têm o Xcode 27 (`.xcode-version`), então o CI roda num **runner self-hosted** neste Mac de desenvolvimento.

| Item | Valor |
|---|---|
| Diretório | `~/actions-runner-rskeeper` (runner oficial `actions/runner` v2.338.0 osx-arm64, SHA-256 verificado) |
| Rótulos | `self-hosted, macOS, ARM64, rskeeper-xcode27` |
| Serviço | LaunchAgent `actions.runner.LucasrsRodrigues-rskeeper.<nome>` (`./svc.sh start/stop/status`) |
| Sessão | `SessionCreate = false`: roda na sessão de login, para o Keychain (testes do `SecretStore`) e os XCUITests |
| Docker | Docker Desktop deste Mac (PostgreSQL de teste a partir da Onda 1) |

## Segurança (repositório público)

- PR vindo de fork **nunca** roda no runner: o job `toolchain` é pulado e todos os outros dependem dele.
- O repositório exige aprovação para workflows de **qualquer** colaborador externo (`fork-pr-contributor-approval = all_external_contributors`).
- Sem segredos no workflow; sem certificados; sem publicação.
- Os jobs rodam com o seu usuário. Só código deste repositório, de quem tem permissão de push, chega ao runner.

## Remover

```sh
cd ~/actions-runner-rskeeper && ./svc.sh stop && ./svc.sh uninstall
./config.sh remove --token "$(gh api -X POST repos/LucasrsRodrigues/rskeeper/actions/runners/remove-token --jq .token)"
```

Depois, apague `~/actions-runner-rskeeper`.
