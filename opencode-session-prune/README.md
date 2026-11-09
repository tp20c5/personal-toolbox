# opencode-session-prune

Delete old OpenCode sessions and reclaim the disk `opencode.db` has been eating.

| File | Role |
| --- | --- |
| `opencode-session-prune.sh` | The tool: dry-run/report by default, `--apply` to delete + VACUUM |

> 中文摘要：清理 OpenCode 的历史会话、把 `opencode.db` 占用的磁盘还回来。
> 该库只增不减——每个会话都会在 `session` / `message` / `part` / `todo` /
> `session_*` 和只追加的 `event` 日志里留下行，opencode 自己从不清理，忙碌的
> `opencode serve` 机器上文件能涨到几十 GB，既吃磁盘、又让单事件循环卡在长事务上。
> 本工具删除「最后活动早于阈值」的会话**及其同样过期的子代理会话和全部关联行**，然后
> `VACUUM` 回收空间。默认**只读 dry-run**，加 `--apply` 且确认后才写入；写入前
> 自动备份；`opencode serve` 在跑时拒绝写入（除非 `--force`）；`--keep-pattern`
> 命中的标题永不删除。可调过期时长、可先看会话标题、前后打印库大小与各表条数。

## Why this exists

`opencode.db` is one SQLite file that only ever grows. Every session leaves rows
behind in `session`, `message`, `part`, `todo`, the `session_*` tables and the
append-only `event` log (a streamed part writes an event row per update), and
opencode never removes any of them. On a busy `opencode serve` box the file
climbs into the tens of gigabytes, which (a) burns disk and (b) makes the
server's single event loop stall on long synchronous SQLite work — the same
failure mode [opencode-serve-systemd](../opencode-serve-systemd/) exists to
recover from. This tool is the cleanup side of that pair: it actually shrinks
the file instead of just watching it grow.

## What it deletes

| Row source | How |
| --- | --- |
| `session` | Rows idle past the cutoff, **plus their descendants at any depth** |
| `message` | Cascaded by the schema foreign key (`ON DELETE CASCADE`) |
| `part` | Cascaded via `message` |
| `todo` | Cascaded |
| `session_share` / `session_input` / `session_message` / `session_context_epoch` | Cascaded |
| `event_sequence` | The per-session event-stream head, deleted explicitly (it has **no** FK to `session`) |
| `event` | The whole append-only log for those sessions, cascaded from `event_sequence` |

On disk (opt out with `--no-clean-disk`):

| Path | What |
| --- | --- |
| `<data>/storage/session_diff/<session>.json` | Per-session diff cache |

Deleting a matched **parent** session also takes its old **children** (subagent
sessions) with it, so a stale subagent tree is removed whole instead of leaving a
bunch of orphaned children behind. That is the `+ eligible descendants` line in
the report.

But the descendant rule only ever sweeps in a child that is **itself eligible**:
idle past the cutoff, inside `--project`, and not protected by
`--keep-pattern`. So a session that is still active — even a subagent whose
parent aged out — is never deleted just because its parent matched. It keeps a
dangling `parent_id`, which is harmless because nothing references `session(id)`
through it.

## Usage

```bash
# 1. See what would go (read-only). Nothing is written.
./opencode-session-prune.sh --older-than 30d

# 2. Look at the whole list, not just the first 30 titles.
./opencode-session-prune.sh -t 30d --list-limit 0

# 3. Peel a lot of them off, keeping anything whose title matches.
./opencode-session-prune.sh -t 90d --keep-pattern 'IMPORTANT|production' --apply

# 4. Just one project, no prompt, back up first (the default).
./opencode-session-prune.sh -t 14d --project prj_abc123 --apply -y
```

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `-t, --older-than DUR` | `30d` | Delete sessions idle longer than `DUR`. `DUR` = number + `s`/`m`/`h`/`d`/`w`, or a bare number meaning **days** (`30d`, `12h`, `8w`, `90`). |
| `-d, --db PATH` | `$OPENCODE_DB_PATH` or `~/.local/share/opencode/opencode.db` | Database file. |
| `--project IDS` | all | Only consider these project ids (comma separated). |
| `--keep-pattern RE` | none | Never delete a session whose **title** matches this ERE. Applied last, so a protected title survives even as the child of a doomed parent. |
| `--list-limit N` | `30` | How many candidate titles to print; `0` = all. |
| `--apply` | off | Actually delete. Without it, this is a read-only dry run. |
| `-y, --yes` | off | Skip the `[y/N]` confirmation. |
| `--[no-]backup` | on | Back up the DB (via `sqlite3 .backup`) before writing. |
| `--[no-]vacuum` | on | `VACUUM` after deleting to hand the space back. |
| `--[no-]clean-disk` | on | Remove per-session files under `<data>/storage`. |
| `--force` | off | Allow `--apply` while `opencode serve` is running. |
| `-q, --quiet` | off | Less chatter. |
| `-h, --help` | — | Help. |

### Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `OPENCODE_DB_PATH` | `~/.local/share/opencode/opencode.db` | Database file (same as `-d`). |
| `OPENCODE_DATA_DIR` | `dirname(DB)` | Root of the on-disk artifacts (`storage/session_diff/...`). |
| `OPENCODE_SQLITE3` | `sqlite3` | sqlite3 CLI to use. |
| `OPENCODE_PRUNE_SERVICE` | `opencode.service` | Unit checked by `systemctl is-active` for the "server is running" guard. |

## Every run prints before/after stats

The whole point (and the whole feedback loop) is the numbers:

```
== before ==
  db file    : 16G (17373954048 bytes)
  db -wal    : 5M
  sessions   : 4981
  messages   : 159022
  parts      : 702792
  todos      : 6739
  events     : 2046843
  event_seq  : 4565
```

The same block is printed again after the run, so you can see the file and the
row counts actually drop.

## Safety model

It is deliberately conservative: it will not surprise you.

- **Dry run by default.** Only `--apply` writes, and only after a `[y/N]`
  prompt (skip with `-y`). The dry-run path exits *before* any backup, temp
  file or transaction is created.
- **Backup first.** `sqlite3 .backup` to `<db>.backup-<timestamp>` before the
  transaction. It refuses to start if free space is smaller than the DB.
  `--no-backup` to skip.
- **Refuses to write under a live server.** If `opencode serve` (or the
  `OPENCODE_PRUNE_SERVICE` unit) is running, `--apply` aborts. This matters
  because deleting rows behind a live server risks stale in-memory session state,
  and a `VACUUM` on a large DB can stall the server's single event loop for
  minutes. `--force` overrides (VACUUM is then skipped unless you also pass
  `--vacuum`).
- **Cascade, not guess.** The delete runs with `PRAGMA foreign_keys=ON` inside a
  single `BEGIN IMMEDIATE` transaction — without the pragma (the CLI default) the
  cascade silently leaves orphans. Each delete is one transaction, so a failure
  rolls back and leaves the DB unchanged apart from the WAL.
- **Never deletes a session it did not mean to.** A descendant is swept in only
  if it is itself idle past the cutoff, inside `--project`, and unprotected, so
  an active session is never dragged down by an aging parent. This is what keeps
  the tool from deleting the session you are currently sitting in.
- **It refuses to guess a time unit.** `session.time_updated` must look like
  milliseconds (epoch ms); if the biggest value reads like seconds the cutoff
  comparison would match *every* row, so the tool aborts instead. `--older-than 0`
  likewise needs `--force`.
- **It refuses to run out of space halfway.** A backup costs one copy of the DB
  and a `VACUUM` costs roughly another; both are checked up front, and the tool
  dies with a "pass `--no-backup` / `--no-vacuum`" hint rather than leaving the
  space unreclaimed.
- **No SQL injection through ids or titles.** Ids are validated against
  `[A-Za-z0-9_]` before interpolation; titles are only ever *printed*, never
  executed. A database path containing a single quote is rejected outright.
- **A failed query is an error, not an absent table.** `sqlite3` exit codes are
  checked, so a transient lock can never be mistaken for "this table is gone" —
  which would otherwise silently skip pruning the `event` log and orphan it.

## Caveats

- **`--force` while the server runs is genuinely unsafe** and is on you. The
  supported sequence is: stop the service, prune, start it again.
- `VACUUM` needs free disk roughly equal to the DB size and rewrites the whole
  file, so on a 17 GB DB give it time (and do not run it under the live server).
  The tool checks for that space up front and, if it is short, aborts with a
  hint to pass `--no-backup` or `--no-vacuum`.
- Legacy on-disk caches outside the data dir are **not** touched: `~/.opencode/messages`
  and `~/.opencode/parts` are no longer written by current opencode (their dir
  mtimes go back months) and their keying does not map cleanly to the DB, so the
  tool leaves them alone rather than guess. Remove them by hand if you want them
  gone.
- Requires **bash 4+** (associative arrays) and the **sqlite3 CLI**. No other
  dependencies, no build step.
- Verified on CentOS 7 with **sqlite3 3.7.17 (2013)** against a DB created by a
  modern SQLite (3.4x): cascade delete plus VACUUM leave `PRAGMA integrity_check`
  = `ok` and `PRAGMA foreign_key_check` empty, with zero orphaned rows in any
  child table.

## Verify

```bash
# Read-only: confirm the target list before you touch anything.
./opencode-session-prune.sh -t 30d --list-limit 0

# Prove the dry run wrote nothing (size + mtime unchanged): run it, then
stat -c '%n %s %y' ~/.local/share/opencode/opencode.db

# Full sequence on a big DB: stop, prune, start.
sudo systemctl stop opencode.service
./opencode-session-prune.sh -t 90d --apply -y
sudo systemctl start opencode.service

# After an apply, confirm the DB is still sound.
sqlite3 ~/.local/share/opencode/opencode.db 'PRAGMA integrity_check; PRAGMA foreign_key_check;'
```

## License

[MIT](../LICENSE)
