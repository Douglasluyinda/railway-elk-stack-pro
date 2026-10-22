#!/usr/bin/env bash
# Tests the LOGIC of scripts/smoke_test.sh with fake curl and a fake `docker compose`.
# It proves the script passes on a healthy stack and fails on each broken one.
# It does NOT start Elasticsearch, Logstash or Kibana: that is what CI does with the real script.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE="$ROOT/scripts/smoke_test.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Fake host curl. Scenario knobs: FAKE_KIBANA_LEVEL, FAKE_UNAUTH_CODE, FAKE_AUTH_CODE.
cat > "$TMP/bin/curl" <<'FAKE'
#!/usr/bin/env bash
url=""; conf=""
while [ $# -gt 0 ]; do
  case "$1" in
    -K) conf="$2"; shift 2 ;;
    -m|-o|-w|-X|-H|-d) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */api/status) printf '{"status":{"overall":{"level":"%s"}}}' "${FAKE_KIBANA_LEVEL:-available}" ;;
  *:8080*) if [ -n "$conf" ]; then printf '%s' "${FAKE_AUTH_CODE:-200}"; else printf '%s' "${FAKE_UNAUTH_CODE:-401}"; fi ;;
  *) echo "fake curl: unexpected url $url" >&2; exit 1 ;;
esac
FAKE

# Fake "docker compose": receives: exec -T elasticsearch sh -c "<curl command string>".
# Scenario knobs: FAKE_HITS, FAKE_HEADERS_INDEXED, FAKE_WRITER_CODE.
cat > "$TMP/bin/fakecompose" <<'FAKE'
#!/usr/bin/env bash
cmd="${@: -1}"
if [[ "$cmd" == *"logstash_writer"* ]]; then
  printf '{"error":"forbidden"}\n%s' "${FAKE_WRITER_CODE:-403}"
  exit 0
fi
extra=""
[ "${FAKE_HEADERS_INDEXED:-0}" = 1 ] && extra=',"headers":{"authorization":"Basic xxx"}'
printf '{"hits":{"total":{"value":%s},"hits":[{"_source":{"message":"m","environment":"production"%s}}]}}\n200' \
  "${FAKE_HITS:-1}" "$extra"
FAKE
chmod +x "$TMP/bin/curl" "$TMP/bin/fakecompose"

pass=0; fail=0
check() { if [ "$2" -eq 0 ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1"; fail=$((fail + 1)); fi; }

run_smoke() { # run_smoke VAR=value ...
  env -i PATH="$TMP/bin:/usr/bin:/bin" COMPOSE="$TMP/bin/fakecompose" \
    ELASTIC_PASSWORD=elasticpw INPUT_PASSWORD=inputpw \
    SMOKE_WAIT_ATTEMPTS=2 SMOKE_WAIT_SLEEP=0 "$@" bash "$SMOKE" > "$TMP/out" 2>&1
}

run_smoke; rc=$?
check "healthy stack passes" "$rc"
grep -c '^PASS' "$TMP/out" | grep -qx 7; check "healthy stack reports 7 passing checks" $?

run_smoke FAKE_KIBANA_LEVEL=unavailable; rc=$?
[ "$rc" -ne 0 ]; check "fails when Kibana never becomes available" $?
grep -q 'stopped early' "$TMP/out"; check "stops early instead of continuing" $?

run_smoke FAKE_UNAUTH_CODE=200; rc=$?
[ "$rc" -ne 0 ]; check "fails when intake accepts anonymous requests" $?

run_smoke FAKE_AUTH_CODE=401; rc=$?
[ "$rc" -ne 0 ]; check "fails when intake rejects the shipper user" $?

run_smoke FAKE_HITS=0; rc=$?
[ "$rc" -ne 0 ]; check "fails when the event is never indexed" $?

run_smoke FAKE_HEADERS_INDEXED=1; rc=$?
[ "$rc" -ne 0 ]; check "fails when intake headers are indexed" $?

run_smoke FAKE_WRITER_CODE=200; rc=$?
[ "$rc" -ne 0 ]; check "fails when logstash_writer can read data" $?

env -i PATH="$TMP/bin:/usr/bin:/bin" COMPOSE="$TMP/bin/fakecompose" INPUT_PASSWORD=x bash "$SMOKE" > "$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "exits 2 when ELASTIC_PASSWORD is missing" $?
grep -q 'ELASTIC_PASSWORD is not set' "$TMP/out"; check "explains the missing variable" $?

echo "smoke_test.sh tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
