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

# R-W0-03: no runner próprio (LaunchAgent com SessionCreate), o processo roda numa sessão de segurança
# separada e o keychain de login não é acessível (-25308). Cria um keychain TEMPORÁRIO e o define como
# padrão só no domínio "dynamic" — que é por sessão de segurança —, sem tocar nas preferências do
# usuário nem no keychain de login. Só roda dentro do GitHub Actions; apagado ao sair.
rsk_ci_keychain() {
  [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${RUNNER_TEMP:-}" ]] || return 0
  RSK_CI_KEYCHAIN="$RUNNER_TEMP/rskeeper-ci-$$.keychain-db"
  local pass; pass="$(uuidgen)"
  security create-keychain -p "$pass" "$RSK_CI_KEYCHAIN"
  security set-keychain-settings "$RSK_CI_KEYCHAIN"          # sem bloqueio por tempo
  security unlock-keychain -p "$pass" "$RSK_CI_KEYCHAIN"
  security list-keychains -d dynamic -s "$RSK_CI_KEYCHAIN"
  security default-keychain -d dynamic -s "$RSK_CI_KEYCHAIN"
  trap 'security delete-keychain "$RSK_CI_KEYCHAIN" 2>/dev/null || true' EXIT
  echo "ci: keychain temporário da sessão do runner ($(basename "$RSK_CI_KEYCHAIN"))"
}
