#!/bin/bash
# Portão §4 item 3 e validação da W0-T16: numa CÓPIA temporária da árvore de trabalho, injeta uma
# violação de cada tipo e exige que o check correspondente REPROVE. A árvore real não é tocada.
source "$(dirname "$0")/lib.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/rsk-negative.XXXXXX")"
trap 'rm -rf "$work"' EXIT
copy() { # nome → cópia limpa com git próprio
  local dst="$work/$1"; mkdir -p "$dst"
  rsync -a --exclude .build --exclude dist --exclude .git "$RSK_ROOT/" "$dst/"
  (cd "$dst" && git init -q && git add -A && git -c user.email=ci@local -c user.name=ci commit -qm base)
  echo "$dst"
}
status=0
expect_fail() { # descrição, diretório, comando…
  local desc="$1" dir="$2"; shift 2
  if (cd "$dir" && "$@" > "$work/out.txt" 2>&1); then
    echo "FAIL  $desc: o check APROVOU uma violação"; status=1
  else
    echo "OK    $desc: reprovado ($(grep -m1 -E 'VIOLAÇÃO|ERRO|error' "$work/out.txt" | cut -c1-160))"
  fi
}
# 1. Licença: pin não registrada no Package.resolved.
d="$(copy license)"
jq '.pins += [{"identity":"pacote-gpl","kind":"remoteSourceControl","location":"https://example.invalid/gpl.git","state":{"revision":"0000000000000000000000000000000000000000","version":"1.0.0"}}]' \
  "$d/Packages/RSKeeperKit/Package.resolved" > "$d/r.json" && mv "$d/r.json" "$d/Packages/RSKeeperKit/Package.resolved"
expect_fail "licença desconhecida" "$d" scripts/license-audit.sh
# 2. Higiene: arquivo de evidência versionado.
d="$(copy hygiene)"
mkdir -p "$d/evidence" && echo x > "$d/evidence/captura.txt" && (cd "$d" && git add -A && git -c user.email=ci@local -c user.name=ci commit -qm v)
expect_fail "higiene (evidence/)" "$d" scripts/ci/hygiene.sh
# 3. Fronteira: SQLKit passa a DECLARAR e importar Security (proibido em docs/module-rules.json).
#    Compila normalmente; só o check de fronteiras pode reprová-lo.
d="$(copy boundary)"
python3 -I -c 'import sys; p=sys.argv[1]; s=open(p).read(); old="name: \"RSKeeperSQLKit\",\n            dependencies: [\"RSKeeperDomain\"]"; assert old in s; open(p,"w").write(s.replace(old, old[:-1]+", \"RSKeeperSecurity\"]"))' "$d/Packages/RSKeeperKit/Package.swift"
printf 'import RSKeeperSecurity\n' > "$d/Packages/RSKeeperKit/Sources/RSKeeperSQLKit/Violation.swift"
expect_fail "fronteira (SQLKit → Security)" "$d" scripts/check-boundaries.sh
# 4. Aviso em fonte própria.
printf '/x/App/Sources/A.swift:3:9: warning: initialization of immutable value never used\n' > "$work/w.log"
expect_fail "aviso de compilação" "$RSK_ROOT" bash -c "source scripts/ci/lib.sh; rsk_check_warnings '$work/w.log'"
exit $status
