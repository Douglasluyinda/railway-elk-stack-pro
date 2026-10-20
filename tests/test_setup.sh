#!/usr/bin/env bash
# Behavioural test for elasticsearch/scripts/setup.sh using a fake curl.
# Verifies the call sequence, JSON validity, retry loop, and input validation.
# It does NOT talk to a real Elasticsearch.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$ROOT/elasticsearch/scripts/setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Fake curl: logs "METHOD URL", logs request bodies and the config file, and can
# fail the first N health checks (FAKE_FAIL_HEALTH_COUNT).
cat > "$TMP/bin/curl" <<'FAKE'
#!/usr/bin/env bash
method=GET; body=""; url=""; conf=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -K) conf="$2"; shift 2 ;;
    --data-binary) body="$(cat "${2#@}")"; shift 2 ;;
    -m|-o) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "ARGS_HAS_PASSWORD=$(printf '%s' "$*" | grep -c "$ELASTIC_PASSWORD")" >> "$FAKE_LOG"
echo "CONF_USER=$(grep '^user' "$conf" | head -1)" >> "$FAKE_LOG"
if [[ "$url" == *"_cluster/health"* ]]; then
  n=$(cat "$FAKE_COUNTER" 2>/dev/null || echo 0)
  if [ "$n" -lt "${FAKE_FAIL_HEALTH_COUNT:-0}" ]; then echo $((n + 1)) > "$FAKE_COUNTER"; exit 22; fi
fi
echo "CALL $method ${url#http://127.0.0.1:9200}" >> "$FAKE_LOG"
[ -n "$body" ] && echo "BODY $body" >> "$FAKE_LOG"
echo '{"acknowledged":true}'
FAKE
chmod +x "$TMP/bin/curl"

pass=0; fail=0
check() { # check "name" condition-exit-code
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1"; fail=$((fail + 1)); fi
}

run_setup() { # runs setup.sh with env overrides passed as args
  : > "$TMP/log"; rm -f "$TMP/counter"
  env -i PATH="$TMP/bin:/usr/bin:/bin" FAKE_LOG="$TMP/log" FAKE_COUNTER="$TMP/counter" \
    SETUP_WAIT_SLEEP=0 ELASTIC_PASSWORD=elasticpw KIBANA_SYSTEM_PASSWORD=kibanapw \
    LOGSTASH_WRITER_PASSWORD=writerpw "$@" bash "$SETUP" >"$TMP/out" 2>&1
}

# 1. Happy path
run_setup; rc=$?
check "happy path exits 0" "$rc"
calls="$(grep '^CALL' "$TMP/log" | grep -v 'GET' | sed 's/^CALL //' | tr '\n' ';')"
expected="POST /_security/user/kibana_system/_password;PUT /_security/role/railway_log_writer;PUT /_security/user/logstash_writer;PUT /_ilm/policy/railway-logs-retention;PUT /_index_template/railway-logs;"
[ "$calls" = "$expected" ]; check "API calls in expected order" $?
grep '^BODY' "$TMP/log" | sed 's/^BODY //' | python3 -c '
import sys, json
for line in sys.stdin: json.loads(line)
'; check "every request body is valid JSON" $?
grep -q '"min_age":"14d"' "$TMP/log"; check "default retention is 14d" $?
grep -q 'railway-logs-\*' "$TMP/log" && grep -q '"index.number_of_replicas":0' "$TMP/log"; check "template targets railway-logs-* with 0 replicas" $?
grep -q 'ARGS_HAS_PASSWORD=0' "$TMP/log" && ! grep -q 'ARGS_HAS_PASSWORD=[1-9]' "$TMP/log"; check "elastic password never on the command line" $?
grep -q 'CONF_USER=user = "elastic:elasticpw"' "$TMP/log"; check "credentials passed via curl config file" $?

# 2. Custom retention
run_setup LOG_RETENTION_DAYS=30; rc=$?
check "custom retention exits 0" "$rc"
grep -q '"min_age":"30d"' "$TMP/log"; check "custom retention applied (30d)" $?

# 3. Retry loop
run_setup FAKE_FAIL_HEALTH_COUNT=3; rc=$?
check "survives 3 failed health checks" "$rc"

# 4. Never ready
run_setup FAKE_FAIL_HEALTH_COUNT=999 SETUP_WAIT_ATTEMPTS=3; rc=$?
[ "$rc" -ne 0 ]; check "fails when Elasticsearch never becomes ready" $?
grep -q 'did not become ready' "$TMP/out"; check "explains the failure" $?

# 5. Input validation
run_setup LOG_RETENTION_DAYS=abc; rc=$?
[ "$rc" -ne 0 ]; check "rejects non-numeric retention" $?
run_setup 'KIBANA_SYSTEM_PASSWORD=bad"quote'; rc=$?
[ "$rc" -ne 0 ]; check "rejects password containing a double quote" $?
run_setup 'LOGSTASH_WRITER_PASSWORD=back\slash'; rc=$?
[ "$rc" -ne 0 ]; check "rejects password containing a backslash" $?
: > "$TMP/log"
if env -i PATH="$TMP/bin:/usr/bin:/bin" FAKE_LOG="$TMP/log" FAKE_COUNTER="$TMP/counter" \
  KIBANA_SYSTEM_PASSWORD=a LOGSTASH_WRITER_PASSWORD=b bash "$SETUP" >"$TMP/out" 2>&1; then
  check "fails clearly when ELASTIC_PASSWORD is missing" 1
else
  grep -q 'ELASTIC_PASSWORD is not set' "$TMP/out"; check "fails clearly when ELASTIC_PASSWORD is missing" $?
fi

echo "setup.sh tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
