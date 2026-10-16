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
- `TimeoutStopSec=20` shortens the 90s default wait when a hung process is being
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
