#!/bin/bash
#
# opencode-session-prune.sh -- delete old OpenCode sessions and reclaim the disk.
#
# Why this exists
# ---------------
# `opencode.db` is one SQLite file that only ever grows. Every session leaves
# rows behind in `session`, `message`, `part`, `todo`, `session_*` and the
# append-only `event` log (a streamed part writes an event row per update), and
# opencode never removes any of them. On a busy `opencode serve` box the file
# climbs into the tens of gigabytes, which (a) burns disk and (b) makes the
# server's single event loop stall on long synchronous SQLite work.
#
# This tool deletes the sessions whose last activity is older than a cutoff you
# pick, together with the child (subagent) sessions that hang off them and every
# row that belongs to them, then VACUUMs the file to hand the space back.
#
# It is deliberately conservative -- it will not surprise you:
#   * dry run by default: nothing is written unless you pass --apply AND confirm;
#   * the database is backed up before it is touched (--no-backup to skip);
#   * it refuses to write while `opencode serve` is running unless --force;
#   * titles matching --keep-pattern are never deleted.
#
# A child session is only swept in by the descendant rule when it is *itself*
# eligible -- idle past the cutoff, inside --project and not protected. So a
# session that is still active (even a subagent whose parent aged out) is never
# deleted just because its parent matched; it merely keeps a dangling parent_id,
# which is harmless because no FK constrains it.
#
# What it deletes
#   session         rows older than the cutoff, plus their eligible descendants
#   message         cascaded by the schema FK (ON DELETE CASCADE)
#   part            cascaded via message
#   todo            cascaded
#   session_*       (share/input/message/context_epoch) cascaded
#   event_sequence  the per-session event-stream head, cascaded into `event`
#   event           the whole append-only log for those sessions
# On disk (opt out with --no-clean-disk):
#   <data>/storage/session_diff/<session>.json
#
# The delete relies on `PRAGMA foreign_keys=ON`, which the CLI does not set by
# default -- without it the cascade silently leaves orphans behind.
#
# Requires: bash 4+ and the sqlite3 CLI. No other dependencies.
# Verified on CentOS 7 (sqlite3 3.7.17) against a database created by a modern
# SQLite: cascade delete plus VACUUM leave `PRAGMA integrity_check` = ok.
#
# Environment overrides:
#   OPENCODE_DB_PATH        default ~/.local/share/opencode/opencode.db
#   OPENCODE_DATA_DIR       default dirname(DB)   (for the on-disk artifacts)
#   OPENCODE_SQLITE3        default sqlite3
#   OPENCODE_PRUNE_SERVICE  default opencode.service (checked via systemctl)
#
set -u

PROG="$(basename "$0")"

# ---- defaults ---------------------------------------------------------------

DB_PATH="${OPENCODE_DB_PATH:-$HOME/.local/share/opencode/opencode.db}"
DATA_DIR="${OPENCODE_DATA_DIR:-}"
SQLITE3="${OPENCODE_SQLITE3:-sqlite3}"
SERVICE="${OPENCODE_PRUNE_SERVICE:-opencode.service}"

OLDER_THAN="30d"          # bare number = days; suffixes s/m/h/d/w
LIST_LIMIT=30             # candidate titles to show; 0 = all
KEEP_PATTERN=""           # ERE; matching titles are protected
PROJECTS=""               # comma-separated project ids to limit to

MODE=dryrun               # dryrun | apply
ASSUME_YES=0
DO_VACUUM=-1              # -1 = auto (on when applying), 1 = on, 0 = off
DO_BACKUP=1
DO_CLEAN_DISK=1
FORCE=0
QUIET=0

SEP=$'\x1f'               # unit separator for multi-field reads

# ---- helpers ----------------------------------------------------------------

die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
info() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

usage() {
  cat <<EOF
$PROG -- delete old OpenCode sessions and reclaim disk space.

Usage:
  $PROG [options]

Options:
  -t, --older-than DUR   Delete sessions idle for longer than DUR (default 30d).
                         DUR = number + s|m|h|d|w, or a bare number meaning days.
                         Examples: 30d, 12h, 8w, 90.
  -d, --db PATH          Database file (default \$OPENCODE_DB_PATH or the
                         standard ~/.local/share/opencode/opencode.db).
      --project IDS      Only consider these project ids (comma separated).
      --keep-pattern RE  Never delete a session whose title matches this ERE.
      --list-limit N     Show at most N candidate titles (default 30; 0 = all).
      --apply            Actually delete. Without it this is a read-only dry run.
  -y, --yes              Do not ask for confirmation (implies you mean it).
      --[no-]backup      Back up the DB before writing (default: on for --apply).
      --[no-]vacuum      VACUUM after deleting to reclaim space (default: on).
      --[no-]clean-disk  Remove per-session files under <data>/storage (default on).
      --force            Allow --apply while opencode serve is running.
  -q, --quiet            Less chatter.
  -h, --help             This help.

Every run prints before/after stats: the DB file size, the session count and the
message / part / todo / event row counts.
EOF
}

human_bytes() {
  local b="$1" unit=0
  while [ "$b" -ge 1024 ] && [ "$unit" -lt 4 ]; do
    b=$(( b / 1024 )); unit=$(( unit + 1 ))
  done
  case "$unit" in
    0) printf '%sB' "$b" ;;
    1) printf '%sK' "$b" ;;
    2) printf '%sM' "$b" ;;
    3) printf '%sG' "$b" ;;
    *) printf '%sT' "$b" ;;
  esac
}

# Render an age in seconds as "3d 4h" / "5h 12m" / "9m".
human_age() {
  local s="$1" d h m
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else                      printf '%dm' "$m"
  fi
}

# parse_duration DUR -> seconds (stdout) or non-zero on bad input.
parse_duration() {
  local v="$1" n mult
  case "$v" in
    *s) n="${v%s}"; mult=1 ;;
    *m) n="${v%m}"; mult=60 ;;
    *h) n="${v%h}"; mult=3600 ;;
    *d) n="${v%d}"; mult=86400 ;;
    *w) n="${v%w}"; mult=604800 ;;
    *)  n="$v";     mult=86400 ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' $(( n * mult ))
}

# q <sql> -- run one read query, '|'-separated rows. Dies on error so a transient
# failure is never mistaken for "no rows".
q() {
  local out rc
  out="$("$SQLITE3" -separator '|' "$DB_PATH" "$1")"; rc=$?
  [ "$rc" -eq 0 ] || die "sqlite3 query failed (exit $rc): $1"
  printf '%s' "$out"
}

db_bytes() { stat -c %s "$1" 2>/dev/null || echo 0; }

# Table existence, cached: the set cannot change during a run, so this turns the
# dozen lookups in print_stats into one query per table.
declare -A TABLE_OK=()
have_table() {
  local t="$1" out
  if [ -z "${TABLE_OK[$t]:-}" ]; then
    out="$(q "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$t';")" \
      || die "failed to query schema for table '$t'"
    if [ "$out" = 1 ]; then TABLE_OK["$t"]=1; else TABLE_OK["$t"]=0; fi
  fi
  [ "${TABLE_OK[$t]}" = 1 ]
}

# ---- argument parsing -------------------------------------------------------

need_val() { # need_val NAME VALUE
  [ -n "${2:-}" ] || die "$1 needs a value"
}

while [ $# -gt 0 ]; do
  arg="$1"
  case "$arg" in
    -t|--older-than)   need_val "$arg" "${2:-}"; OLDER_THAN="$2"; shift 2 ;;
    --older-than=*)    OLDER_THAN="${arg#*=}"; shift ;;
    -d|--db)           need_val "$arg" "${2:-}"; DB_PATH="$2"; shift 2 ;;
    --db=*)            DB_PATH="${arg#*=}"; shift ;;
    --project)         need_val "$arg" "${2:-}"; PROJECTS="$2"; shift 2 ;;
    --project=*)       PROJECTS="${arg#*=}"; shift ;;
    --keep-pattern)    KEEP_PATTERN="${2:-}"; shift 2 ;;
    --keep-pattern=*)  KEEP_PATTERN="${arg#*=}"; shift ;;
    --list-limit)      need_val "$arg" "${2:-}"; LIST_LIMIT="$2"; shift 2 ;;
    --list-limit=*)    LIST_LIMIT="${arg#*=}"; shift ;;
    --apply)           MODE=apply; shift ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    --backup)          DO_BACKUP=1; shift ;;
    --no-backup)       DO_BACKUP=0; shift ;;
    --vacuum)          DO_VACUUM=1; shift ;;
    --no-vacuum)       DO_VACUUM=0; shift ;;
    --clean-disk)      DO_CLEAN_DISK=1; shift ;;
    --no-clean-disk)   DO_CLEAN_DISK=0; shift ;;
    --force)           FORCE=1; shift ;;
    -q|--quiet)        QUIET=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; break ;;
    -*)                die "unknown option: $arg (try --help)" ;;
    *)                 die "unexpected argument: $arg (try --help)" ;;
  esac
done

case "$LIST_LIMIT" in ''|*[!0-9]*) die "--list-limit must be a non-negative integer" ;; esac

AGE_SECS="$(parse_duration "$OLDER_THAN")" || die "bad --older-than value: $OLDER_THAN (use e.g. 30d, 12h, 8w, 90)"
if [ "$AGE_SECS" -eq 0 ] && [ "$FORCE" != 1 ]; then
  die "--older-than 0 would delete essentially every session; pass --force if you really mean it"
fi

# ---- preflight --------------------------------------------------------------

command -v "$SQLITE3" >/dev/null 2>&1 || die "sqlite3 not found (set OPENCODE_SQLITE3)"
case "$SQLITE3" in */*) [ -x "$SQLITE3" ] || die "not executable: $SQLITE3" ;; esac
[ -f "$DB_PATH" ] || die "database not found: $DB_PATH"
case "$DB_PATH" in *"'"*) die "database path contains a single quote; not supported" ;; esac

[ -z "$DATA_DIR" ] && DATA_DIR="$(dirname "$DB_PATH")"

q "SELECT 1;" >/dev/null 2>&1 || die "cannot open database: $DB_PATH"
have_table session || die "no 'session' table in $DB_PATH -- is this an opencode database?"
have_table event_sequence || warn "no 'event_sequence' table; the event log will not be pruned"

# opencode stores epoch MILLIseconds. If this column holds seconds the cutoff
# comparison below would match every session -- refuse to guess a unit.
max_upd="$(q "SELECT COALESCE(MAX(time_updated),0) FROM session;")" \
  || die "cannot read session timestamps"
case "$max_upd" in
  ''|*[!0-9]*) : ;;
  *) if [ "$max_upd" -gt 0 ] && [ "$max_upd" -lt 100000000000 ]; then
       die "session.time_updated looks like seconds (max=$max_upd), not milliseconds; refusing to guess"
     fi ;;
esac

NOW=$(date +%s)
CUTOFF_MS=$(( (NOW - AGE_SECS) * 1000 ))
CUTOFF_HUMAN=$(date -d "@$((NOW - AGE_SECS))" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")

# ---- target selection -------------------------------------------------------

# --project: an SQL IN-list for the query, plus a set for the bash-side filter.
PROJ_CLAUSE=""
declare -A PROJ_SET=()
if [ -n "$PROJECTS" ]; then
  IFS=',' read -r -a _projs <<<"$PROJECTS"
  for pr in "${_projs[@]}"; do
    [ -n "$pr" ] || continue
    case "$pr" in *[!A-Za-z0-9_-]*) die "bad project id: $pr" ;; esac
    PROJ_SET["$pr"]=1
  done
  [ "${#PROJ_SET[@]}" -gt 0 ] || die "--project needs at least one id"
  PROJ_CLAUSE=" AND project_id IN ("
  first=1
  for pr in "${!PROJ_SET[@]}"; do
    if [ "$first" = 1 ]; then first=0; else PROJ_CLAUSE="$PROJ_CLAUSE,"; fi
    PROJ_CLAUSE="$PROJ_CLAUSE'$pr'"
  done
  PROJ_CLAUSE="$PROJ_CLAUSE)"
fi

# Load every session's title / last-update / parent / project once. Titles may
# contain any byte, so fields are joined with the ASCII unit separator, not '|';
# 0x1f itself is scrubbed so it can never split a field.
declare -A S_TITLE=() S_TIME=() S_PARENT=() S_PROJ=()
meta="$("$SQLITE3" -separator "$SEP" "$DB_PATH" \
  "SELECT id,
          replace(replace(replace(title,char(10),' '),char(13),' '),char(31),' '),
          time_updated, COALESCE(parent_id,''), project_id
     FROM session;")" || die "failed to read sessions from $DB_PATH"
while IFS="$SEP" read -r sid stitle supd sparent sproj; do
  [ -n "$sid" ] || continue
  S_TITLE["$sid"]="$stitle"
  S_TIME["$sid"]="$supd"
  S_PARENT["$sid"]="$sparent"
  S_PROJ["$sid"]="$sproj"
done <<<"$meta"

# --keep-pattern predicate (ERE against the title).
is_protected() {
  [ -n "$KEEP_PATTERN" ] || return 1
  printf '%s' "${S_TITLE[$1]:-}" | grep -Eq -- "$KEEP_PATTERN"
}

# A session may be swept in by the descendant rule only when it is itself
# eligible: idle past the cutoff, inside --project, and not protected.
cascade_eligible() {
  local sid="$1"
  [ "${S_TIME[$sid]:-0}" -lt "$CUTOFF_MS" ] || return 1
  if [ "${#PROJ_SET[@]}" -gt 0 ]; then
    [ -n "${PROJ_SET[${S_PROJ[$sid]:-}]:-}" ] || return 1
  fi
  is_protected "$sid" && return 1
  return 0
}

# Initial matches: sessions idle past the cutoff (and inside --project).
declare -A DOOMED=()
matched_age=0
kept_count=0
age_rows="$(q "SELECT id FROM session WHERE time_updated < $CUTOFF_MS$PROJ_CLAUSE;")" \
  || die "failed to select candidates"
while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  matched_age=$(( matched_age + 1 ))
  if is_protected "$sid"; then kept_count=$(( kept_count + 1 )); continue; fi
  DOOMED["$sid"]=1
done <<<"$age_rows"
matched_count=${#DOOMED[@]}

# Expand to eligible descendants at any depth: an old parent takes its old
# children with it, so a stale subagent tree is removed whole. A child that is
# still active -- or out of --project, or protected -- is left alone, even though
# that leaves its parent_id dangling (harmless: no FK references parent_id).
changed=1
while [ "$changed" = 1 ]; do
  changed=0
  if [ "${#S_PARENT[@]}" -gt 0 ]; then
    for sid in "${!S_PARENT[@]}"; do
      p="${S_PARENT[$sid]}"
      [ -n "$p" ] || continue
      [ -n "${DOOMED[$p]:-}" ] || continue
      [ -z "${DOOMED[$sid]:-}" ] || continue
      cascade_eligible "$sid" || continue
      DOOMED["$sid"]=1
      changed=1
    done
  fi
done
descendant_added=$(( ${#DOOMED[@]} - matched_count ))

doomed_count=${#DOOMED[@]}

# ---- stats ------------------------------------------------------------------

print_stats() {
  local label="$1" sql="" t row
  for t in session message part todo event event_sequence; do
    if have_table "$t"; then sql="${sql:+$sql,}(SELECT COUNT(*) FROM $t)"; else sql="${sql:+$sql,}0"; fi
  done
  row="$(q "SELECT $sql;")" || die "failed to read stats"
  IFS='|' read -r n_session n_message n_part n_todo n_event n_eseq <<<"$row"
  printf '\n== %s ==\n' "$label"
  printf '  db file    : %s (%s bytes)\n' "$(human_bytes "$(db_bytes "$DB_PATH")")" "$(db_bytes "$DB_PATH")"
  [ -f "$DB_PATH-wal" ] && printf '  db -wal    : %s\n' "$(human_bytes "$(db_bytes "$DB_PATH-wal")")"
  printf '  sessions   : %s\n' "$n_session"
  printf '  messages   : %s\n' "$n_message"
  printf '  parts      : %s\n' "$n_part"
  printf '  todos      : %s\n' "$n_todo"
  printf '  events     : %s\n' "$n_event"
  printf '  event_seq  : %s\n' "$n_eseq"
}

# ---- report -----------------------------------------------------------------

printf '%s\n' 'opencode-session-prune'
printf '  database     : %s\n' "$DB_PATH"
printf '  cutoff       : idle longer than %s (before %s)\n' "$OLDER_THAN" "$CUTOFF_HUMAN"
printf '  mode         : %s\n' "$([ "$MODE" = apply ] && echo 'APPLY (will delete)' || echo 'DRY RUN (read-only)')"
[ -n "$KEEP_PATTERN" ] && printf '  keep-pattern : %s\n' "$KEEP_PATTERN"
[ -n "$PROJECTS" ]     && printf '  projects     : %s\n' "$PROJECTS"

print_stats "before"

printf '\n== candidates ==\n'
printf '  matched by age         : %s\n' "$matched_age"
printf '  + eligible descendants : %s\n' "$descendant_added"
[ "$kept_count" -gt 0 ] && printf '  - protected by pattern : %s\n' "$kept_count"
printf '  = to delete            : %s\n' "$doomed_count"

if [ "$doomed_count" -eq 0 ]; then
  printf '\nNothing to do.\n'
  exit 0
fi

printf '\n  %-3s %-17s %-10s %s\n' '#' 'UPDATED' 'AGE' 'TITLE  (id)'
shown=0
while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  upd="${S_TIME[$sid]:-0}"
  when=$(date -d "@$(( upd / 1000 ))" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')
  age=$(human_age $(( NOW - upd / 1000 )))
  printf '  %-3d %-17s %-10s %s  (%s)\n' "$((shown + 1))" "$when" "$age" "${S_TITLE[$sid]:-}" "$sid"
  shown=$(( shown + 1 ))
  [ "$LIST_LIMIT" -ne 0 ] && [ "$shown" -ge "$LIST_LIMIT" ] && break
done < <(for sid in "${!DOOMED[@]}"; do printf '%s|%s\n' "$sid" "${S_TIME[$sid]:-0}"; done | sort -t'|' -k2,2n | cut -d'|' -f1)

if [ "$LIST_LIMIT" -ne 0 ] && [ "$doomed_count" -gt "$LIST_LIMIT" ]; then
  printf '  ... and %d more (use --list-limit 0 to show all)\n' "$((doomed_count - LIST_LIMIT))"
fi

# ---- guards -----------------------------------------------------------------

server_running=0
if command -v pgrep >/dev/null 2>&1 && pgrep -f 'opencode serve' >/dev/null 2>&1; then
  server_running=1
fi
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  server_running=1
fi

if [ "$MODE" = dryrun ]; then
  printf '\nDRY RUN: nothing was written. Re-run with --apply to delete.\n'
  exit 0
fi

if [ "$server_running" = 1 ] && [ "$FORCE" != 1 ]; then
  cat >&2 <<EOF
$PROG: error: 'opencode serve' looks like it is running.

Deleting rows behind a live server risks stale in-memory session state, and a
VACUUM on a large DB can stall its single event loop for minutes. Stop it first:

    sudo systemctl stop $SERVICE      # or stop it however you started it

then re-run. Pass --force to proceed anyway (VACUUM is then skipped unless you
also pass --vacuum).
EOF
  exit 1
fi

if [ "$server_running" = 1 ]; then
  warn "server is running and --force was given; proceeding (unsafe)"
  [ "$DO_VACUUM" = -1 ] && DO_VACUUM=0
fi

[ "$DO_VACUUM" = -1 ] && DO_VACUUM=1

# Free-space preflight: a backup copies the whole file and a VACUUM on a large DB
# needs roughly another copy as scratch. Refuse up front rather than fail halfway
# through and leave the space unreclaimed.
db_sz=$(db_bytes "$DB_PATH")
need_bytes=0
[ "$DO_BACKUP" = 1 ] && need_bytes=$(( need_bytes + db_sz ))
[ "$DO_VACUUM" = 1 ] && need_bytes=$(( need_bytes + db_sz ))
if [ "$need_bytes" -gt 0 ]; then
  free_kb=$(df -Pk "$(dirname "$DB_PATH")" | awk 'NR==2{print $4}')
  if [ -n "$free_kb" ] && [ "$(( free_kb * 1024 ))" -lt "$need_bytes" ]; then
    die "not enough free space: need ~$(human_bytes "$need_bytes") for backup+VACUUM, have $(human_bytes $(( free_kb * 1024 ))) -- pass --no-backup and/or --no-vacuum"
  fi
fi

if [ "$ASSUME_YES" != 1 ]; then
  printf '\nDelete %d session(s) and all their rows from %s? [y/N] ' "$doomed_count" "$DB_PATH"
  reply=""
  read -r reply || true
  case "$reply" in
    y|Y|yes|YES) ;;
    *) printf 'Aborted.\n'; exit 0 ;;
  esac
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/ocprune.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT

# ---- backup -----------------------------------------------------------------

if [ "$DO_BACKUP" = 1 ]; then
  BK="${DB_PATH}.backup-$(date +%Y%m%d_%H%M%S)"
  info "backing up to $BK ..."
  "$SQLITE3" -bail "$DB_PATH" ".backup '$BK'" >/dev/null 2>&1 \
    || die "backup failed (nothing was deleted)"
  info "backup ok: $(human_bytes "$(db_bytes "$BK")")"
else
  warn "backup disabled (--no-backup)"
fi

# ---- delete -----------------------------------------------------------------

# Ids are opencode-generated [A-Za-z0-9_]; validate them before interpolating so
# nothing can smuggle SQL in through an id.
: > "$TMPD/delete.sql"
{
  echo "PRAGMA foreign_keys=ON;"
  echo "PRAGMA busy_timeout=30000;"
  echo "BEGIN IMMEDIATE;"
  echo "CREATE TEMP TABLE doomed(id TEXT PRIMARY KEY);"
  for sid in "${!DOOMED[@]}"; do
    case "$sid" in *[!A-Za-z0-9_]*) die "refusing to quote suspicious id: $sid" ;; esac
    printf "INSERT INTO doomed(id) VALUES('%s');\n" "$sid"
  done
  echo "DELETE FROM session WHERE id IN (SELECT id FROM doomed);"
  have_table event_sequence && echo "DELETE FROM event_sequence WHERE aggregate_id IN (SELECT id FROM doomed);"
  echo "COMMIT;"
  echo "PRAGMA wal_checkpoint(TRUNCATE);"
} > "$TMPD/delete.sql"

info "deleting $doomed_count session(s) ..."
"$SQLITE3" -bail "$DB_PATH" < "$TMPD/delete.sql" >/dev/null 2>&1 \
  || die "delete failed; the transaction was rolled back (DB unchanged apart from WAL)"

# ---- vacuum -----------------------------------------------------------------

if [ "$DO_VACUUM" = 1 ]; then
  info "vacuuming (may take a while on a large DB) ..."
  if "$SQLITE3" -bail "$DB_PATH" "PRAGMA busy_timeout=120000; VACUUM;" >/dev/null 2>&1; then
    info "vacuum ok"
  else
    warn "VACUUM failed (likely locked); rows are deleted, space not yet reclaimed"
  fi
else
  info "skipping VACUUM; rows are deleted but space is not reclaimed (VACUUM later to reclaim)"
fi

# ---- on-disk artifacts ------------------------------------------------------

if [ "$DO_CLEAN_DISK" = 1 ]; then
  rm_count=0
  for sid in "${!DOOMED[@]}"; do
    case "$sid" in *[!A-Za-z0-9_]*) continue ;; esac
    f="$DATA_DIR/storage/session_diff/$sid.json"
    if [ -f "$f" ]; then rm -f "$f" && rm_count=$(( rm_count + 1 )); fi
  done
  info "removed $rm_count per-session file(s) under $DATA_DIR/storage/session_diff"
fi

# ---- after ------------------------------------------------------------------

print_stats "after"
printf '\nDone. Deleted %d session(s).\n' "$doomed_count"
