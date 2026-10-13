#!/bin/bash
# Avisos como erro: SWIFT_TREAT_WARNINGS_AS_ERRORS vem do xcconfig (alvos do projeto); na linha de
# comando ele atingiria o GRDB (conflito com -suppress-warnings). O pacote é coberto por rsk_check_warnings.
# [build] <Dev|Test|Release> <YES|NO>: build do app com assinatura ad hoc, sem certificados reais.
source "$(dirname "$0")/lib.sh"
config="${1:?configuração}"; sandbox="${2:-YES}"
log="$RSK_LOGS/build-$config-sb$sandbox.log"
xcodebuild -project RSKeeper.xcodeproj -scheme "$(rsk_scheme "$config")" -configuration "$config" \
  -destination 'platform=macOS' -derivedDataPath ".build/xcode-sb$sandbox" \
  RSK_SANDBOX="$sandbox" CODE_SIGN_IDENTITY=- \
  build > "$log" 2>&1 || { tail -40 "$log" >&2; echo "build: FALHOU $config sb$sandbox (log: $log)" >&2; exit 1; }
echo "build: OK $config RSK_SANDBOX=$sandbox"
rsk_check_warnings "$log"
