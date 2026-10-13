#!/bin/bash
# Auditoria de licenças (W0-T16; NT-SEC-17). Requer jq.
#  - Toda pin do Package.resolved está em docs/third-party-licenses.json com a MESMA versão.
#  - A licença registrada está na allowlist.
#  - Se o checkout existir, o texto do LICENSE confirma a licença registrada (heurística por família).
#  - Nenhum binaryTarget no Package.swift.
# Saída: 0 ok; 1 violação; 2 erro de ambiente.
set -euo pipefail
case "$0" in */*) d="${0%/*}" ;; *) d="." ;; esac
root="$(cd "$d/.." && pwd)"
pkg="$root/Packages/RSKeeperKit"
resolved="$pkg/Package.resolved"
registry="$root/docs/third-party-licenses.json"
command -v jq > /dev/null 2>&1 || { echo "license-audit: ERRO: jq não encontrado" >&2; exit 2; }
[ -f "$registry" ] || { echo "license-audit: ERRO: $registry ausente" >&2; exit 2; }

status=0
if grep -q "binaryTarget" "$pkg/Package.swift"; then
  echo "license-audit: VIOLAÇÃO: binaryTarget no Package.swift" >&2; status=1
fi

if [ ! -f "$resolved" ]; then
  echo "license-audit: OK (sem dependências externas)"; exit "$status"
fi

while IFS='|' read -r identity version; do
  entry="$(jq -c --arg id "$identity" '.dependencies[$id] // empty' "$registry")"
  if [ -z "$entry" ]; then
    echo "license-audit: VIOLAÇÃO: $identity $version não registrado em docs/third-party-licenses.json" >&2; status=1; continue
  fi
  regVersion="$(echo "$entry" | jq -r '.version')"
  license="$(echo "$entry" | jq -r '.license')"
  if [ "$regVersion" != "$version" ]; then
    echo "license-audit: VIOLAÇÃO: $identity resolvido em $version, registrado $regVersion" >&2; status=1
  fi
  if ! jq -e --arg l "$license" '.allowedLicenses | index($l)' "$registry" > /dev/null; then
    echo "license-audit: VIOLAÇÃO: $identity com licença $license fora da allowlist" >&2; status=1
  fi
  # Sem checkout (runner limpo), a comparação de texto é pulada; pipefail não pode abortar o script.
  checkout="$( { ls -d "$pkg"/.build/checkouts/* 2>/dev/null || true; } | while read -r c; do
    if [ "$(basename "$c" | tr 'A-Z' 'a-z')" = "$identity" ]; then echo "$c"; fi; done | head -1)"
  if [ -n "$checkout" ]; then
    lic="$(ls "$checkout"/LICENSE* "$checkout"/COPYING* 2>/dev/null | head -1 || true)"
    if [ -n "$lic" ]; then
      if grep -qiE "GNU (AFFERO |LESSER )?GENERAL PUBLIC LICENSE|Server Side Public License" "$lic"; then
        echo "license-audit: VIOLAÇÃO: $identity contém texto GPL/AGPL/LGPL/SSPL em $(basename "$lic")" >&2; status=1
      fi
      case "$license" in
        MIT) grep -q "Permission is hereby granted, free of charge" "$lic" || { echo "license-audit: VIOLAÇÃO: $identity não parece MIT" >&2; status=1; } ;;
        Apache-2.0) grep -q "Apache License" "$lic" || { echo "license-audit: VIOLAÇÃO: $identity não parece Apache-2.0" >&2; status=1; } ;;
      esac
    fi
  fi
done < <(jq -r '.pins[] | "\(.identity)|\(.state.version // "SEM-VERSAO")"' "$resolved")

[ "$status" -eq 0 ] && echo "license-audit: OK ($(jq '.pins | length' "$resolved") dependência(s))"
exit "$status"
