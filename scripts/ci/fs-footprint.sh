#!/bin/bash
# Portão §4 item 5 (W0-T31, diff de diretório): o app Test abre sem rede no boot e só deixa arquivos
# na raiz de dados indicada e nos caminhos geridos pelo SO (docs/os-managed-paths.md) do bundle ID
# app.rskeeper.RSKeeper.test. Uso: scripts/ci/fs-footprint.sh [YES|NO]
source "$(dirname "$0")/lib.sh"
sandbox="${1:-YES}"
app="$RSK_ROOT/.build/xcode-sb$sandbox/Build/Products/Test/RSKeeper Test.app"
[[ -d "$app" ]] || { echo "footprint: ERRO: rode antes scripts/ci/build.sh Test $sandbox" >&2; exit 2; }
bid="app.rskeeper.RSKeeper.test"
name="footprint-$$"
listing() { find "$HOME/Library" -maxdepth 4 -iname '*rskeeper*' 2>/dev/null | grep -v "/Library/Developer/" | sort || true; }
before="$(listing)"
"$app/Contents/MacOS/RSKeeper Test" -RSKeeperDataRoot "$name" > /dev/null 2>&1 &
pid=$!
sleep 5
kill -0 $pid 2>/dev/null || { echo "footprint: FALHA: o app encerrou no boot" >&2; exit 1; }
net="$( (lsof -nP -a -p $pid -i 2>/dev/null || true) | tail -n +2 | wc -l | tr -d ' ')"
kill $pid; wait $pid 2>/dev/null || true
after="$(listing)"
new="$(comm -13 <(echo "$before") <(echo "$after") | grep -v '^$' || true)"
status=0
[[ "$net" == 0 ]] && echo "footprint: OK 0 conexões de rede no boot" || { echo "footprint: VIOLAÇÃO: $net conexão(ões) de rede no boot" >&2; status=1; }
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  case "$path" in
    "$HOME/Library/Containers/$bid"|"$HOME/Library/Containers/$bid/"*) ok=1 ;;
    "$HOME/Library/Saved Application State/$bid.savedState"*) ok=1 ;;
    "$HOME/Library/Preferences/$bid.plist") ok=1 ;;
    "$HOME/Library/Caches/$bid"|"$HOME/Library/Caches/$bid/"*) ok=1 ;;
    "$HOME/Library/HTTPStorages/$bid"*) ok=1 ;;
    "$HOME/Library/Logs/DiagnosticReports/RSKeeper Test-"*) echo "footprint: VIOLAÇÃO: relatório de crash $path" >&2; ok=0 ;;
    *) ok=0 ;;
  esac
  if [[ $ok == 1 ]]; then echo "footprint: allowlist do SO: ${path#$HOME/}"; else echo "footprint: VIOLAÇÃO: caminho fora da allowlist: $path" >&2; status=1; fi
done <<< "$new"
# A raiz de dados é criada no temporário do processo (no sandbox, o tmp do container).
if [[ $sandbox == YES ]]; then root="$HOME/Library/Containers/$bid/Data/tmp/$name"; else root="$(getconf DARWIN_USER_TEMP_DIR)$name"; fi
if [[ -d "$root/data" && -d "$root/tmp" ]]; then
  echo "footprint: OK raiz de dados $(stat -f '%Lp' "$root") com $(ls "$root" | tr '\n' ' ')"
  rm -rf "$root"
else
  echo "footprint: VIOLAÇÃO: raiz de dados não encontrada em $root" >&2; status=1
fi
exit $status
