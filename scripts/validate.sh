#!/usr/bin/env bash
# Static validation and script tests. Runs without Docker or network access.
# What this does NOT cover: building the images, starting Elasticsearch/Logstash/Kibana,
# or anything on Railway. See README "What is verified".
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
status=0
step() { echo; echo "== $*"; }
fail() { echo "FAILED: $*"; status=1; }
# ok_or_fail LABEL CMD...: run CMD, print "ok LABEL" or record a failure.
ok_or_fail() {
  local label="$1"; shift
  if "$@"; then echo "ok  $label"; else fail "$label"; fi
}

step "shell syntax"
for f in elasticsearch/scripts/*.sh tests/*.sh scripts/*.sh; do
  ok_or_fail "$f" bash -n "$f"
done

step "shellcheck (if installed)"
if command -v shellcheck >/dev/null; then
  ok_or_fail "shellcheck" shellcheck elasticsearch/scripts/*.sh tests/*.sh scripts/*.sh
else
  echo "skipped: shellcheck not installed"
fi

step "JSON files"
for f in */railway.json; do
  ok_or_fail "$f" python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f"
done

step "YAML files"
if python3 -c 'import yaml' 2>/dev/null; then
  for f in elasticsearch/config/elasticsearch.yml logstash/config/logstash.yml docker-compose.yml; do
    ok_or_fail "$f" python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$f"
  done
else
  echo "skipped: PyYAML not installed (pip install pyyaml)"
fi

step "Dockerfile sanity"
for d in elasticsearch kibana logstash; do
  grep -q '^FROM ' "$d/Dockerfile" || fail "$d/Dockerfile has no FROM"
  if grep -qi '^VOLUME' "$d/Dockerfile"; then fail "$d/Dockerfile uses VOLUME (attach a Railway volume instead)"; fi
  echo "ok  $d/Dockerfile"
done

step "Logstash pipeline (structure only, not a real syntax check)"
python3 - <<'PY' || fail "logstash.conf"
import re, sys
text = open("logstash/pipeline/logstash.conf").read()
code = "\n".join(l.split("#", 1)[0] for l in text.splitlines())
assert code.count("{") == code.count("}"), "unbalanced braces"
for section in ("input", "filter", "output"):
    assert re.search(rf"^\s*{section}\s*{{", code, re.M), f"missing {section} section"
assert "stdout" not in code, "debug stdout output must not ship"
for var in ("INPUT_USER", "INPUT_PASSWORD", "ES_URL", "ES_USER", "ES_PASSWORD"):
    assert "${" + var + "}" in code, f"{var} not referenced"
print("ok  logstash/pipeline/logstash.conf")
PY

step "No hardcoded secrets"
if grep -rInE '(PASSWORD|ENCRYPTIONKEY)\s*[=:]\s*["'"'"']?[A-Za-z0-9]{8,}' --include=Dockerfile --include='*.yml' --include='*.conf' --include='*.json' . ; then
  fail "possible hardcoded secret above"
else
  echo "ok"
fi

step "setup.sh behaviour (mock curl)"
bash tests/test_setup.sh || status=1

step "entrypoint.sh behaviour (mock privilege tools)"
bash tests/test_entrypoint.sh || status=1

echo
[ "$status" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$status"
