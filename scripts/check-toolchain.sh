#!/bin/bash
# Verifica se o toolchain local corresponde ao fixado no repositório (W0-T02).
#
# - Xcode: comparação EXATA com o conteúdo de `.xcode-version`.
# - Swift: comparação por major.minor com EXPECTED_SWIFT_VERSION.
# Não depende de arquitetura (arm64 ou x86_64).
#
# Variáveis de ambiente (opcionais, para CI e para simular divergências):
#   RSK_EXPECTED_XCODE   sobrepõe a versão lida de .xcode-version
#   RSK_EXPECTED_SWIFT   sobrepõe EXPECTED_SWIFT_VERSION
#
# Códigos de saída: 0 = ok; 1 = divergência; 2 = erro de ambiente.

set -euo pipefail

EXPECTED_SWIFT_VERSION="6.4"

# Resolve a raiz sem `dirname`, para não depender de ferramentas externas.
case "$0" in
  */*) script_dir="${0%/*}" ;;
  *) script_dir="." ;;
esac
repo_root="$(cd "$script_dir/.." && pwd)"
xcode_file="$repo_root/.xcode-version"

fail() {
  echo "check-toolchain: ERRO: $1" >&2
  exit "${2:-1}"
}

if [ -n "${RSK_EXPECTED_XCODE:-}" ]; then
  expected_xcode="$RSK_EXPECTED_XCODE"
else
  [ -f "$xcode_file" ] || fail "arquivo .xcode-version não encontrado em $repo_root" 2
  expected_xcode="$(tr -d '[:space:]' < "$xcode_file")"
fi
expected_swift="${RSK_EXPECTED_SWIFT:-$EXPECTED_SWIFT_VERSION}"

[ -n "$expected_xcode" ] || fail ".xcode-version está vazio" 2

command -v xcodebuild > /dev/null 2>&1 || fail "xcodebuild não encontrado (instale o Xcode $expected_xcode)" 2
command -v swift > /dev/null 2>&1 || fail "swift não encontrado (instale o Xcode $expected_xcode)" 2

# "Xcode 27.0" -> "27.0"
actual_xcode="$(xcodebuild -version 2>/dev/null | sed -n 's/^Xcode \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
[ -n "$actual_xcode" ] || fail "não foi possível ler a versão do Xcode (xcodebuild -version)" 2

# "... Apple Swift version 6.4 (swiftlang-...)" -> "6.4"
actual_swift_full="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
[ -n "$actual_swift_full" ] || fail "não foi possível ler a versão do Swift (swift --version)" 2
actual_swift="$(echo "$actual_swift_full" | cut -d. -f1-2)"
expected_swift_mm="$(echo "$expected_swift" | cut -d. -f1-2)"

status=0
if [ "$actual_xcode" != "$expected_xcode" ]; then
  echo "check-toolchain: DIVERGÊNCIA: Xcode $actual_xcode encontrado; esperado $expected_xcode (.xcode-version)." >&2
  echo "  Selecione o Xcode correto (ex.: sudo xcode-select -s /Applications/Xcode_$expected_xcode.app)." >&2
  status=1
fi
if [ "$actual_swift" != "$expected_swift_mm" ]; then
  echo "check-toolchain: DIVERGÊNCIA: Swift $actual_swift_full encontrado; esperado $expected_swift_mm.x." >&2
  status=1
fi

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

echo "check-toolchain: OK — Xcode $actual_xcode, Swift $actual_swift_full."
