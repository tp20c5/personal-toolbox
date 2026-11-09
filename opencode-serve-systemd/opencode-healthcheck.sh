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
# On top of the restart it can raise IM webhook alerts (WeCom / Feishu /
# DingTalk / generic), watch the size of opencode.db and detect a stop-timeout
# SIGKILL. The DB is only `stat`ed -- it is never opened, written, deleted or
# vacuumed. Everything it touches is under /run; it makes no persistent changes.
#
# Overridable via environment:
#   OPENCODE_HEALTHCHECK_URL        default http://127.0.0.1:4096/
#   OPENCODE_HEALTHCHECK_THRESHOLD  default 3
#   OPENCODE_HEALTHCHECK_SERVICE    default opencode.service
#   OPENCODE_HEALTHCHECK_NORESTART  if 1, log the restart but do not run it
#   OPENCODE_ALERT_CONF             default /etc/opencode-healthcheck.conf
#   OPENCODE_ALERT_WEBHOOK          default empty (alerts disabled)
#   OPENCODE_ALERT_KIND             wecom|feishu|dingtalk|generic (default wecom)
#   OPENCODE_ALERT_SILENCE          de-dup window in seconds (default 600)
#   OPENCODE_ALERT_PREFIX           default opencode@$(hostname -s)
#   OPENCODE_ALERT_DRYRUN           if 1, print JSON only (no send, no journal)
#   OPENCODE_DB_PATH                default /home/you/.local/share/opencode/opencode.db
#   OPENCODE_DB_WARN_BYTES          default 17179869184 (16 GiB)
#   OPENCODE_METRICS_FILE           default /run/opencode-healthcheck/metrics.log
#
set -u

# Pull in the operator config early, so both manual runs and the systemd
# EnvironmentFile pick up the same values. A missing file is fine.
ALERT_CONF="${OPENCODE_ALERT_CONF:-/etc/opencode-healthcheck.conf}"
if [ -r "$ALERT_CONF" ]; then
  # shellcheck disable=SC1090
  . "$ALERT_CONF"
fi

URL="${OPENCODE_HEALTHCHECK_URL:-http://127.0.0.1:4096/}"
STATE="/run/opencode-healthcheck.fail"
THRESHOLD="${OPENCODE_HEALTHCHECK_THRESHOLD:-3}"
SERVICE="${OPENCODE_HEALTHCHECK_SERVICE:-opencode.service}"

STATE_DIR="/run/opencode-healthcheck"

# ---- helpers ---------------------------------------------------------------

# Escape a string for safe embedding inside a JSON double-quoted value.
# The probe never emits newlines, so only backslash and double-quote matter.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Render a byte count as a short human-readable IEC string (du -h style).
human_bytes() {
  local b="$1" unit=0
  while [ "$b" -ge 1024 ] && [ "$unit" -lt 4 ]; do
    b=$(( b / 1024 ))
    unit=$(( unit + 1 ))
  done
  case "$unit" in
    0) printf '%sB' "$b" ;;
    1) printf '%sK' "$b" ;;
    2) printf '%sM' "$b" ;;
    3) printf '%sG' "$b" ;;
    *) printf '%sT' "$b" ;;
  esac
}

# Build the webhook JSON body for the configured kind.
alert_body() {
  case "${OPENCODE_ALERT_KIND:-wecom}" in
    feishu)  printf '{"msg_type":"text","content":{"text":"%s"}}' "$(json_escape "$1")" ;;
    generic) printf '{"text":"%s"}' "$(json_escape "$1")" ;;
    *)       printf '{"msgtype":"text","text":{"content":"%s"}}' "$(json_escape "$1")" ;;
  esac
}

# log <message...>
# Write to the journal, except under OPENCODE_ALERT_DRYRUN, where the probe is a
# pure simulation and must not touch the journal at all.
log() {
  [ "${OPENCODE_ALERT_DRYRUN:-0}" = "1" ] && return 0
  logger -t opencode-healthcheck "$@"
}

# alert <key> <severity> <message>
# In production: always logs to the journal, then sends to the webhook unless
# disabled or silenced. Under OPENCODE_ALERT_DRYRUN it is a pure simulation --
# it prints the payload to stdout and touches neither the journal nor the wire.
# The silence window is per <key>, tracked under /run/opencode-healthcheck.
alert() {
  local key="$1" severity="$2" msg="$3"
  local now ts prefix full json last stamp_file

  now=$(date +%s)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  prefix="${OPENCODE_ALERT_PREFIX:-opencode@$(hostname -s)}"
  full="${prefix} [${severity}] ${msg}  (${ts})"

  # A dry run is a pure simulation: print the payload, send nothing, log nothing,
  # and do not consume the silence slot. Checked first so tests stay out of the
  # journal.
  if [ "${OPENCODE_ALERT_DRYRUN:-0}" = "1" ]; then
    printf 'DRYRUN alert key=%s url=%s\n' "$key" "${OPENCODE_ALERT_WEBHOOK:-}"
    printf '%s\n' "$(alert_body "$full")"
    return 0
  fi

  # The journal always gets the record, even when the webhook is off/silenced.
  log "ALERT ${key} [${severity}] ${msg}"

  # No webhook configured -> alerts are disabled (the restart still happens).
  if [ -z "${OPENCODE_ALERT_WEBHOOK:-}" ]; then
    return 0
  fi

  json=$(alert_body "$full")

  mkdir -p "$STATE_DIR" 2>/dev/null || true
  stamp_file="${STATE_DIR}/alert_${key}"

  # De-dup / silence window, per alert key.
  if [ -f "$stamp_file" ]; then
    last=$(cat "$stamp_file" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $(( now - last )) -lt "${OPENCODE_ALERT_SILENCE:-600}" ]; then
      logger -t opencode-healthcheck "alert ${key} silenced (last sent ${last})"
      return 0
    fi
  fi

  curl -s -m 5 -H 'Content-Type: application/json' -d "$json" "$OPENCODE_ALERT_WEBHOOK" >/dev/null 2>&1 \
    || logger -t opencode-healthcheck "alert ${key} webhook POST failed"
  echo "$now" > "$stamp_file" 2>/dev/null || true
}

# ---- liveness (unchanged semantics) ----------------------------------------

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$URL" 2>/dev/null || echo 000)

case "$code" in
  2*|3*|401|403|404) n=0 ;;
  *) n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 )) ;;
esac
echo "$n" > "$STATE"

if [ "$n" -ge "$THRESHOLD" ]; then
  log "no response ${n}x (last HTTP ${code}); restarting ${SERVICE}"
  alert wedged_restart CRITICAL "no response ${n}x (last HTTP ${code}); restarting ${SERVICE}"
  if [ "${OPENCODE_HEALTHCHECK_NORESTART:-0}" = "1" ]; then
    log "OPENCODE_HEALTHCHECK_NORESTART=1; not restarting ${SERVICE}"
  else
    systemctl restart "$SERVICE"
  fi
  echo 0 > "$STATE"
fi

# ---- DB size (alert only; never mutate the DB) -----------------------------

DB_PATH="${OPENCODE_DB_PATH:-/home/you/.local/share/opencode/opencode.db}"
DB_WARN="${OPENCODE_DB_WARN_BYTES:-17179869184}"
db_bytes=""
if [ -f "$DB_PATH" ]; then
  db_bytes=$(stat -c %s "$DB_PATH" 2>/dev/null || echo "")
  case "$db_bytes" in ''|*[!0-9]*) db_bytes="" ;; esac
  if [ -n "$db_bytes" ] && [ "$db_bytes" -ge "$DB_WARN" ]; then
    alert db_size WARNING "opencode.db is $(human_bytes "$db_bytes") (>= $(human_bytes "$DB_WARN")) at ${DB_PATH}"
  fi
fi

# ---- SIGKILL / stop-timeout visibility -------------------------------------

svc_show=$(systemctl show -p Result,ExecMainStatus,ExecMainStartTimestamp "$SERVICE" 2>/dev/null || true)
result=$(printf '%s\n' "$svc_show" | sed -n 's/^Result=//p')
exec_status=$(printf '%s\n' "$svc_show" | sed -n 's/^ExecMainStatus=//p')
start_ts=$(printf '%s\n' "$svc_show" | sed -n 's/^ExecMainStartTimestamp=//p')

if [ -n "$start_ts" ]; then
  last_start_file="${STATE_DIR}/last_start"
  prev_start=$(cat "$last_start_file" 2>/dev/null || echo "")
  if [ "$start_ts" != "$prev_start" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    echo "$start_ts" > "$last_start_file" 2>/dev/null || true
    case "${result}:${exec_status}" in
      signal:9|timeout:9|watchdog:9)
        alert sigkill CRITICAL "service was force-killed (SIGKILL) -- process likely ignored SIGTERM (${result}:${exec_status})"
        ;;
    esac
  fi
fi

# ---- optional metrics (no alert) -------------------------------------------

METRICS_FILE="${OPENCODE_METRICS_FILE:-/run/opencode-healthcheck/metrics.log}"
cg_stat="/sys/fs/cgroup/cpu,cpuacct/system.slice/${SERVICE}/cpu.stat"
nr_throttled=0
throttled_time=0
if [ -r "$cg_stat" ]; then
  v=$(sed -n 's/^nr_throttled //p' "$cg_stat" 2>/dev/null); [ -n "$v" ] && nr_throttled="$v"
  v=$(sed -n 's/^throttled_time //p' "$cg_stat" 2>/dev/null); [ -n "$v" ] && throttled_time="$v"
fi
mkdir -p "$(dirname "$METRICS_FILE")" 2>/dev/null || true
printf '%s db_bytes=%s nr_throttled=%s throttled_time=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${db_bytes:-0}" "$nr_throttled" "$throttled_time" \
  >> "$METRICS_FILE" 2>/dev/null || true
