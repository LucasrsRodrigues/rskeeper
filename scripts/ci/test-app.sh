#!/bin/bash
# [test-app]: XCUITest de fumaça no build Test + guarda de ambiente (W0-T31).
source "$(dirname "$0")/lib.sh"
sandbox="${1:-YES}"
log="$RSK_LOGS/test-app-sb$sandbox.log"
xcodebuild -project RSKeeper.xcodeproj -scheme RSKeeper-Test -configuration Test \
  -destination 'platform=macOS' -derivedDataPath ".build/xcode-sb$sandbox" \
  RSK_SANDBOX="$sandbox" CODE_SIGN_IDENTITY=- \
  test > "$log" 2>&1 || { grep -E "error:|failed" "$log" | head -20 >&2; echo "test-app: FALHOU (log: $log)" >&2; exit 1; }
grep -E "Test Case .* passed" "$log" | sed 's/^/test-app: /'
rsk_check_warnings "$log"
"$RSK_ROOT/scripts/ci/smoke-guard.sh" ".build/xcode-sb$sandbox/Build/Products/Test/RSKeeper Test.app"
