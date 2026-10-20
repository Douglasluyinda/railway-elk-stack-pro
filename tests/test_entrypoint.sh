#!/usr/bin/env bash
# Behavioural test for elasticsearch/scripts/entrypoint.sh with fake id/stat/chown/setpriv/tini.
# Verifies privilege-drop arguments and volume ownership handling. It does NOT start Elasticsearch.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/elasticsearch/scripts/entrypoint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/data"

# Fakes: every command appends its argv to $LOG.
# shellcheck disable=SC2016  # the single-quoted bodies are written to files and expanded later
{
  for cmd in chown setpriv runuser; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$LOG"\n' "$cmd" > "$TMP/bin/$cmd"
  done
  printf '#!/usr/bin/env bash\nif [ "$1" = "-u" ]; then echo "${FAKE_UID:-0}"; else echo "unexpected id $*" >&2; exit 1; fi\n' > "$TMP/bin/id"
  printf '#!/usr/bin/env bash\necho "${FAKE_OWNER_UID:-0}"\n' > "$TMP/bin/stat"
  printf '#!/usr/bin/env bash\necho "setup-started" >> "$LOG"\n' > "$TMP/setup.sh"
}
chmod +x "$TMP"/bin/* "$TMP/setup.sh"

# A second PATH without setpriv (the sandbox has a real one in /usr/bin), so the
# runuser fallback can be exercised. It only exposes the fakes plus bash and mkdir.
mkdir -p "$TMP/bin_nosetpriv"
for f in chown runuser id stat; do cp "$TMP/bin/$f" "$TMP/bin_nosetpriv/$f"; done
ln -s "$(command -v bash)" "$TMP/bin_nosetpriv/bash"
ln -s "$(command -v mkdir)" "$TMP/bin_nosetpriv/mkdir"
ln -s "$(command -v env)" "$TMP/bin_nosetpriv/env"

pass=0; fail=0
check() { if [ "$2" -eq 0 ]; then echo "PASS: $1"; pass=$((pass + 1)); else echo "FAIL: $1"; fail=$((fail + 1)); fi; }
run() { # usage: run PATH_VALUE VAR=value ...
  local path_value="$1"; shift
  : > "$TMP/log"
  env -i PATH="$path_value" LOG="$TMP/log" ES_DATA_DIR="$TMP/data" ES_SETUP_SCRIPT="$TMP/setup.sh" "$@" bash "$ENTRY"
  sleep 0.2 # background setup job
}
FULL_PATH="$TMP/bin:/usr/bin:/bin"

# Root, volume owned by root: chown + setpriv to 1000:0
run "$FULL_PATH" FAKE_UID=0 FAKE_OWNER_UID=0
grep -q "^chown -R 1000:0 $TMP/data" "$TMP/log"; check "root-owned volume is chowned to 1000:0" $?
grep -q '^setpriv --reuid=1000 --regid=0 --clear-groups -- /bin/tini -- /usr/local/bin/docker-entrypoint.sh eswrapper' "$TMP/log"; check "drops to uid 1000 and runs the stock entrypoint" $?
grep -q '^setup-started' "$TMP/log"; check "starts the provisioning script" $?

# Root, volume already owned by 1000: no recursive chown
run "$FULL_PATH" FAKE_UID=0 FAKE_OWNER_UID=1000
! grep -q '^chown' "$TMP/log"; check "skips chown when ownership is already correct" $?

# Root, no setpriv: falls back to runuser
run "$TMP/bin_nosetpriv" FAKE_UID=0 FAKE_OWNER_UID=1000
grep -q '^runuser -u elasticsearch -- /bin/tini' "$TMP/log"; check "falls back to runuser when setpriv is missing" $?

echo "entrypoint.sh tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
