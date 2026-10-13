#!/bin/bash
# Evidências do portão de saída da onda 0 (W0-T32). Roda TODA a sequência do CI localmente e grava
# um resumo em .build/evidence/<data>/summary.txt (os logs completos ficam ao lado).
# Uso: scripts/ci/collect-evidence.sh
source "$(dirname "$0")/lib.sh"
stamp="$(date +%Y%m%d-%H%M%S)"
export RSK_LOGS="$RSK_ROOT/.build/evidence/$stamp"
mkdir -p "$RSK_LOGS"
summary="$RSK_LOGS/summary.txt"
overall=0
step() { # nome, comando…
  local name="$1"; shift
  local out="$RSK_LOGS/step-$name.txt"
  if "$@" > "$out" 2>&1; then echo "PASS  $name" | tee -a "$summary"; else echo "FAIL  $name" | tee -a "$summary"; overall=1; fi
  sed 's/^/        /' "$out" | grep -vE "^\s*$" | tail -12 >> "$summary"
}
{
  echo "RSKeeper — evidências da onda 0 ($stamp)"
  echo "commit: $(git rev-parse --short HEAD) $(git status --porcelain | wc -l | tr -d ' ') arquivo(s) modificados"
  echo "host: $(sw_vers -productVersion) $(uname -m); $(xcodebuild -version | tr '\n' ' '); $(swift --version 2>&1 | head -1)"
  echo
} > "$summary"
step toolchain scripts/check-toolchain.sh
step hygiene scripts/ci/hygiene.sh
step test-kit scripts/ci/test-kit.sh
step boundaries scripts/check-boundaries.sh
step negative-checks scripts/ci/negative-checks.sh
for c in Dev Test Release; do for sb in YES NO; do step "build-$c-sb$sb" scripts/ci/build.sh $c $sb; done; done
for sb in YES NO; do step "test-app-sb$sb" scripts/ci/test-app.sh $sb; step "footprint-sb$sb" scripts/ci/fs-footprint.sh $sb; done
step license-audit scripts/license-audit.sh
for sb in YES NO; do step "artifact-sb$sb" scripts/ci/package-adhoc.sh $sb; done
step log-privacy scripts/ci/log-privacy.sh YES
echo; echo "resultado: $([[ $overall == 0 ]] && echo VERDE || echo VERMELHO) — $summary"
exit $overall
