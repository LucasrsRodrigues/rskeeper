#!/bin/bash
# Seleciona, no runner de CI, o Xcode da versão fixada em .xcode-version (W0-T02/T16).
# Procura em /Applications os nomes usuais (Xcode_27.0.app, Xcode_27.app, Xcode.app…) e confere a
# versão pelo Info.plist. Exporta DEVELOPER_DIR para os passos seguintes (GITHUB_ENV).
# Sem correspondência: lista os Xcodes instalados e sai com 2 (erro de ambiente).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
want="$(tr -d '[:space:]' < "$root/.xcode-version")"
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true; }
found=""
for app in "/Applications/Xcode_$want.app" "/Applications/Xcode_${want%.0}.app" "/Applications/Xcode-$want.app" /Applications/Xcode*.app; do
  [[ -d "$app" ]] || continue
  v="$(version_of "$app")"
  # "27.0" casa com "27.0" e com "27.0.x"; "27" casa com "27.0".
  if [[ "$v" == "$want" || "$v" == "$want".* || "$v.0" == "$want" ]]; then found="$app"; break; fi
done
if [[ -z "$found" ]]; then
  echo "select-xcode: ERRO: Xcode $want não encontrado. Instalados:" >&2
  for app in /Applications/Xcode*.app; do [[ -d "$app" ]] && echo "  $app ($(version_of "$app"))" >&2; done
  exit 2
fi
dir="$found/Contents/Developer"
echo "select-xcode: $found ($(version_of "$found"))"
if [[ -n "${GITHUB_ENV:-}" ]]; then echo "DEVELOPER_DIR=$dir" >> "$GITHUB_ENV"; else echo "export DEVELOPER_DIR=$dir"; fi
