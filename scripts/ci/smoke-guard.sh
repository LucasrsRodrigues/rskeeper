#!/bin/bash
# W0-T31 / NT-SEC-14 em nível de app: o build Test recusa iniciar sem -RSKeeperDataRoot ou com raiz
# fora do temporário (exit 78), e não toca na raiz de dados de produção.
# Uso: scripts/ci/smoke-guard.sh [caminho/para/RSKeeper Test.app]
set -euo pipefail
APP="${1:-.build/xcode-sbYES/Build/Products/Test/RSKeeper Test.app}"
BIN="$APP/Contents/MacOS/RSKeeper Test"
[[ -x "$BIN" ]] || { echo "binário não encontrado: $BIN" >&2; exit 2; }
PROD="$HOME/Library/Application Support/RSKeeper"
before=$( [[ -e "$PROD" ]] && echo exists || echo absent )
fail=0
check() { # descrição, status esperado, argumentos…
  local desc="$1" expected="$2"; shift 2
  set +e; "$BIN" "$@" >/dev/null 2>"${TMPDIR:-/tmp}/rsk-guard.err"; local status=$?; set -e
  if [[ $status -eq $expected ]]; then echo "OK   $desc (exit $status)"; else echo "FAIL $desc (exit $status, esperado $expected)"; cat "${TMPDIR:-/tmp}/rsk-guard.err"; fail=1; fi
}
check "sem -RSKeeperDataRoot" 78
check "raiz fora do temporário" 78 -RSKeeperDataRoot "$HOME/Documents"
check "raiz igual à de produção" 78 -RSKeeperDataRoot "$PROD"
after=$( [[ -e "$PROD" ]] && echo exists || echo absent )
if [[ "$before" == "$after" ]]; then echo "OK   raiz de produção inalterada ($after)"; else echo "FAIL raiz de produção mudou: $before → $after"; fail=1; fi
exit $fail
