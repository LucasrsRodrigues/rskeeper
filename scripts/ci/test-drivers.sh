#!/bin/bash
# [test-drivers] (W1-T05; NST-00-04 crit. 2): conformidade dos drivers contra bancos reais e descartáveis.
# Sobe PostgreSQL 14/16/17 (scripts/ci/pg-test.sh), roda os testes dos drivers e SEMPRE derruba os containers.
# Falha se alguma suíte de driver for pulada: pular nunca conta como aprovação.
source "$(dirname "$0")/lib.sh"
log="$RSK_LOGS/test-drivers.log"
trap '"$RSK_ROOT/scripts/ci/pg-test.sh" down > /dev/null 2>&1 || true' EXIT
"$RSK_ROOT/scripts/ci/pg-test.sh" up 14 16 17
eval "$("$RSK_ROOT/scripts/ci/pg-test.sh" env)"
export RSK_PG_PORTS RSK_PG_PASSWORD
swift test --package-path Packages/RSKeeperKit --filter "RSKeeperDriver" -Xswiftc -warnings-as-errors > "$log" 2>&1 || {
  sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E "✘|error:" | head -30 >&2
  echo "test-drivers: FALHOU (log: $log)" >&2; exit 1; }
clean="$(sed 's/\x1b\[[0-9;]*m//g' "$log")"
if echo "$clean" | grep -qE "Suite .* skipped|Test .* skipped"; then
  echo "$clean" | grep -E "skipped" >&2
  echo "test-drivers: VIOLAÇÃO: suíte de driver pulada" >&2; exit 1
fi
echo "$clean" | grep -E "with [0-9]+ test cases passed" | sed 's/^/test-drivers: /'
rsk_check_warnings "$log"
