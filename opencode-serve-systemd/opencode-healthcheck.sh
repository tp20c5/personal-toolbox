#!/bin/bash
#
# opencode-healthcheck.sh -- liveness probe for `opencode serve`.
#
# Why this exists: the server is a single Bun/Node process. If its event loop
# gets stuck in a long synchronous SQLite call, the process stays alive but
# stops answering HTTP *and* ignores SIGTERM -- so systemd's `Restart=always`
# never fires and the box sits on a wedged server until someone restarts it by
# hand. This probe detects that state and forces a restart.
#
# Health rule: a `GET /` returns 401 when OPENCODE_SERVER_PASSWORD is set, which
# still means the server is alive. Treat any HTTP response (2xx/3xx/401/403/404)
# as healthy. Only a timeout / connection failure / 5xx counts as a strike.
# After THRESHOLD consecutive strikes (default 3) it restarts opencode.service.
#
# Everything it touches is under /run; it makes no persistent changes.
#
# Overridable via environment:
#   OPENCODE_HEALTHCHECK_URL        default http://127.0.0.1:4096/
#   OPENCODE_HEALTHCHECK_THRESHOLD  default 3
#   OPENCODE_HEALTHCHECK_SERVICE    default opencode.service
#
set -u

URL="${OPENCODE_HEALTHCHECK_URL:-http://127.0.0.1:4096/}"
STATE="/run/opencode-healthcheck.fail"
THRESHOLD="${OPENCODE_HEALTHCHECK_THRESHOLD:-3}"
SERVICE="${OPENCODE_HEALTHCHECK_SERVICE:-opencode.service}"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$URL" 2>/dev/null || echo 000)

case "$code" in
  2*|3*|401|403|404) n=0 ;;
  *) n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 )) ;;
esac
echo "$n" > "$STATE"

if [ "$n" -ge "$THRESHOLD" ]; then
  logger -t opencode-healthcheck "no response ${n}x (last HTTP ${code}); restarting ${SERVICE}"
  systemctl restart "$SERVICE"
  echo 0 > "$STATE"
fi
