#!/bin/bash
# Verifica as fronteiras de módulo (W0-T09, NT-UNIT-15).
#  1. Dependências DECLARADAS no Package.swift == declaredDependencies de docs/module-rules.json.
#  2. Imports das fontes (via ArchitectureTests, que varre inclusive blocos #if canImport).
# Requer: swift, jq. Saída: 0 ok; 1 violação; 2 erro de ambiente.
set -euo pipefail
case "$0" in */*) d="${0%/*}" ;; *) d="." ;; esac
root="$(cd "$d/.." && pwd)"
pkg="$root/Packages/RSKeeperKit"
rules="$root/docs/module-rules.json"
command -v jq > /dev/null 2>&1 || { echo "check-boundaries: ERRO: jq não encontrado" >&2; exit 2; }

dump="$(swift package --package-path "$pkg" dump-package 2>/dev/null)" || { echo "check-boundaries: ERRO: dump-package falhou" >&2; exit 2; }

status=0
while IFS= read -r line; do
  target="${line%%|*}"; declared="${line#*|}"
  expected="$(jq -r --arg t "$target" '.modules[$t].declaredDependencies // empty | sort | join(",")' "$rules")"
  if ! jq -e --arg t "$target" '.modules[$t]' "$rules" > /dev/null; then
    echo "check-boundaries: VIOLAÇÃO: alvo $target sem regra em docs/module-rules.json" >&2; status=1; continue
  fi
  if [ "$declared" != "$expected" ]; then
    echo "check-boundaries: VIOLAÇÃO: $target declara [$declared]; esperado [$expected]" >&2; status=1
  fi
done < <(echo "$dump" | jq -r '.targets[] | select(.type=="regular") | "\(.name)|\([.dependencies[] | (.byName // .target // .product)[0]] | map(select(startswith("RSKeeper"))) | sort | join(","))"')

if [ "$status" -eq 0 ]; then
  echo "check-boundaries: dependências declaradas OK"
fi

# Imports: ArchitectureTests (warnings como erro, E-2).
if swift test --package-path "$pkg" --filter ArchitectureTests -Xswiftc -warnings-as-errors > "${TMPDIR:-/tmp}/rsk-boundaries.log" 2>&1; then
  echo "check-boundaries: imports OK (ArchitectureTests)"
else
  grep -E "✘|error:" "${TMPDIR:-/tmp}/rsk-boundaries.log" >&2 || true
  echo "check-boundaries: VIOLAÇÃO: ArchitectureTests falhou (log: ${TMPDIR:-/tmp}/rsk-boundaries.log)" >&2
  status=1
fi
exit "$status"
