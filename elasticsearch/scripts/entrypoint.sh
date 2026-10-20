#!/usr/bin/env bash
# Railway entrypoint for Elasticsearch.
# 1. Make the (root-owned) volume writable by the elasticsearch user.
# 2. Start the idempotent provisioning script in the background.
# 3. Run the stock Elastic entrypoint as uid 1000 (Elasticsearch refuses to run as root).
set -euo pipefail

DATA_DIR="${ES_DATA_DIR:-/usr/share/elasticsearch/data}"
SETUP_SCRIPT="${ES_SETUP_SCRIPT:-/usr/local/bin/railway-es-setup.sh}"
ES_UID=1000
ES_GID=0
UPSTREAM=(/bin/tini -- /usr/local/bin/docker-entrypoint.sh eswrapper)

mkdir -p "$DATA_DIR"

if [ "$(id -u)" -eq 0 ]; then
  if [ "$(stat -c %u "$DATA_DIR")" != "$ES_UID" ]; then
    echo "[railway-es-entrypoint] fixing ownership of $DATA_DIR"
    chown -R "$ES_UID:$ES_GID" "$DATA_DIR"
  fi
  "$SETUP_SCRIPT" &
  if command -v setpriv >/dev/null 2>&1; then
    exec setpriv --reuid="$ES_UID" --regid="$ES_GID" --clear-groups -- "${UPSTREAM[@]}"
  fi
  exec runuser -u elasticsearch -- "${UPSTREAM[@]}"
fi

# Already non-root (for example when run locally with --user): just start.
"$SETUP_SCRIPT" &
exec "${UPSTREAM[@]}"
