#!/bin/bash
# NT-SEC-05 (versão da onda 0). Artefato .app ad hoc (portão §4 item 6): Hardened Runtime verificado por codesign, entitlements
# iguais à allowlist da variante, sem get-task-allow. Saída em dist/ (fora do git).
source "$(dirname "$0")/lib.sh"
sandbox="${1:-YES}"
app=".build/xcode-sb$sandbox/Build/Products/Release/RSKeeper.app"
[[ -d "$app" ]] || { echo "package: ERRO: rode antes scripts/ci/build.sh Release $sandbox" >&2; exit 2; }
status=0
codesign --verify --deep --strict "$app" || { echo "package: VIOLAÇÃO: assinatura inválida" >&2; status=1; }
info="$(codesign -dv "$app" 2>&1)"
echo "$info" | grep -q "flags=.*runtime" || { echo "package: VIOLAÇÃO: Hardened Runtime ausente" >&2; status=1; }
echo "$info" | grep -q "Signature=adhoc" || { echo "package: VIOLAÇÃO: esperado ad hoc (sem certificados reais)" >&2; status=1; }
variant=$([[ $sandbox == YES ]] && echo sandboxed || echo direct)
expected="$(plutil -convert json -o - "App/RSKeeper.$variant.entitlements" | jq -S 'keys')"
actual="$(codesign -d --entitlements :- "$app" 2>/dev/null | plutil -convert json -o - - 2>/dev/null | jq -S 'keys' || echo '[]')"
[[ "$expected" == "$actual" ]] || { echo "package: VIOLAÇÃO: entitlements $actual ≠ allowlist $expected" >&2; status=1; }
echo "$actual" | grep -q get-task-allow && { echo "package: VIOLAÇÃO: get-task-allow no Release" >&2; status=1; }
[[ $status -eq 0 ]] || exit 1
mkdir -p dist
out="dist/RSKeeper-wave0-adhoc-sb$sandbox.zip"
rm -f "$out"; ditto -c -k --keepParent "$app" "$out"
echo "package: OK $(echo "$info" | grep -E '^(Identifier|CodeDirectory|Signature)' | tr '\n' ' ')"
echo "package: entitlements = $(echo "$actual" | jq -c .)"
echo "package: artefato $out ($(du -h "$out" | cut -f1))"
