#!/bin/bash
# NT-SEC-20 (versão da onda 0): no build Release ad hoc, o campo dinâmico do evento de boot aparece
# como <private> no `log show` (sem perfil de depuração) e o valor real não aparece.
# Uso: scripts/ci/log-privacy.sh [YES|NO]. Abre o app Release por ~4 s (raiz de dados do próprio app).
source "$(dirname "$0")/lib.sh"
sandbox="${1:-YES}"
app="$RSK_ROOT/.build/xcode-sb$sandbox/Build/Products/Release/RSKeeper.app"
[[ -d "$app" ]] || { echo "log-privacy: ERRO: rode antes scripts/ci/build.sh Release $sandbox" >&2; exit 2; }
start="$(date '+%Y-%m-%d %H:%M:%S')"
"$app/Contents/MacOS/RSKeeper" > /dev/null 2>&1 &
pid=$!
sleep 4
kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
sleep 1
out="$(/usr/bin/log show --start "$start" --style compact \
  --predicate 'subsystem == "app.rskeeper.RSKeeper" AND category == "lifecycle"' 2>/dev/null | grep "app.started" || true)"
[[ -n "$out" ]] || { echo "log-privacy: FALHA: evento app.started não encontrado" >&2; exit 1; }
echo "log-privacy: $(echo "$out" | tail -1 | sed -E 's/^.*(app\.started)/\1/')"
status=0
echo "$out" | grep -q "<private>" || { echo "log-privacy: VIOLAÇÃO: campo privado não está como <private>" >&2; status=1; }
echo "$out" | grep -q "Application Support" && { echo "log-privacy: VIOLAÇÃO: o caminho da raiz vazou no log" >&2; status=1; }
echo "$out" | grep -q "environment=prod" || { echo "log-privacy: VIOLAÇÃO: campo público ausente" >&2; status=1; }
[[ $status -eq 0 ]] && echo "log-privacy: OK campo dinâmico privado como <private>; campos públicos visíveis"
exit $status
