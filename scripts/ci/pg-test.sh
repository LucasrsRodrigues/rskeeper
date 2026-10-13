#!/bin/bash
# PostgreSQL DESCARTÁVEL para os testes do driver (W1-T05; D-W1-1). Só dados sintéticos.
#   scripts/ci/pg-test.sh up [14 16 17]   → sobe containers --rm em 127.0.0.1:554<versão>
#   scripts/ci/pg-test.sh down            → remove todos os containers rskeeper-test-pg*
#   scripts/ci/pg-test.sh env             → imprime RSK_PG_PORTS para os testes
# A senha é descartável e só vale para containers locais que somem ao parar.
set -euo pipefail
action="${1:-up}"; shift || true
versions=("${@:-17}")
[[ ${#versions[@]} -gt 0 && -n "${versions[0]}" ]] || versions=(17)
PASSWORD="rskeeper-test-only"
docker info > /dev/null 2>&1 || { echo "pg-test: ERRO: Docker não está rodando" >&2; exit 2; }

case "$action" in
  up)
    for v in "${versions[@]}"; do
      name="rskeeper-test-pg$v"; port="554$v"
      if [[ -z "$(docker ps -q --filter "name=^${name}$")" ]]; then
        docker run -d --rm --name "$name" -p "127.0.0.1:$port:5432" \
          -e POSTGRES_PASSWORD="$PASSWORD" -e POSTGRES_USER=rskeeper -e POSTGRES_DB=rskeeper_test \
          "postgres:$v-alpine" > /dev/null
      fi
      # Espera por TCP dentro do container: o servidor temporário do init só escuta no socket Unix.
      docker exec "$name" sh -c 'for i in $(seq 1 90); do pg_isready -h 127.0.0.1 -U rskeeper -d rskeeper_test >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1' \
        || { echo "pg-test: ERRO: $name não ficou pronto" >&2; exit 1; }
      echo "pg-test: $name pronto em 127.0.0.1:$port ($(docker exec "$name" postgres --version))"
    done
    ;;
  down)
    ids="$(docker ps -aq --filter name=rskeeper-test-pg)"
    [[ -z "$ids" ]] || docker rm -f $ids > /dev/null
    echo "pg-test: containers removidos"
    ;;
  env)
    ports="$(docker ps --filter name=rskeeper-test-pg --format '{{.Ports}}' | sed -E 's/.*:([0-9]+)->.*/\1/' | sort | paste -sd, -)"
    echo "export RSK_PG_PORTS=$ports RSK_PG_PASSWORD=$PASSWORD"
    ;;
  *) echo "uso: $0 up|down|env [versões]" >&2; exit 2 ;;
esac
