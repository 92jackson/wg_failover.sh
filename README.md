# wg_failover.sh

**WireGuard VPN Tunnel Failover and Auto-Rotate for GL.iNet Routers (OpenWrt)**

Automatically monitors one or more WireGuard tunnels and switches to the next available server when the current one becomes unresponsive. Supports scheduled server rotation independent of tunnel health.

---

## How It Works

WireGuard's "last handshake" timestamp is used to detect a down server — when it goes stale beyond a configurable threshold, the script rotates to the next server in the pool. Before acting, a WAN pre-flight check runs to ensure the issue isn't a local ISP outage. After switching, a ping through the tunnel interface confirms traffic is flowing; if it fails, the next server is tried immediately without waiting for the next cron cycle.

Failed servers enter a cooldown period to prevent immediately cycling back to them. Each tunnel is monitored independently, and a lockfile prevents overlapping cron runs during longer failover sequences.

---

## Features

- **Automatic failover** — Detects stale WireGuard handshakes and switches servers without manual intervention
- **WAN pre-flight checks** — Suppresses failover during ISP outages so the server pool isn't exhausted unnecessarily
- **Scheduled rotation** — Rotate to the next server after X hours or at a set time of day, regardless of tunnel health
- **Ping verification** — Confirms the new server is actually routing traffic after switching, with a primary and fallback target
- **Per-peer cooldown** — Prevents cycling back to recently failed servers
- **Switch history** — Persistent per-tunnel log of recent switches with configurable retention
- **Independent multi-tunnel support** — Monitor multiple WireGuard tunnels, each with their own server pool
- **Webhook notifications** — Alerts on failover, rotation, and WAN up/down events
- **Flexible flag interface** — Dry-run, simulated failure, WAN simulation, force-rotate, exercise testing, cooldown bypass, and more

---

## Compatibility

- GL.iNet firmware 4.x (split-tunnel / VPN policy / dashboard mode)
- GL.iNet firmware 4.x (global VPN mode — single tunnel, no policies)
- Any OpenWrt device using UCI WireGuard peer configuration + ubus network control

> ⚠️ The GL.iNet web dashboard will likely show incorrect server info after an automated switch. Traffic routing is unaffected. See [Limitations](#limitations).

---

## Prerequisites

- SSH access enabled
- At least 2 VPN server profiles configured per tunnel

---

## Installation

The script must be configured before being activated. Do not add it to cron until you have edited it with your tunnel details.

**Step 1 — Download the script:**

```bash
wget -O /usr/bin/wg_failover.sh https://raw.githubusercontent.com/92jackson/wg_failover.sh/refs/heads/main/wg_failover.sh
chmod +x /usr/bin/wg_failover.sh
```

**Step 2 — Configure the script** (see [Configuration](#configuration) below).

**Step 3 — Activate via cron:**

```bash
echo "* * * * * /usr/bin/wg_failover.sh" >> /etc/crontabs/root
/etc/init.d/cron restart
```

**Step 4 — Verify it is running:**

```bash
# Wait a minute, then check the log
tail -20 /var/log/wg_failover.log

# Or check tunnel status directly
/usr/bin/wg_failover.sh status
```

---

## Configuration

All configuration is at the top of the script:

```bash
vi /usr/bin/wg_failover.sh
```

### Discovering Your Values

Run these commands on your router to find the correct values before editing.

```bash
# 1. Find your WAN interface
ip route show default | awk '{print $5}'
```

The output is your `WAN_IFACE` value.

---

```bash
# 2. List your WireGuard tunnel interfaces and their currently active peer
uci show network | grep 'wgclient.*\.config='
```

```
network.wgclient1.config='peer_2001'
network.wgclient2.config='peer_2006'
```

The interface names (`wgclient1`, `wgclient2`) are your `TUNNEL_X_IFACE` and `TUNNEL_X_WG_IF` values.

---

```bash
# 3. List all available VPN servers
uci show wireguard | grep '\.name='
```

```
wireguard.peer_100.name='Provider-SetA-Server1'
wireguard.peer_101.name='Provider-SetA-Server2'
wireguard.peer_102.name='Provider-SetA-Server3'
wireguard.peer_103.name='Provider-SetB-Server1'
wireguard.peer_104.name='Provider-SetB-Server2'
```

Choose a keyword substring present in all server names for each tunnel's pool — `SetA`, `SetB`, etc. You need at least 2 matching servers per tunnel. These become your `TUNNEL_X_KEYWORD` values.

---

```bash
# 4. Find the routing table assigned to each tunnel
uci show network | grep ip4table
```

```
network.wgclient1.ip4table='1001'
network.wgclient2.ip4table='1002'
```

The table numbers are your `TUNNEL_X_ROUTE_TABLE` values.

---

### Configuring Your Tunnels

With the values found above, fill in the tunnel definitions:

```bash
TUNNEL_COUNT=2

# Tunnel 1: Primary VPN — all Set A servers, no rotation
TUNNEL_1_IFACE='wgclient1'
TUNNEL_1_WG_IF='wgclient1'
TUNNEL_1_LABEL='Primary (Set A)'
TUNNEL_1_KEYWORD='SetA'
TUNNEL_1_ROUTE_TABLE='1001'
TUNNEL_1_ENABLED=1
TUNNEL_1_ROTATE_INTERVAL=0
TUNNEL_1_ROTATE_AT=''

# Tunnel 2: Secondary VPN — all Set B servers, rotates every 6h and at 3am
TUNNEL_2_IFACE='wgclient2'
TUNNEL_2_WG_IF='wgclient2'
TUNNEL_2_LABEL='Secondary (Set B)'
TUNNEL_2_KEYWORD='SetB'
TUNNEL_2_ROUTE_TABLE='1002'
TUNNEL_2_ENABLED=1
TUNNEL_2_ROTATE_INTERVAL=6
TUNNEL_2_ROTATE_AT='03:00'
```

---

### Scheduled Rotation

Each tunnel can rotate to the next server on a schedule, independent of whether the current server is healthy. Both conditions can be set simultaneously — whichever triggers first wins.

| Variable                   | Description                                                      |
| -------------------------- | ---------------------------------------------------------------- |
| `TUNNEL_X_ROTATE_INTERVAL` | Hours between forced rotations. `0` = disabled.                  |
| `TUNNEL_X_ROTATE_AT`       | Time-of-day rotation in `HH:MM` 24-hour format. `''` = disabled. |

Rotation always verifies the new server with a ping test. If the rotated-to server fails, it is placed in cooldown and the rotation timestamp is still recorded to avoid hammering a bad server every minute. A successful rotation sends a `rotated` webhook notification and is marked `[rotation]` in the log.

---

### Blank Keyword — Global VPN Mode / Catch-All Pool

Setting `TUNNEL_X_KEYWORD=''` tells the script to build that tunnel's pool from all servers not claimed by another tunnel's keyword.

**Single global VPN — one tunnel, all servers:**

```bash
TUNNEL_COUNT=1

TUNNEL_1_IFACE='wgclient1'
TUNNEL_1_WG_IF='wgclient1'
TUNNEL_1_LABEL='Global VPN'
TUNNEL_1_KEYWORD=''         # Blank = use ALL configured servers as the pool
TUNNEL_1_ROUTE_TABLE='1001'
TUNNEL_1_ENABLED=1
TUNNEL_1_ROTATE_INTERVAL=0
TUNNEL_1_ROTATE_AT=''
```

**Mixed — keyword tunnel plus a catch-all:**

```bash
TUNNEL_COUNT=2

TUNNEL_1_KEYWORD='SetA'  # Claims all servers whose name contains 'SetA'
TUNNEL_2_KEYWORD=''      # Gets everything not claimed by any other tunnel
```

> Only one tunnel may have a blank keyword. If more than one is blank, only the first will be used and the others will be skipped with an error logged.

---

### Global Settings Reference

| Variable                        | Description                                                    | Default                    |
| ------------------------------- | -------------------------------------------------------------- | -------------------------- |
| `CHECK_INTERVAL`                | Seconds between checks (cron throttle)                         | `60`                       |
| `HANDSHAKE_TIMEOUT`             | Seconds before a handshake is considered stale                 | `180`                      |
| `PEER_COOLDOWN`                 | Seconds before a failed server can be retried                  | `600`                      |
| `POST_SWITCH_HANDSHAKE_TIMEOUT` | Seconds to poll for a handshake after switching                | `45`                       |
| `POST_SWITCH_DELAY`             | Seconds to wait before pinging if handshake poll times out     | `20`                       |
| `POST_SWITCH_GRACE`             | Seconds of monitoring pause after a successful switch          | `60`                       |
| `PING_VERIFY`                   | Enable ping verification after switching (`1` = yes, `0` = no) | `1`                        |
| `PING_TARGET`                   | Primary IP address to ping for verification                    | `1.1.1.1`                  |
| `PING_TARGET_FALLBACK`          | Secondary ping target used if the primary fails                | `8.8.8.8`                  |
| `PING_COUNT`                    | Number of ping packets to send                                 | `3`                        |
| `PING_TIMEOUT`                  | Seconds to wait per ping reply                                 | `5`                        |
| `WAN_IFACE`                     | WAN interface used for pre-flight connectivity checks          | `eth1`                     |
| `WAN_CHECK_TARGETS`             | Space-separated IPs used to verify WAN reachability            | `1.1.1.1 8.8.8.8`          |
| `WAN_WEBHOOK_INTERVAL`          | Minimum seconds between repeated `wan_down` webhook alerts     | `300`                      |
| `MAX_FAILOVER_ATTEMPTS`         | Max servers to try per cycle (`0` = unlimited)                 | `0`                        |
| `HISTORY_MAX_LINES`             | Max switch history entries per tunnel (`0` = unlimited)        | `500`                      |
| `LOG_FILE`                      | Log file path (set to `''` to disable)                         | `/var/log/wg_failover.log` |
| `LOG_MAX_SIZE`                  | Max log size in bytes before rotation                          | `102400`                   |
| `LOG_LEVEL`                     | `0` silent · `1` changes only · `2` normal · `3` verbose       | `2`                        |
| `WEBHOOK_URL`                   | Notification URL (set to `''` to disable)                      | `''`                       |
| `WEBHOOK_METHOD`                | `GET` or `POST`                                                | `GET`                      |
| `STATE_DIR`                     | Directory for state files and lockfile                         | `/tmp/wg_failover`         |

### Per-Tunnel Settings Reference

| Variable                   | Description                                                                   |
| -------------------------- | ----------------------------------------------------------------------------- |
| `TUNNEL_X_IFACE`           | OpenWrt network interface name (e.g. `wgclient1`)                             |
| `TUNNEL_X_WG_IF`           | WireGuard kernel interface name (usually same as IFACE)                       |
| `TUNNEL_X_LABEL`           | Friendly name used in logs, webhooks, and flag targeting                      |
| `TUNNEL_X_KEYWORD`         | Substring to match server names · blank = all unclaimed servers               |
| `TUNNEL_X_ROUTE_TABLE`     | Routing table number for ping verification · blank = interface-bound fallback |
| `TUNNEL_X_ENABLED`         | `1` = monitor · `0` = skip this tunnel                                        |
| `TUNNEL_X_ROTATE_INTERVAL` | Hours between forced rotations · `0` = disabled                               |
| `TUNNEL_X_ROTATE_AT`       | Time-of-day rotation as `HH:MM` · `''` = disabled                             |

---

## Usage

The script is called automatically by cron every minute. No manual intervention is needed during normal operation.

### Subcommands

| Subcommand             | Description                                                                                        |
| ---------------------- | -------------------------------------------------------------------------------------------------- |
| `status`               | Print tunnel status, handshake health, peer pool, cooldowns, rotation state, and a live ping test. |
| `status --json`        | Same output as machine-readable JSON, suitable for scripting.                                      |
| `reset`                | Clear all cooldowns, grace periods, rotation timestamps, and the run timer.                        |
| `reset --keep-history` | Reset state but preserve switch history files.                                                     |

### Flags

All flags are composable and may appear in any order. Tunnel targeting accepts either a label or `--iface <iface>` in place of a label.

| Flag                     | Description                                                                                                 |
| ------------------------ | ----------------------------------------------------------------------------------------------------------- |
| `--dry-run`              | Run full logic but make no changes. Output goes to stdout, not the log.                                     |
| `--fail <label>`         | Treat the named tunnel as failed, triggering an immediate switch.                                           |
| `--fail-wan`             | Simulate a WAN outage — failover is suppressed on all tunnels this run.                                     |
| `--force-rotate [label]` | Immediately rotate to the next peer without simulating a failure. Omit label to rotate all.                 |
| `--exercise [label]`     | Run a full forward/return switch test. Reverts automatically. Suppresses webhooks and log writes.           |
| `--revert`               | After a successful switch, switch back to the original peer.                                                |
| `--ignore-cooldown`      | Skip cooldown checks when selecting the next peer.                                                          |
| `--iface <iface>`        | Sub-qualifier for `--fail`, `--exercise`, and `--force-rotate` — target by interface name instead of label. |
| `--version`              | Print version and exit.                                                                                     |

The `<label>` argument must match `TUNNEL_X_LABEL` exactly, including capitalisation.

### Examples

```bash
# Check tunnel status
/usr/bin/wg_failover.sh status
/usr/bin/wg_failover.sh status --json

# Trace failover logic without making any changes
/usr/bin/wg_failover.sh --dry-run

# Trigger an immediate failover on a specific tunnel
/usr/bin/wg_failover.sh --fail "Primary (Set A)"

# Force a rotation without simulating a failure
/usr/bin/wg_failover.sh --force-rotate "Primary (Set A)"
/usr/bin/wg_failover.sh --force-rotate --iface wgclient1

# Simulate a WAN outage (failover suppressed on all tunnels)
/usr/bin/wg_failover.sh --fail-wan

# Run a full end-to-end exercise test (switches and auto-reverts)
/usr/bin/wg_failover.sh --exercise
/usr/bin/wg_failover.sh --exercise "Primary (Set A)"

# Clear all state
/usr/bin/wg_failover.sh reset
/usr/bin/wg_failover.sh reset --keep-history
```

---

## Webhook Notifications

Set `WEBHOOK_URL` to receive a notification on failover, rotation, or WAN state changes.

### ntfy.sh (cloud-hosted, GET)

```bash
WEBHOOK_URL='https://ntfy.sh/your-topic-name'
WEBHOOK_METHOD='GET'
```

### Gotify (self-hosted, POST)

```bash
WEBHOOK_URL='https://your-gotify-server/message?token=YOUR_APP_TOKEN'
WEBHOOK_METHOD='POST'
```

> **Note:** Gotify expects `title`, `message`, and `priority` fields. The script sends its own payload structure — the notification will appear with a blank title in the Gotify UI. To fix this, modify the `send_webhook` function in the script to use Gotify's expected format.

### Custom Endpoint (POST)

```bash
WEBHOOK_URL='https://yourserver.com/webhook'
WEBHOOK_METHOD='POST'
```

POST payload:

```json
{
  "tunnel": "Primary (Set A)",
  "from": "Provider-SetA-Server1",
  "to": "Provider-SetA-Server2",
  "status": "switched"
}
```

### Status Values

| Status        | Meaning                                                                            |
| ------------- | ---------------------------------------------------------------------------------- |
| `switched`    | Failover successful — new server verified                                          |
| `rotated`     | Scheduled rotation successful — new server verified                                |
| `ping_failed` | Switched to new server but ping verification failed                                |
| `all_failed`  | All servers in the pool are exhausted or in cooldown                               |
| `wan_down`    | WAN outage detected; failover suppressed (rate-limited per `WAN_WEBHOOK_INTERVAL`) |
| `wan_up`      | WAN restored after a `wan_down` event                                              |

---

## Logs

Default location: `/var/log/wg_failover.log`

> **OpenWrt note:** `/var/log/` is stored in RAM and cleared on every reboot. This is normal behaviour.

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

### A tunnel is off but the script still monitors it

The script checks whether each interface is administratively up before monitoring — if you switch a tunnel off in the GL.iNet admin panel it will be skipped automatically. You can also set `TUNNEL_X_ENABLED=0` to permanently exclude a tunnel without removing its configuration.

---

## Limitations

### Out-of-sync GL.iNet dashboard

This project switches WireGuard peers outside of the GL.iNet VPN Client application. As a result, the router dashboard will likely display incorrect server information after an automated failover.

| Component                       | Reported VPN server                           |
| ------------------------------- | --------------------------------------------- |
| Failover script (`status`)      | ✅ Correct (actual active peer)               |
| WireGuard CLI / traffic routing | ✅ Correct                                    |
| GL.iNet Web Dashboard           | ❌ Likely shows last GUI-selected server      |
| Router reboot behaviour         | ❌ Likely reconnects last GUI-selected server |

Traffic routing, kill-switch behaviour, DNS, and connectivity all use the new active peer — only the dashboard display is affected.

To verify the real connection at any time:

```bash
/usr/bin/wg_failover.sh status
```

**If anyone has suggestions to fix this, please let me know!**

---

## License

MIT License — feel free to modify and distribute.

## Contributing

Issues and pull requests are welcome.

---

## Support

If this script has been useful to you, a coffee is always appreciated — thank you!

[![Buy Me A Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://buymeacoffee.com/92jackson)
