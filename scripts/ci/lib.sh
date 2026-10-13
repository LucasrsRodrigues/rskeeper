# Funções comuns dos scripts de CI (W0-T16). Uso: source "$(dirname "$0")/lib.sh"
set -euo pipefail
RSK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RSK_LOGS="${RSK_LOGS:-$RSK_ROOT/.build/ci-logs}"
mkdir -p "$RSK_LOGS"
cd "$RSK_ROOT"

# Esquema e nome de produto por configuração.
rsk_scheme() { case "$1" in Dev) echo RSKeeper-Dev ;; Test) echo RSKeeper-Test ;; Release) echo RSKeeper ;; *) echo "configuração inválida: $1" >&2; exit 2 ;; esac; }
rsk_product() { case "$1" in Dev) echo "RSKeeper Dev" ;; Test) echo "RSKeeper Test" ;; Release) echo "RSKeeper" ;; esac; }

# NT-CONC-11: qualquer "warning:" em fontes próprias reprova (W0-D11: alguns grupos de diagnóstico
# não são promovidos a erro por SWIFT_TREAT_WARNINGS_AS_ERRORS / -warnings-as-errors).
rsk_check_warnings() {
  local log="$1" found
  # Exceção única e explícita: mensagem informativa da toolchain (não é diagnóstico de fonte) emitida
  # em todo app sem AppIntents.
  found="$(grep -E "warning:" "$log" | grep -vE "/SourcePackages/|/checkouts/|\.build/checkouts" \
    | grep -v "appintentsmetadataprocessor.*Metadata extraction skipped, no AppIntents.framework dependency found" | sort -u || true)"
  if [[ -n "$found" ]]; then
    echo "$found" | head -40 >&2
    echo "ci: VIOLAÇÃO: $(echo "$found" | wc -l | tr -d ' ') aviso(s) em fontes próprias ($log)" >&2
    return 1
  fi
  echo "ci: zero avisos em fontes próprias ($(basename "$log"))"
}
