#!/bin/bash
# [test-kit]: testes do pacote com avisos como erro (E-2) e checagem de avisos no log (NT-CONC-11).
source "$(dirname "$0")/lib.sh"
log="$RSK_LOGS/test-kit.log"
rsk_ci_keychain
swift test --package-path Packages/RSKeeperKit -Xswiftc -warnings-as-errors 2>&1 | tee "$log" | grep -E "Test run with|✘ Test .* failed|error:" || true
[[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "test-kit: FALHOU (log: $log)" >&2; exit 1; }
rsk_check_warnings "$log"
