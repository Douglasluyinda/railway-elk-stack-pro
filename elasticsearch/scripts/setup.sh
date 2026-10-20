#!/usr/bin/env bash
# Idempotent post-start provisioning for the Elasticsearch service.
# Safe to run on every start: every call is a PUT/POST that replaces state.
#
# Required env: ELASTIC_PASSWORD, KIBANA_SYSTEM_PASSWORD, LOGSTASH_WRITER_PASSWORD
# Optional env: LOG_RETENTION_DAYS (default 14), ES_URL (default http://127.0.0.1:9200)
set -euo pipefail

ES_URL="${ES_URL:-http://127.0.0.1:9200}"
RETENTION_DAYS="${LOG_RETENTION_DAYS:-14}"
WAIT_ATTEMPTS="${SETUP_WAIT_ATTEMPTS:-180}"
WAIT_SLEEP="${SETUP_WAIT_SLEEP:-2}"

log() { printf '[railway-es-setup] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

check_secret() {
  local name="$1" value="${!1:-}"
  [ -n "$value" ] || die "$name is not set"
  case "$value" in
    *\"* | *\\* | *$'\n'*) die "$name must not contain double quotes, backslashes or newlines" ;;
  esac
}

check_secret ELASTIC_PASSWORD
check_secret KIBANA_SYSTEM_PASSWORD
check_secret LOGSTASH_WRITER_PASSWORD
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && [ "$RETENTION_DAYS" -ge 1 ] \
  || die "LOG_RETENTION_DAYS must be a whole number of days, 1 or more"

# Credentials live in a private temp file, not on the curl command line.
umask 077
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
{
  printf 'user = "elastic:%s"\n' "$ELASTIC_PASSWORD"
  printf 'header = "Content-Type: application/json"\n'
} > "$WORKDIR/curl.conf"

api() {
  local method="$1" path="$2" body="${3:-}" out
  local args=(-sS --fail-with-body -m 30 -K "$WORKDIR/curl.conf" -X "$method")
  if [ -n "$body" ]; then
    printf '%s' "$body" > "$WORKDIR/body.json"
    args+=(--data-binary "@$WORKDIR/body.json")
  fi
  out="$(curl "${args[@]}" "${ES_URL}${path}")" || { log "request failed: ${method} ${path}: ${out}"; return 1; }
  log "ok: ${method} ${path}"
}

wait_for_es() {
  local i
  for ((i = 1; i <= WAIT_ATTEMPTS; i++)); do
    if curl -sS -f -m 10 -K "$WORKDIR/curl.conf" -o /dev/null \
      "${ES_URL}/_cluster/health?wait_for_status=yellow&timeout=5s" 2>/dev/null; then
      return 0
    fi
    sleep "$WAIT_SLEEP"
  done
  return 1
}

log "waiting for Elasticsearch at ${ES_URL}"
wait_for_es || die "Elasticsearch did not become ready; restart the service to retry setup"

# Kibana's built-in service user.
api POST /_security/user/kibana_system/_password \
  "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}"

# Least-privilege writer for Logstash: can only create/index into railway-logs-*.
api PUT /_security/role/railway_log_writer \
  '{"cluster":["monitor"],"indices":[{"names":["railway-logs-*"],"privileges":["create_index","create_doc","index","auto_configure"]}]}'
api PUT /_security/user/logstash_writer \
  "{\"password\":\"${LOGSTASH_WRITER_PASSWORD}\",\"roles\":[\"railway_log_writer\"]}"

# Retention: delete railway-logs-* indices after N days, no replicas on a single node.
api PUT /_ilm/policy/railway-logs-retention \
  "{\"policy\":{\"phases\":{\"delete\":{\"min_age\":\"${RETENTION_DAYS}d\",\"actions\":{\"delete\":{}}}}}}"
api PUT /_index_template/railway-logs \
  '{"index_patterns":["railway-logs-*"],"priority":200,"template":{"settings":{"index.number_of_replicas":0,"index.lifecycle.name":"railway-logs-retention"}}}'

log "setup complete"
