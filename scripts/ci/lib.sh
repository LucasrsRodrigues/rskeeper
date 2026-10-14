# Funções comuns dos scripts de CI (W0-T16). Uso: source "$(dirname "$0")/lib.sh"
set -euo pipefail
RSK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RSK_LOGS="${RSK_LOGS:-$RSK_ROOT/.build/ci-logs}"
mkdir -p "$RSK_LOGS"
cd "$RSK_ROOT"

# Esquema e nome de produto por configuração.
rsk_scheme() { case "$1" in Dev) echo RSKeeper-Dev ;; Test) echo RSKeeper-Test ;; Release) echo RSKeeper ;; *) echo "configuração inválida: $1" >&2; exit 2 ;; esac; }
rsk_product() { case "$1" in Dev) echo "RSKeeper Dev" ;; Test) echo "RSKeeper Test" ;; Release) echo "RSKeeper" ;; esac; }

# NT-CONC-11: diagnóstico de compilação em fonte própria reprova (W0-D11: alguns grupos de diagnóstico
# não são promovidos a erro por SWIFT_TREAT_WARNINGS_AS_ERRORS / -warnings-as-errors).
# Conta: `arquivo:linha[:coluna]: warning:` fora de dependências, expansões de macro e avisos do linker.
# Não conta avisos de ferramenta (cache do SwiftPM, appintents, avisos internos do runner do XCTest).
rsk_check_warnings() {
  local log="$1" found
  found="$( { grep -E "^/[^ ]+\.(swift|m|h|c):[0-9]+(:[0-9]+)?: warning:|^macro expansion .*: warning:|^ld: warning:" "$log" || true; } \
    | { grep -vE "/SourcePackages/|/checkouts/" || true; } | sort -u)"
  if [[ -n "$found" ]]; then
    echo "$found" | head -40 >&2
    echo "ci: VIOLAÇÃO: $(echo "$found" | wc -l | tr -d ' ') aviso(s) em fontes próprias ($log)" >&2
    return 1
  fi
  echo "ci: zero avisos em fontes próprias ($(basename "$log"))"
}


# R-W0-03: o runner próprio roda como LaunchAgent na sessão de login do usuário (SessionCreate=false;
# ver docs/ci-runner.md). Assim os testes do SecretStore usam o keychain de login como no terminal,
# tocando só o serviço `….test.secrets` (NT-SEC-15). Com SessionCreate=true davam -25308.
