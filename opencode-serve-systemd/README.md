# opencode-serve-systemd

Run `opencode serve` under systemd with sane resource limits and a self-healing
liveness probe, so a wedged server restarts itself instead of sitting dead until
someone notices.

| File | Role |
| --- | --- |
| `opencode.service` | The systemd unit for the server (resource limits + restart policy) |
| `opencode-healthcheck.sh` | The liveness probe: forces a restart of a hung server |
| `opencode-healthcheck.service` | oneshot unit that runs the probe |
| `opencode-healthcheck.timer` | Fires the probe once a minute |
| `opencode-alert.conf.example` | Template for the IM webhook / DB-watch config (`/etc/opencode-healthcheck.conf`) |

> 中文摘要：把 `opencode serve` 作为 systemd 服务运行，并配一个每分钟一次的
> 存活探针。核心动机：`opencode serve` 是单进程单事件循环，一旦事件循环被
> 某个长时间同步 SQLite 调用卡住，进程还活着、但既不响应 HTTP 也不响应
> SIGTERM——此时 `Restart=always` 永远不会触发，机器就带着一个僵死服务干等
> 人工重启。探针负责发现这种「假死」并强制重启。另含 CPU 配额、文件句柄、
> 停止超时等针对高并发/大库场景的调优。

## Why the health probe is needed

systemd can only restart a process that *exits*. A hung Bun/Node process does not
exit: the event loop is blocked by a long synchronous call, so it stops serving
requests, stops logging, and ignores SIGTERM (systemd then waits `TimeoutStopSec`
and SIGKILLs it). `Restart=always` is blind to this state. The probe is the only
thing that turns "wedged forever" into "wedged for ~3 minutes".

The probe treats **any** HTTP response as healthy -- including `401`, which is
what `GET /` returns when `OPENCODE_SERVER_PASSWORD` is set. Only a timeout,
connection failure or 5xx counts as a strike. After 3 consecutive strikes
(~3 minutes) it runs `systemctl restart opencode.service`.

## Alerting

The probe can push an IM webhook alert whenever something is wrong. Alerts are
**off by default**: set `OPENCODE_ALERT_WEBHOOK` (via
`/etc/opencode-healthcheck.conf`, `chmod 600`) to enable them. With no webhook
the probe still restarts a wedged server and only records the event via
`logger -t opencode-healthcheck` (visible in `journalctl`).

### Alert triggers

| Alert key | Severity | When it fires |
| --- | --- | --- |
| `wedged_restart` | CRITICAL | The probe itself restarts the service after `THRESHOLD` consecutive failures |
| `db_size` | WARNING | `opencode.db` size `>= OPENCODE_DB_WARN_BYTES` |
| `sigkill` | CRITICAL | The last service run ended with `Result=signal`/`timeout` and `ExecMainStatus=9` (force-killed after ignoring SIGTERM); fired at most once per new `ExecMainStartTimestamp` |

Every alert is logged to the journal first, so the journal always has the full
record even when the webhook is disabled or silenced (a dry run is the
exception: it neither sends nor logs).

Message format:

```
<PREFIX> [<SEVERITY>] <message>  (<ISO-8601 UTC timestamp>)
```

### Webhook kinds

`OPENCODE_ALERT_KIND` selects the JSON body:

| Kind | Body |
| --- | --- |
| `wecom` (default) | `{"msgtype":"text","text":{"content":"<msg>"}}` |
| `dingtalk` | `{"msgtype":"text","text":{"content":"<msg>"}}` |
| `feishu` | `{"msg_type":"text","content":{"text":"<msg>"}}` |
| `generic` | `{"text":"<msg>"}` |

Sent with `curl -s -m 5 -H 'Content-Type: application/json' -d "$json" "$OPENCODE_ALERT_WEBHOOK"`.
The message is JSON-escaped (backslashes and double-quotes).

### De-dup / silence

Per alert key, the epoch of the last send is kept in
`/run/opencode-healthcheck/alert_<key>`. A new alert with the same key is
skipped when `now - last < OPENCODE_ALERT_SILENCE` (default 600 s), so a
persistent problem pages at most once per window. `OPENCODE_ALERT_DRYRUN=1`
prints the exact JSON + URL to stdout and never sends, and writes nothing to
the journal; a dry run is a pure simulation and does not consume the silence
slot.

### Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `OPENCODE_ALERT_CONF` | `/etc/opencode-healthcheck.conf` | Sourced early if readable |
| `OPENCODE_ALERT_WEBHOOK` | empty | Webhook URL; empty disables alerts |
| `OPENCODE_ALERT_KIND` | `wecom` | `wecom` / `feishu` / `dingtalk` / `generic` |
| `OPENCODE_ALERT_SILENCE` | `600` | Per-key de-dup window (seconds) |
| `OPENCODE_ALERT_PREFIX` | `opencode@$(hostname -s)` | Message prefix |
| `OPENCODE_ALERT_DRYRUN` | unset | `1` = print JSON only (no send, no journal) |
| `OPENCODE_DB_PATH` | `/home/opencode/.local/share/opencode/opencode.db` | File to size-watch |
| `OPENCODE_DB_WARN_BYTES` | `17179869184` (16 GiB) | Alert threshold |
| `OPENCODE_METRICS_FILE` | `/run/opencode-healthcheck/metrics.log` | Optional per-run metrics |
| `OPENCODE_HEALTHCHECK_NORESTART` | unset | `1` = log the restart, do not run it (testing) |

**The probe never mutates the database.** It only `stat`s the file size. It
never opens, reads, writes, deletes or vacuums `opencode.db`; the size check is
alert-only by design.

> 中文摘要：探针可推送 IM webhook 告警（企业微信/飞书/钉钉/通用），**默认关闭**
> ——在 `/etc/opencode-healthcheck.conf`（`chmod 600`）里填 `OPENCODE_ALERT_WEBHOOK`
> 才会启用；未配置时仍照常重启僵死服务，仅通过 `logger` 记入 journal。
> 告警触发点：`wedged_restart`（探针自身触发重启）、`db_size`（`opencode.db`
> 超过 `OPENCODE_DB_WARN_BYTES`，默认 16 GiB）、`sigkill`（上次运行被 SIGKILL，
> 即进程忽略 SIGTERM，每个新的启动时间戳最多告警一次）。消息格式为
> `<前缀> [<级别>] <内容>  (<ISO-8601 时间戳>)`。去重：按告警键记录上次发送时间，
> `now - last < OPENCODE_ALERT_SILENCE`（默认 600 秒）内不重复发送。
> **探针绝不改动数据库**：只对文件做 `stat` 取大小，绝不打开/读取/写入/删除/vacuum。

## Install

The commands below assume CentOS 7 / systemd 219 and a `/home/opencode` layout.
Adjust paths to taste.

```bash
# 1. Server unit
sudo cp opencode.service /etc/systemd/system/opencode.service

# 2. Health probe
sudo cp opencode-healthcheck.sh        /usr/local/sbin/opencode-healthcheck.sh
sudo chmod +x                          /usr/local/sbin/opencode-healthcheck.sh
sudo cp opencode-healthcheck.service   /etc/systemd/system/
sudo cp opencode-healthcheck.timer     /etc/systemd/system/

# 2b. Alerting config (optional -- leave the webhook empty to disable alerts)
sudo cp opencode-alert.conf.example    /etc/opencode-healthcheck.conf
sudo chmod 600                         /etc/opencode-healthcheck.conf
# then edit it and replace CHANGE_ME with your real webhook key

# 3. Review, then enable
sudo systemd-analyze verify /etc/systemd/system/opencode.service
sudo systemctl daemon-reload
sudo systemctl enable --now opencode.service
sudo systemctl enable --now opencode-healthcheck.timer
```

### Set the server password

`opencode serve` refuses to run without `OPENCODE_SERVER_PASSWORD`. This repo
ships a `CHANGE_ME` placeholder on purpose -- do **not** commit a real password.
Set it with a drop-in (kept outside this repo):

```bash
sudo mkdir -p /etc/systemd/system/opencode.service.d
sudo tee /etc/systemd/system/opencode.service.d/password.conf >/dev/null <<'EOF'
[Service]
Environment=OPENCODE_SERVER_PASSWORD=your-real-password
EOF
sudo chmod 600 /etc/systemd/system/opencode.service.d/password.conf
sudo systemctl daemon-reload
```

## Notes on the directives

- `CPUQuota=400%` = 4 of 8 cores. `opencode serve` is one event loop but fans
  out to LSP / codegraph / agent children; too small a quota starves the loop
  and stretches synchronous SQLite work from seconds into minutes.
- `Restart=always` + `RestartSec=5` handles crashes and OOM kills.
- `TimeoutStopSec=60` shortens the 90s default wait when a hung process is being
  stopped; `SendSIGKILL=yes` guarantees the kill lands.
- `LimitNOFILE=65536` matters with hundreds of concurrent streams and LSP child
  processes; the 4096 default is easy to exhaust.
- `ProtectSystem` / `ProtectHome` / `ReadWritePaths` are **commented out**:
  systemd 219 ignores them and logs a parse warning. Enable only on systemd >= 232.
- `CPUQuota` and `Restart` take effect on `daemon-reload` for a *running* unit;
  `LimitNOFILE` and `TimeoutStopSec` need a service restart to apply.

## Caveats

- This service does not fix the underlying cause of a hang -- it only recovers
  from one. The usual culprit is synchronous work (SQLite) on the single event
  loop of a very large `opencode.db`. Keep an eye on `opencode.db` growth.
- The probe restarts the service, which will interrupt any in-flight sessions.
  Three consecutive misses is a deliberate trade-off to avoid flapping.
- Paths (`/home/opencode`, JDK, Maven) are from one specific machine.

## Verify

```bash
# quota is applied (400% -> 400000)
cat /sys/fs/cgroup/cpu,cpuacct/system.slice/opencode.service/cpu.cfs_quota_us

# liveness: 401 == alive & awaiting auth
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4096/

# simulate a hang; expect an automatic restart within ~3 minutes
sudo kill -STOP "$(systemctl show -p MainPID --value opencode.service)"
journalctl -u opencode.service | tail   # look for the "no response 3x" log line
```

## Uninstall

```bash
sudo systemctl disable --now opencode-healthcheck.timer opencode.service
sudo rm /etc/systemd/system/opencode.service \
        /etc/systemd/system/opencode-healthcheck.{service,timer} \
        /usr/local/sbin/opencode-healthcheck.sh
sudo rm -rf /etc/systemd/system/opencode.service.d
sudo systemctl daemon-reload
```

## License

[MIT](../LICENSE)
