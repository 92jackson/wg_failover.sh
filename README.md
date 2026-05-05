# wg_failover.sh

**WireGuard Tunnel Failover and Auto-Rotation for OpenWrt**

Monitors your WireGuard VPN connection and automatically switches to another server if the current one stops responding (active peer becomes unresponsive). You can also set it to auto-swap on a schedule (every X hours and/or at a specific time of day), regardless of tunnel health.

Compatible with both policy-based routing and global VPN modes on OpenWrt routers, with special (optional) handling for GL.iNet OpenWrt routers.

---

## How It Works

The script monitors the WireGuard `latest handshake` timestamp to detect a failed server. When it becomes stale, two optional checks run before switching:

1. **WAN check** — confirms the ISP connection is up.
2. **Tunnel ping** — confirms the peer can route traffic. If it succeeds, no switch occurs.

After switching, another tunnel ping verifies connectivity. If it fails, the script immediately tries the next server until a connection is established (or limits are reached).

Failed servers enter a cooldown period to prevent rapid reuse. Tunnels are monitored independently, and a `lockfile` prevents overlapping cron runs during long failover sequences.

---

## Features

- **Automatic failover** — Detects stale handshakes and switches servers automatically
- **Scheduled rotation** — Rotate servers after a set interval or at a specific time of day
- **Multi-tunnel support** — Independent monitoring and server pools per tunnel
- **WAN safeguards** — Prevents failover during ISP outages
- **Post-switch verification** — Confirms traffic routing with primary and fallback ping targets
- **Per-peer cooldown** — Avoids rapid reuse of recently failed servers
- **Switch history** — Persistent per-tunnel log with configurable retention
- **Optional peer benchmarking** — Optional current-peer throughput benchmarking per tunnel (download speed)
- **Webhook notifications** — Alerts for failover, rotation, and WAN state changes
- **GL.iNet dashboard sync** — Optional API integration to keep the router UI in sync after peer switches

---

## Compatibility

- GL.iNet firmware 4.x (policy-based routing and global VPN modes)
- Any OpenWrt device using UCI WireGuard peer configuration with `ubus` network control

> ⚠️ On GL.iNet routers the web dashboard may show incorrect server info after an automated switch unless the optional GL.iNet API integration is enabled. See [Peer Switching Methods](#peer-switching-methods) and [Limitations](#limitations).

> _Tested so far on GL.iNet Flint 2 (stock firmware)._

---

## Installation

### Step 1 — Download the script

```bash
wget -O /usr/bin/wg_failover.sh https://raw.githubusercontent.com/92jackson/wg_failover.sh/refs/heads/main/wg_failover.sh
chmod +x /usr/bin/wg_failover.sh
```

### Step 2 — Run discovery commands

Run the following commands on your router and note the output. You'll need these values for configuration.

#### A) Identify WireGuard tunnel interfaces

```bash
uci show network | grep '\.config='
```

Example output:

```
network.wgclient1.config='peer_2001'
network.wgclient2.config='peer_2006'
```

The interface names (`wgclient1`, `wgclient2`) are used for `TUNNEL_X_IFACE` and `TUNNEL_X_WG_IF`.

#### B) List available VPN servers

```bash
uci show wireguard | grep '\.name='
```

Example output:

```
wireguard.peer_100.name='Provider-SetA-Server1'
wireguard.peer_101.name='Provider-SetA-Server2'
wireguard.peer_102.name='Provider-SetA-Server3'
wireguard.peer_103.name='Provider-SetB-Server1'
wireguard.peer_104.name='Provider-SetB-Server2'
```

Choose a keyword (substring) that appears in all servers belonging to a tunnel pool (e.g. `SetA`, `SetB`). Each tunnel requires **at least two matching servers**. These become `TUNNEL_X_KEYWORD`.

#### C) Find routing tables per tunnel

```bash
uci show network | grep ip4table
```

Example:

```
network.wgclient1.ip4table='1001'
network.wgclient2.ip4table='1002'
```

Use these values for `TUNNEL_X_ROUTE_TABLE`.

### Step 3 — Configure the script

Edit the script with your gathered values:

```bash
vi /usr/bin/wg_failover.sh
```

**Minimum required configuration** (fill in values from Step 2):

```bash
# Tunnel 1
TUNNEL_COUNT=1

TUNNEL_1_IFACE='wgclient1'           # From Step 2A
TUNNEL_1_WG_IF='wgclient1'           # From Step 2A
TUNNEL_1_LABEL='Primary'             # Friendly name (free text)
TUNNEL_1_KEYWORD='SetA'              # From Step 2B
TUNNEL_1_ROUTE_TABLE='1001'          # From Step 2C
TUNNEL_1_FAILOVER_ENABLED=1          # Monitor for failovers (0=disabled)
```

See [Configuration Reference](#configuration-reference) for all available options including multiple tunnels, rotation schedules, and GL.iNet API integration.

### Step 4 — Activate via cron

```bash
echo "* * * * * /usr/bin/wg_failover.sh" >> /etc/crontabs/root
/etc/init.d/cron restart
```

> **Note:** The script runs every minute via cron. The `CHECK_INTERVAL` setting (default 60s) throttles actual checks so overlapping invocations exit early rather than stacking up. See [Settings Reference](#settings-reference) for tuning.

### Step 5 — Verify it's working

```bash
# Wait a minute, then check the log
tail -20 /var/log/wg_failover.log

# Or check tunnel status directly
/usr/bin/wg_failover.sh status
```

---

## Peer Switching Methods

The script supports two methods for switching WireGuard peers, controlled by `GLINET_SWITCH_METHOD`.

### Method 1 — UCI/ubus (works on all OpenWrt routers)

```bash
GLINET_SWITCH_METHOD='uci'
```

Uses standard OpenWrt tools (`uci` and `ubus`) to update the active peer and bounce the tunnel interface. Works on any OpenWrt router and requires no credentials.

**Drawback on GL.iNet routers:** The GL.iNet web dashboard is not informed of the peer change and will continue to display the last server selected through the GUI. On reboot, the router will reconnect to whichever peer was last chosen in the dashboard, not the one the script had switched to.

If dashboard accuracy and reboot persistence don't matter to you, this is the right choice — it's faster and keeps credentials out of the script.

### Method 2 — GL.iNet Dashboard API (GL.iNet routers only)

```bash
GLINET_SWITCH_METHOD='auto'            # auto=API first, fall back to UCI | api=API only | uci=skip API
GLINET_ROUTER='http://192.168.8.1/rpc' # Router JSON-RPC endpoint
GLINET_USER='root'                     # Router admin username
GLINET_PASS='yourpassword'             # Router admin password
```

Performs the switch through the GL.iNet JSON-RPC API so the router dashboard and reboots stay in sync.

**Drawbacks:**

- Requires storing your router admin password in the script — use `chmod 700 /usr/bin/wg_failover.sh` to restrict read access.
- Slower than UCI switching — the API path performs a challenge, login, tunnel lookup, switch, and logout sequence.
- Only works on GL.iNet firmware 4.x. Setting `api` or `auto` on a non-GL.iNet router will fail and — if using `auto` — fall back to UCI.

> **Recommendation:** The script's default configuration is `GLINET_SWITCH_METHOD='auto'`, which attempts the GL.iNet API first and falls back to UCI if the API is unavailable or credentials are missing. If you don't need dashboard sync, set `uci` explicitly for the simplest and fastest behaviour.

The switch method can also be overridden at runtime without editing the script:

```bash
/usr/bin/wg_failover.sh --switch-method uci
/usr/bin/wg_failover.sh --switch-method api
/usr/bin/wg_failover.sh --switch-method auto
```

---

## Scheduled Rotation

Each tunnel can rotate to the next server on a schedule, independent of whether the current server is healthy. Both conditions can be set simultaneously — whichever triggers first wins.

```bash
TUNNEL_1_ROTATE=''                # Disabled
```

`TUNNEL_X_ROTATE` accepts a comma-separated schedule:

- `21600` = rotate every 21600 seconds (6 hours)
- `03:00` = rotate daily at 03:00
- `21600,03:00` = either trigger may rotate first

**Examples:**

```bash
# Rotate every 6 hours
TUNNEL_1_ROTATE='21600'

# Rotate at 3am daily
TUNNEL_1_ROTATE='03:00'

# Both — whichever triggers first
TUNNEL_1_ROTATE='21600,03:00'
```

A successful scheduled rotation sends a `rotated_scheduled` webhook notification and is marked `[rotation]` in the log. A manual `--force-rotate` sends `rotated_manual` on success.

---

## Keyword Behaviour

The `TUNNEL_X_KEYWORD` determines which servers belong to a tunnel's pool:

- **Keyword set (e.g. `SetA`):** The tunnel can only use servers whose names contain that substring. Servers matching `SetA` are exclusive to that tunnel.
- **Keyword empty (`''`):** The tunnel uses all servers _not claimed_ by other tunnels with keywords. Useful for a single global VPN or a catch-all secondary tunnel. Only one tunnel may use an empty keyword. If multiple tunnels have empty keywords, only the first is used and the rest are skipped with an error.

**Example:** Tunnel 1 has keyword `SetA`, Tunnel 2 has keyword `SetB`, Tunnel 3 has empty keyword. Tunnel 1 gets all `SetA` servers, Tunnel 2 gets all `SetB` servers, Tunnel 3 gets everything else.

---

## Usage

The script is called automatically by cron every minute. No manual intervention is needed during normal operation.

### Subcommands

| Subcommand             | Description                                                                                        |
| ---------------------- | -------------------------------------------------------------------------------------------------- |
| `status`               | Print tunnel status, handshake health, peer pool, cooldowns, rotation state, and a live ping test. |
| `status --json`        | Same output as machine-readable JSON, suitable for scripting.                                      |
| `status --webhook`     | Send the current consolidated status snapshot to the configured webhook endpoint and exit.         |
| `benchmarks`           | Print benchmark history summaries, including per-peer performance within each tunnel.              |
| `benchmarks --json`    | Same benchmark summary as machine-readable JSON.                                                   |
| `benchmarks --webhook` | Send the current benchmark summary to the configured webhook endpoint and exit.                    |
| `reset`                | Clear all cooldowns, rotation timestamps, and the run timer.                                       |
| `reset --keep-history` | Reset state but preserve switch history files.                                                     |

### Flags

All flags are composable and may appear in any order. Tunnel targeting accepts either a label or `--iface <iface>` in place of a label.

| Flag                       | Description                                                                                                 |
| -------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `--dry-run`                | Run full logic but make no changes. Output goes to stdout, not the log.                                     |
| `--fail <label>`           | Treat the named tunnel as failed, triggering an immediate switch.                                           |
| `--fail-wan`               | Simulate a WAN outage — failover is suppressed on all tunnels this run.                                     |
| `--force-rotate [label]`   | Immediately rotate to the next peer without simulating a failure. Omit label to rotate all.                 |
| `--benchmark [label]`      | Run a throughput benchmark on the current active peer. Omit label to benchmark all enabled tunnels.         |
| `--exercise [label]`       | Run a full forward/return switch test. Reverts automatically. **Suppresses webhooks and log writes.**       |
| `--revert`                 | After a successful switch, switch back to the original peer.                                                |
| `--ignore-cooldown`        | Skip cooldown checks when selecting the next peer.                                                          |
| `--switch-method <method>` | Override `GLINET_SWITCH_METHOD` for this run. Values: `auto` \| `api` \| `uci`.                             |
| `--iface <iface>`          | Sub-qualifier for `--fail`, `--exercise`, and `--force-rotate` — target by interface name instead of label. |
| `--debug`                  | Force verbose logging and send webhooks regardless of mode.                                                 |
| `--version`                | Print version and exit.                                                                                     |
| `--check-update`           | Check for updates and exit.                                                                                 |

The `<label>` argument must match `TUNNEL_X_LABEL` exactly, including capitalisation.

### Examples

```bash
# Check tunnel status
/usr/bin/wg_failover.sh status
/usr/bin/wg_failover.sh status --json

# Push a one-shot status snapshot to the configured webhook
/usr/bin/wg_failover.sh status --webhook

# Trace failover logic without making any changes
/usr/bin/wg_failover.sh --dry-run

# Trigger an immediate failover on a specific tunnel
/usr/bin/wg_failover.sh --fail "Primary"

# Force a rotation without simulating a failure
/usr/bin/wg_failover.sh --force-rotate "Primary"
/usr/bin/wg_failover.sh --force-rotate --iface wgclient1

# Run current-peer benchmarks
/usr/bin/wg_failover.sh --benchmark
/usr/bin/wg_failover.sh --benchmark "Primary"
/usr/bin/wg_failover.sh --benchmark --iface wgclient1

# Print benchmark summaries
/usr/bin/wg_failover.sh benchmarks
/usr/bin/wg_failover.sh benchmarks --json
/usr/bin/wg_failover.sh benchmarks --webhook

# Simulate a WAN outage (failover suppressed on all tunnels)
/usr/bin/wg_failover.sh --fail-wan

# Run a full end-to-end exercise test (switches and auto-reverts)
/usr/bin/wg_failover.sh --exercise
/usr/bin/wg_failover.sh --exercise "Primary"

# Switch using UCI only, regardless of configured method
/usr/bin/wg_failover.sh --switch-method uci --force-rotate

# Clear all state
/usr/bin/wg_failover.sh reset
/usr/bin/wg_failover.sh reset --keep-history
```

---

## Settings Reference

### Tunnel Definitions

| Variable                    | Description                                                                                              |
| --------------------------- | -------------------------------------------------------------------------------------------------------- |
| `TUNNEL_COUNT`              | Total number of tunnels defined below                                                                    |
| `TUNNEL_X_IFACE`            | OpenWrt network interface name (e.g. `wgclient1`)                                                        |
| `TUNNEL_X_WG_IF`            | WireGuard kernel interface name (usually same as `TUNNEL_X_IFACE`)                                       |
| `TUNNEL_X_LABEL`            | Friendly name used in logs, webhooks, and flag targeting                                                 |
| `TUNNEL_X_KEYWORD`          | Substring to match server names · blank = all unclaimed servers                                          |
| `TUNNEL_X_ROUTE_TABLE`      | Routing table number for ping verification · blank = interface-bound fallback                            |
| `TUNNEL_X_FAILOVER_ENABLED` | `1` = monitor for failover · `0` = skip this tunnel for failover                                         |
| `TUNNEL_X_ROTATE`           | CSV rotation schedule. e.g. '21600' (secs), '03:00' (daily), '21600,03:00' (either) · `''` = no rotation |
| `TUNNEL_X_BENCHMARK_URL`    | Optional benchmark test-file URL override for this tunnel · blank = use `BENCHMARK_URL`                  |

### WAN Safety Guard

| Variable                  | Description                                                                                          | Default           |
| ------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------- |
| `WAN_IFACE`               | WAN interface override for ping checks · `''` = auto-detect via ubus                                 | `''`              |
| `WAN_PING_TARGETS`        | IPs to ping to confirm internet access · `''` = skip ping check                                      | `1.1.1.1 8.8.8.8` |
| `WAN_STABILITY_THRESHOLD` | Min WAN uptime + confirmed internet access ping in seconds before acting on tunnel state · `0` = off | `120`             |

### Privacy Settings

| Variable                   | Description                                                        | Default |
| -------------------------- | ------------------------------------------------------------------ | ------- |
| `PRIVACY_ROUTE_VIA_TUNNEL` | Route non-local outbound traffic via tunnels · `0` = off, `1` = on | `0`     |

`PRIVACY_ROUTE_VIA_TUNNEL` prevents IP leakage by routing non-local outbound traffic via tunnels. This includes update webhooks, WAN reachability, and update checks (benchmarking, and tunnel PING testing is already directed over tunnels).

If using this setting and you only have a single tunnel defined, WAN ping checks are bypassed as the script will not be able to distinguish WAN outage from tunnel failure. In that case, WAN stability relies on WAN interface uptime only.

Only use this setting if you are running a privacy-conscious setup.

### GL.iNet Dashboard API

| Variable               | Description                                                          | Default                  |
| ---------------------- | -------------------------------------------------------------------- | ------------------------ |
| `GLINET_SWITCH_METHOD` | `uci` = UCI only · `api` = API only · `auto` = API with UCI fallback | `auto`                   |
| `GLINET_ROUTER`        | Router JSON-RPC endpoint                                             | `http://192.168.8.1/rpc` |
| `GLINET_USER`          | Router admin username                                                | `root`                   |
| `GLINET_PASS`          | Router admin password                                                | `''`                     |

### Failover Tuning

| Variable                        | Description                                                                                                | Default |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------- | ------- |
| `HANDSHAKE_TIMEOUT`             | Seconds before a handshake is considered stale                                                             | `180`   |
| `PRE_FAILOVER_PING`             | Ping the current peer before failing over — skips switch if traffic is still flowing (`1` = yes, `0` = no) | `1`     |
| `POST_SWITCH_HANDSHAKE_TIMEOUT` | Seconds to poll for a handshake after switching                                                            | `45`    |
| `POST_SWITCH_DELAY`             | Seconds to wait before pinging if handshake poll times out                                                 | `20`    |
| `PEER_COOLDOWN`                 | Seconds before a failed server can be retried                                                              | `600`   |
| `MAX_FAILOVER_ATTEMPTS`         | Max peers to try per cycle · `0` = try all                                                                 | `0`     |
| `HANDSHAKE_POLL_INTERVAL`       | Seconds between handshake polls after switching                                                            | `3`     |

### Ping Verification

| Variable       | Description                                                      | Default           |
| -------------- | ---------------------------------------------------------------- | ----------------- |
| `PING_VERIFY`  | Enable ping verification after switching (`1` = yes)             | `1`               |
| `PING_TARGETS` | Space-separated IPs to ping through tunnel. First success = pass | `1.1.1.1 8.8.8.8` |
| `PING_COUNT`   | Packets per ping test                                            | `3`               |
| `PING_TIMEOUT` | Seconds per ping reply                                           | `5`               |

### Logging

| Variable            | Description                                              | Default                    |
| ------------------- | -------------------------------------------------------- | -------------------------- |
| `LOG_FILE`          | Log file path · `''` = disable                           | `/var/log/wg_failover.log` |
| `LOG_MAX_SIZE`      | Max log size in bytes before rotation                    | `102400`                   |
| `LOG_MAX_LINES`     | Lines kept after log rotation                            | `500`                      |
| `LOG_LEVEL`         | `0` silent · `1` changes only · `2` normal · `3` verbose | `2`                        |
| `HISTORY_MAX_LINES` | Max switch history entries per tunnel · `0` = unlimited  | `500`                      |
| `STATE_DIR`         | Directory for runtime state files and lockfile           | `/tmp/wg_failover`         |

### Benchmarking

| Variable                      | Description                                                                             | Default                                   |
| ----------------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------- |
| `BENCHMARK_URL`               | Default public test-file URL used for throughput benchmarking                           | `https://ash-speed.hetzner.com/100MB.bin` |
| `BENCHMARK_TIMEOUT`           | Max seconds per benchmark request                                                       | `30`                                      |
| `BENCHMARK_HISTORY_MAX_LINES` | Max benchmark history entries per tunnel                                                | `200`                                     |
| `BENCHMARK_INTERVAL`          | CSV schedule for periodic current-peer benchmarks. e.g. `21600`, `03:00`, `21600,03:00` | `''`                                      |
| `BENCHMARK_INTERVAL_WEBHOOK`  | `1` = send a benchmark webhook after a scheduled benchmark run, `0` = do not            | `0`                                       |

### Webhook Notifications

| Variable                  | Description                                                                                       | Default |
| ------------------------- | ------------------------------------------------------------------------------------------------- | ------- |
| `WEBHOOK_URL`             | Notification endpoint · `''` = disable                                                            | `''`    |
| `WEBHOOK_PROCESSOR`       | GET = `''` · POST: `'text'` (plain text), `'json'`, `'ntfy'`, `'gotify'`                          | `''`    |
| `WEBHOOK_REPEAT_INTERVAL` | Minimum seconds before the same event fires again on the same tunnel                              | `300`   |
| `STATUS_WEBHOOK_INTERVAL` | CSV schedule for periodic status webhooks. e.g. '21600' (sec), '06:00,18:00', '21600,06:00,18:00' | ''      |

---

## Webhook Notifications

Set `WEBHOOK_URL` to receive a notification on failover, rotation, or WAN state changes.

### Methods

#### GET (default, `''`)

Parameters are appended as query strings. Fields vary by event type:

```
# Standard events (switched_failover, rotated_scheduled, rotated_manual,
# failover_ping_failed, rotation_ping_failed)
{WEBHOOK_URL}?tunnel=Streaming&from=UK-01&to=Albania-58&status=switched_failover

# All peers exhausted (no destination peer)
{WEBHOOK_URL}?tunnel=Streaming&from=UK-01&status=all_failed

# WAN events (not tunnel-specific)
{WEBHOOK_URL}?status=wan_down
{WEBHOOK_URL}?status=wan_up
```

#### Plain Text (`'text'`)

POSTs a human-readable string:

```
Streaming - failover from UK-01 to Albania-58
WAN offline
```

```bash
WEBHOOK_URL='https://yourserver.com/webhook'
WEBHOOK_PROCESSOR='text'
```

#### JSON (`'json'`)

POSTs a JSON body. Fields vary by event type:

```json
// Standard events (switched_failover, rotated_scheduled, rotated_manual,
// failover_ping_failed, rotation_ping_failed)
{ "tunnel": "Streaming", "from": "UK-01", "to": "Albania-58", "status": "switched_failover" }

// All peers exhausted (no destination peer)
{ "tunnel": "Streaming", "from": "UK-01", "status": "all_failed" }

// WAN events (not tunnel-specific)
{ "status": "wan_down" }
{ "status": "wan_up" }
```

```bash
WEBHOOK_URL='https://yourserver.com/webhook'
WEBHOOK_PROCESSOR='json'
```

#### ntfy (`'ntfy'`)

POSTs to an [ntfy](https://ntfy.sh) topic with title, priority and tags derived from the event type.

```bash
WEBHOOK_URL='https://ntfy.sh/your-topic-name'
WEBHOOK_PROCESSOR='ntfy'
```

#### Gotify (`'gotify'`)

POSTs a JSON body with `title`, `message`, and `priority` mapped per event type. Include your app token in the URL.

```bash
WEBHOOK_URL='https://your-gotify-server/message?token=YOUR_APP_TOKEN'
WEBHOOK_PROCESSOR='gotify'
```

---

### Status Values

| Status                  | Meaning                                                                 |
| ----------------------- | ----------------------------------------------------------------------- |
| `switched_failover`     | Failover successful — new peer verified                                 |
| `switched_revert`       | Reverted to original peer after --revert                                |
| `rotated_scheduled`     | Scheduled rotation successful — new peer verified                       |
| `rotated_manual`        | Manual force-rotate successful — new peer verified                      |
| `failover_ping_failed`  | A candidate peer failed ping verification during failover — trying next |
| `rotation_ping_failed`  | Rotation target failed ping verification — staying on current peer      |
| `all_failed`            | All peers exhausted or in cooldown — cannot failover                    |
| `wan_down`              | WAN outage detected; failover suppressed while WAN is down              |
| `wan_up`                | WAN restored after a `wan_down` event                                   |
| `tunnel_down`           | Tunnel interface is not up, monitoring skipped this cycle               |
| `single_peer`           | Only one peer in pool, failover not possible                            |
| `rotation_all_cooldown` | All peers in cooldown, scheduled rotation skipped                       |
| `all_failed_wan_lost`   | WAN lost mid-failover, peer cycle aborted — no working peer guaranteed  |
| `ping_failed`           | Manual `--force-rotate` target failed ping verification                 |

---

## Logs

Default location: `/var/log/wg_failover.log`

> **OpenWrt note:** `/var/log/` is stored in RAM and cleared on every reboot. This is normal behaviour.

### Log Levels

| Level | What is logged                                                            |
| ----- | ------------------------------------------------------------------------- |
| `0`   | Nothing                                                                   |
| `1`   | Failovers, rotations, and errors only (recommended for production)        |
| `2`   | Also includes successful health checks (recommended during initial setup) |
| `3`   | Every check including handshake ages and peer pool details                |

Each switch is tagged with its reason — `[failover]`, `[rotation]`, `[exercise]`, or `[revert]` — so you can distinguish scheduled rotations from emergency failovers at a glance.

```bash
tail -50 /var/log/wg_failover.log
tail -f /var/log/wg_failover.log
```

---

## Troubleshooting

### Script doesn't run

Check cron is running and the entry exists:

```bash
/etc/init.d/cron status
crontab -l
```

Check for a stuck lockfile (means a previous run is still active or crashed):

```bash
cat /tmp/wg_failover/wg_failover.lock
```

If the PID in the lockfile no longer exists, the script will clean it up automatically on the next run. You can also force-clear all state with:

```bash
/usr/bin/wg_failover.sh reset
```

### No servers found for a tunnel

Keywords are case-sensitive. Verify your keyword matches actual server names:

```bash
uci show wireguard | grep '\.name='
```

### Ping verification always fails

Test the two ping methods manually (replace `1001` and `wgclient1` with your values):

```bash
# Routing table method
ip route exec table 1001 ping -c 3 1.1.1.1

# Interface-bound fallback
ping -c 3 -I wgclient1 1.1.1.1
```

If only the interface-bound method works, set `TUNNEL_X_ROUTE_TABLE=''` in the script.

### False positive failovers

Increase `HANDSHAKE_TIMEOUT` to `240` or `300`. WireGuard re-handshakes roughly every 3 minutes but this can occasionally stretch longer on congested connections.

### GL.iNet API switch fails

Check that `GLINET_ROUTER` points to the correct IP and port for your router's JSON-RPC endpoint (`{ROUTER_IP}/rpc`). Verify the credentials are correct by logging into the dashboard manually. If the API is intermittently unreachable, switch to `GLINET_SWITCH_METHOD='auto'` so failed API calls fall back to UCI automatically. If you don't need dashboard sync at all, use `GLINET_SWITCH_METHOD='uci'`.

---

## Uninstallation

To completely remove the script and its state:

```bash
# Remove cron entry
sed -i '/wg_failover.sh/d' /etc/crontabs/root
/etc/init.d/cron restart

# Remove the script
rm /usr/bin/wg_failover.sh

# Remove state files and logs
rm -rf /tmp/wg_failover
rm -f /var/log/wg_failover.log
```

---

## Limitations

### Out-of-sync GL.iNet dashboard (UCI mode)

When using UCI switching (`GLINET_SWITCH_METHOD='uci'`), peer changes happen outside of the GL.iNet VPN Client application and the dashboard is not notified.

| Component                       | Reported VPN server                       |
| ------------------------------- | ----------------------------------------- |
| Failover script (`status`)      | ✅ Correct (actual active peer)           |
| WireGuard CLI / traffic routing | ✅ Correct                                |
| GL.iNet Web Dashboard           | ❌ Shows last GUI-selected server         |
| Router reboot behaviour         | ❌ Reconnects to last GUI-selected server |

Traffic routing, kill-switch behaviour, DNS, and connectivity all use the new active peer — only the dashboard display and reboot persistence are affected.

To verify the real connection at any time:

```bash
/usr/bin/wg_failover.sh status
```

Set `GLINET_SWITCH_METHOD='api'` or `'auto'` to keep the dashboard in sync, keeping in mind the [drawbacks noted above](#method-2--glinet-dashboard-api-glinet-routers-only).

---

## License

MIT License — feel free to modify and distribute.

## Contributing

Issues and pull requests are welcome.

---

## Support

Discord server: [Discord](https://discord.gg/e3eXGTJbjx).

If this script has been useful to you, a coffee is always appreciated — thank you!

[![Buy Me A Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://buymeacoffee.com/92jackson)
