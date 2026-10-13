#!/bin/bash
# Higiene do repositório (W0-T01 aceite 2; portão §4 item 8): nenhum ativo/evidência do Beekeeper
# Studio, nenhum ASAR, nenhuma credencial versionada.
source "$(dirname "$0")/lib.sh"
status=0
names="$(git ls-files | grep -Ei 'beekeeper|bks|\.asar$|(^|/)evidence/|(^|/)work/' || true)"
[[ -z "$names" ]] || { echo "hygiene: VIOLAÇÃO: arquivos proibidos:"; echo "$names"; status=1; } >&2
secrets="$(git ls-files | grep -Ei '\.(p12|p8|cer|mobileprovision|provisionprofile|keychain-db)$|(^|/)\.env' || true)"
[[ -z "$secrets" ]] || { echo "hygiene: VIOLAÇÃO: possíveis credenciais:"; echo "$secrets"; status=1; } >&2
# Conteúdo: o nome do produto investigado só pode aparecer nos arquivos que DECLARAM a proibição
# (allowlist explícita; qualquer arquivo novo com a menção reprova e exige revisão).
content="$(git grep -Il -i 'beekeeper' -- . ':!scripts/ci/hygiene.sh' ':!.github/pull_request_template.md' \
  ':!CONTRIBUTING.md' ':!README.md' ':!docs/**' ':!design/tokens.json' \
  ':!Packages/RSKeeperKit/Tests/RSKeeperDesignSystemTests/TokenTests.swift' || true)"
[[ -z "$content" ]] || { echo "hygiene: VIOLAÇÃO: menção ao produto investigado em código:"; echo "$content"; status=1; } >&2
# Imagens versionadas: só o ícone próprio e as referências de snapshot.
images="$(git ls-files | grep -Ei '\.(png|jpe?g|gif|heic|tiff?)$' | grep -vE '^App/Resources/Assets\.xcassets/AppIcon\.appiconset/|/__Snapshots__/' || true)"
[[ -z "$images" ]] || { echo "hygiene: VIOLAÇÃO: imagens fora da allowlist:"; echo "$images"; status=1; } >&2
[[ $status -eq 0 ]] && echo "hygiene: OK ($(git ls-files | wc -l | tr -d ' ') arquivos versionados)"
exit $status
