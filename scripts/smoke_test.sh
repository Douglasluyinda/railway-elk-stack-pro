#!/usr/bin/env bash
# End-to-end smoke test for the docker-compose stack (the same three services Railway runs).
#
#   cp .env.example .env     # fill in the values
#   docker compose up --build -d
#   bash scripts/smoke_test.sh
#
# Checks, in order:
#   1. Kibana reports overall status "available" (log in as elastic)
#   2. Logstash intake rejects a request without credentials
#   3. Logstash intake accepts an event from the "shipper" user
#   4. The event is searchable in Elasticsearch, with intake credentials removed
#   5. The logstash_writer user cannot read data (least privilege)
#
# Reads ELASTIC_PASSWORD and INPUT_PASSWORD from the environment or from ./.env.
# No password is placed on any command line: curl reads a private config file on the host,
# and the Elasticsearch checks use the variables already set inside the container.
#
# Overrides (mainly for tests/test_smoke.sh): COMPOSE, KIBANA_URL, INTAKE_URL,
# SMOKE_WAIT_ATTEMPTS, SMOKE_WAIT_SLEEP.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE:-docker compose}"
KIBANA_URL="${KIBANA_URL:-http://127.0.0.1:5601}"
INTAKE_URL="${INTAKE_URL:-http://127.0.0.1:8080}"
WAIT_ATTEMPTS="${SMOKE_WAIT_ATTEMPTS:-120}"
WAIT_SLEEP="${SMOKE_WAIT_SLEEP:-3}"

log() { printf '[smoke] %s\n' "$*" >&2; }

# Take only the variables this script needs from .env, without executing the file.
for name in ELASTIC_PASSWORD INPUT_PASSWORD; do
  if [ -z "${!name:-}" ] && [ -f "$ROOT/.env" ]; then
    value="$(grep -E "^${name}=" "$ROOT/.env" | tail -n1 | cut -d= -f2-)"
    export "$name=$value"
  fi
  if [ -z "${!name:-}" ]; then
    log "ERROR: $name is not set (export it or put it in .env)"
    exit 2
  fi
done

umask 077
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
printf 'user = "elastic:%s"\n' "$ELASTIC_PASSWORD" > "$WORKDIR/elastic.conf"
printf 'user = "shipper:%s"\n' "$INPUT_PASSWORD" > "$WORKDIR/shipper.conf"

pass=0
fail=0
check() { # check "name" exit-code
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1"; fail=$((fail + 1)); fi
}

check_if() { # check_if "name" command...: passes when the command succeeds
  local name="$1"; shift
  if "$@"; then check "$name" 0; else check "$name" 1; fi
}

# es_get USER PASSWORD_VAR URL: runs curl inside the Elasticsearch container, using the password
# variable already set there. Prints the body, then the HTTP status on the last line.
es_get() {
  # shellcheck disable=SC2086  # COMPOSE is intentionally word-split ("docker compose")
  $COMPOSE exec -T elasticsearch sh -c "curl -sS -m 20 -w '\n%{http_code}' -u '$1:'\"\$$2\" '$3'"
}

json_get() { # json_get PYTHON_EXPRESSION_ON_d  (reads JSON on stdin; prints "" on any error)
  python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(eval(sys.argv[1]))
except Exception:
    print("")' "$1"
}

# 1. Kibana available -----------------------------------------------------------------------
log "waiting for Kibana at $KIBANA_URL (up to $((WAIT_ATTEMPTS * WAIT_SLEEP))s)"
level=""
for ((i = 1; i <= WAIT_ATTEMPTS; i++)); do
  level="$(curl -sS -m 10 -K "$WORKDIR/elastic.conf" "$KIBANA_URL/api/status" 2>/dev/null \
    | json_get 'd["status"]["overall"]["level"]')"
  [ "$level" = "available" ] && break
  sleep "$WAIT_SLEEP"
done
[ "$level" = "available" ]
check "Kibana status is available (last seen: '${level:-no response}')" $?
if [ "$level" != "available" ]; then
  echo "smoke test: $pass passed, $fail failed (stopped early: Kibana never became available)"
  exit 1
fi

# 2 and 3. Intake authentication ------------------------------------------------------------
token="smoke${RANDOM}${RANDOM}"
payload="{\"message\":\"$token\",\"service\":\"smoke-test\",\"level\":\"info\"}"

code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$payload" "$INTAKE_URL" 2>/dev/null)"
check_if "intake rejects a request without credentials (HTTP ${code:-none})" [ "$code" = "401" ]

code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -K "$WORKDIR/shipper.conf" -d "$payload" "$INTAKE_URL" 2>/dev/null)"
check_if "intake accepts an event from the shipper user (HTTP ${code:-none})" [ "$code" = "200" ]

# 4. The event is indexed -------------------------------------------------------------------
search_url="http://127.0.0.1:9200/railway-logs-*/_search?size=1&q=message:${token}"
hits=0
body=""
for ((i = 1; i <= 30; i++)); do
  out="$(es_get elastic ELASTIC_PASSWORD "$search_url" 2>/dev/null)"
  body="${out%$'\n'*}"
  hits="$(printf '%s' "$body" | json_get 'd["hits"]["total"]["value"]')"
  [ "${hits:-0}" -ge 1 ] 2>/dev/null && break
  sleep 3
done
check_if "event is searchable in railway-logs-* (hits: ${hits:-0})" [ "${hits:-0}" -ge 1 ]

printf '%s' "$body" | json_get '"headers" not in d["hits"]["hits"][0]["_source"]' | grep -qx True
check "intake headers (including credentials) are not indexed" $?
printf '%s' "$body" | json_get 'bool(d["hits"]["hits"][0]["_source"]["environment"])' | grep -qx True
check "environment field is added" $?

# 5. Least privilege ------------------------------------------------------------------------
out="$(es_get logstash_writer LOGSTASH_WRITER_PASSWORD 'http://127.0.0.1:9200/railway-logs-*/_search' 2>/dev/null)"
code="${out##*$'\n'}"
[ "$code" = "403" ]
check "logstash_writer cannot read data (HTTP ${code:-none})" $?

echo "smoke test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
