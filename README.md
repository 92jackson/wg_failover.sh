# wg_failover.sh

**WireGuard VPN Tunnel Failover and Auto-Rotate for GL.iNet Routers (OpenWrt)**

- Automatically monitors one or more WireGuard tunnels and switches to the next available VPN server when the current one becomes unresponsive. After switching, verifies the new connection with a ping test before declaring the failover successful. Supports scheduled server rotation independent of tunnel health.

- Optionally, configure each tunnel to rotate to the next server on a schedule- after a set number of hours, at a specific time of day, or both.

---

## How It Works

WireGuard maintains a "last handshake" timestamp for each peer connection, refreshed roughly every 3 minutes under normal conditions. When this goes stale beyond a configurable threshold, the script treats the server as down and rotates to the next server in the pool.

After switching, it waits briefly for the new connection to establish, then pings a target IP through the specific tunnel interface to confirm traffic is actually flowing. If the ping fails, it immediately tries the next server- no waiting for the next cron cycle.

Each tunnel is monitored independently. Failed servers are placed in a cooldown period to prevent immediately cycling back to a dead server. A lockfile prevents overlapping cron runs during longer failover sequences.

Separately from failure-driven failover, each tunnel can be configured to rotate to the next server on a schedule- after a set number of hours, at a specific time of day, or both.

---

## Features

- **Automatic failover**- Detects stale WireGuard handshakes and switches servers without manual intervention
- **Scheduled rotation**- Rotate to the next server after X hours or at a set time of day, regardless of tunnel health
- **Ping verification**- Confirms the new server is actually routing traffic after switching
- **Per-peer cooldown**- Prevents cycling back to recently failed servers
- **Independent multi-tunnel support**- Monitor multiple WireGuard tunnels, each with their own server pool
- **Webhook notifications**- Get alerted via ntfy.sh or any custom HTTP endpoint on failover and rotation events
- **Flexible flag interface**- Composable flags for dry-run, simulated failure, exercise testing, cooldown bypass, and post-switch revert
- **Configurable log levels**- From silent to verbose, with automatic log rotation

---

## Compatibility

- GL.iNet firmware 4.x (split-tunnel / VPN policy / dashboard mode)
- GL.iNet firmware 4.x (global VPN mode- single tunnel, no policies)
- Any OpenWrt device using UCI WireGuard peer configuration + ubus network control

---

## Prerequisites

Before installing, confirm the following are in place:

- **SSH access enabled**
- **At least 2 VPN server profiles configured** per tunnel

---

## Known Issues

⚠️ Out-of-sync GUI status

This project switches WireGuard peers outside of the GL.iNet VPN Client application by performing a direct OpenWrt WireGuard switch.
As a result, the router dashboard will likely display incorrect server information after an automated failover.

What you will see after a failover or rotation:

| Component                       | Reported VPN server                          |
| ------------------------------- | -------------------------------------------- |
| Failover script (`status`)      | ✅ Correct (actual active peer)              |
| WireGuard CLI / traffic routing | ✅ Correct                                   |
| GL.iNet Web Dashboard           | ❌ Likely show last GUI selected server      |
| Router reboot behaviour         | ❌ Likely reconnect last GUI selected server |

**Does this affect functionality?**

No.
Traffic routing, kill-switch behaviour, DNS, and connectivity all use the new active peer.

To verify the real connection at any time:

```bash
/usr/bin/wg_failover.sh status
```

**If anyone has any suggestions to fix this, please let me know!**

---

## Installation

The script must be configured before being activated. Do not add it to cron until you have edited it with your tunnel details- running it unconfigured will cause it to use the placeholder values in the script.

**Step 1- Download the script to the router over SSH:**

```bash
wget -O /usr/bin/wg_failover.sh https://raw.githubusercontent.com/92jackson/wg_failover.sh/refs/heads/main/wg_failover.sh
chmod +x /usr/bin/wg_failover.sh
```

**Step 2- Discover your router's values and configure the script** (see [Configuration](#configuration) below).

**Step 3- Once configured, activate the script via cron:**

```bash
echo "* * * * * /usr/bin/wg_failover.sh" >> /etc/crontabs/root
/etc/init.d/cron restart
```

**Step 4- Verify it is running correctly:**

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

Before editing the script, run the following commands on your router to find the correct values.

```bash
# 1. List your WireGuard tunnel interfaces and their currently active server
uci show network | grep -A5 wgclient | grep -E "^network\.wgclient|\.config="
```

```
network.wgclient1=interface
network.wgclient1.config='peer_100'
network.wgclient2=interface
network.wgclient2.config='peer_103'
```

The interface names (`wgclient1`, `wgclient2`) are your `TUNNEL_X_IFACE` and `TUNNEL_X_WG_IF` values.

---

```bash
# 2. List all VPN servers and the routing table assigned to each tunnel
uci show wireguard | grep '\.name=' && uci show network | grep ip4table
```

```
wireguard.peer_100.name='Provider-RegionA-Server1'
wireguard.peer_101.name='Provider-RegionA-Server2'
wireguard.peer_102.name='Provider-RegionA-Server3'
wireguard.peer_103.name='Provider-RegionB-Server1'
wireguard.peer_104.name='Provider-RegionB-Server2'
network.wgclient1.ip4table='1001'
network.wgclient2.ip4table='1002'
```

- The routing table numbers (`1001`, `1002`) are your `TUNNEL_X_ROUTE_TABLE` values- these ensure ping verification is routed through the correct tunnel.
- Choose a substring present in all the server names you want grouped into each tunnel's failover pool. For example `RegionA` matches all three Region A servers above; `RegionB` matches both Region B servers. These become your `TUNNEL_X_KEYWORD` values. You need at least 2 matching servers per tunnel for failover to be possible.

---

### Configuring Your Tunnels

With the values discovered above, edit the tunnel definitions in the script:

```bash
TUNNEL_COUNT=2

# Tunnel 1: Primary VPN- all Region A servers, no rotation
TUNNEL_1_IFACE='wgclient1'
TUNNEL_1_WG_IF='wgclient1'
TUNNEL_1_LABEL='Primary (Region A)'
TUNNEL_1_KEYWORD='RegionA'
TUNNEL_1_ROUTE_TABLE='1001'
TUNNEL_1_ENABLED=1
TUNNEL_1_ROTATE_INTERVAL=0
TUNNEL_1_ROTATE_AT=''

# Tunnel 2: Secondary VPN- all Region B servers, rotates every 6h and at 3am
TUNNEL_2_IFACE='wgclient2'
TUNNEL_2_WG_IF='wgclient2'
TUNNEL_2_LABEL='Secondary (Region B)'
TUNNEL_2_KEYWORD='RegionB'
TUNNEL_2_ROUTE_TABLE='1002'
TUNNEL_2_ENABLED=1
TUNNEL_2_ROTATE_INTERVAL=6
TUNNEL_2_ROTATE_AT='03:00'
```

---

### Scheduled Rotation

Each tunnel can rotate to the next server in its pool on a schedule, independent of whether the current server is healthy. Both conditions can be set simultaneously- whichever triggers first wins.

| Variable                   | Description                                                      |
| -------------------------- | ---------------------------------------------------------------- |
| `TUNNEL_X_ROTATE_INTERVAL` | Hours between forced rotations. `0` = disabled.                  |
| `TUNNEL_X_ROTATE_AT`       | Time-of-day rotation in `HH:MM` 24-hour format. `''` = disabled. |

Rotation always verifies the new server with a ping test. If the rotated-to server fails verification, it is placed in cooldown and the rotation timestamp is still recorded to avoid hammering a bad server every minute.

A successful rotation sends a `rotated` webhook notification and is clearly marked `[rotation]` in the log, distinct from failure-driven failovers.

---

### Blank Keyword- Global VPN Mode / Catch-All Pool

Setting `TUNNEL_X_KEYWORD=''` (blank) tells the script to build that tunnel's pool from **all servers not already claimed by another tunnel's keyword**. The other tunnels' keywords act as excluders automatically.

**Single global VPN (no split-tunnel policies)- one tunnel, all servers:**

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

**Mixed- keyword tunnel plus a catch-all tunnel:**

```bash
TUNNEL_COUNT=2

TUNNEL_1_KEYWORD='RegionA'  # Claims all servers whose name contains 'RegionA'
TUNNEL_2_KEYWORD=''         # Gets everything not claimed by any other tunnel
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
| `PING_TARGET`                   | IP address to ping for verification                            | `1.1.1.1`                  |
| `PING_COUNT`                    | Number of ping packets to send                                 | `3`                        |
| `PING_TIMEOUT`                  | Seconds to wait per ping reply                                 | `5`                        |
| `MAX_FAILOVER_ATTEMPTS`         | Max servers to try per cycle (`0` = unlimited)                 | `0`                        |
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

### Normal Operation

The script is called automatically by cron every minute. No manual intervention is needed during normal operation.

### Flags

All flags are composable and can be combined freely. They may appear in any order.

| Flag                 | Description                                                                                       |
| -------------------- | ------------------------------------------------------------------------------------------------- |
| `--dry-run`          | Run full logic but make no changes. Output goes to stdout, not the log.                           |
| `--fail <label>`     | Treat the named tunnel as failed this run, triggering an immediate switch.                        |
| `--exercise [label]` | Run a full forward/return switch test. Reverts automatically. Suppresses webhooks and log writes. |
| `--revert`           | After a successful switch, switch back to the original peer.                                      |
| `--ignore-cooldown`  | Skip cooldown checks when selecting the next peer.                                                |

The `<label>` argument must match `TUNNEL_X_LABEL` exactly, including capitalisation.

### Subcommands

| Subcommand | Description                                                                                        |
| ---------- | -------------------------------------------------------------------------------------------------- |
| `status`   | Print tunnel status, handshake health, peer pool, cooldowns, rotation state, and a live ping test. |
| `reset`    | Clear all cooldowns, grace periods, rotation timestamps, and the run timer.                        |

---

### Examples

```bash
# Check all tunnel status
/usr/bin/wg_failover.sh status

# Clear all state (force an immediate check on next cron tick)
/usr/bin/wg_failover.sh reset

# Trace failover logic without making any changes
/usr/bin/wg_failover.sh --dry-run

# Trigger a real immediate failover on a specific tunnel
/usr/bin/wg_failover.sh --fail "Primary (Region A)"

# Dry-run a simulated failure to trace decision logic
/usr/bin/wg_failover.sh --dry-run --fail "Primary (Region A)"

# Trigger a failover but revert to original peer after success (useful for alerting tests)
/usr/bin/wg_failover.sh --fail "Primary (Region A)" --revert

# Force a failover even if the next candidate is in cooldown
/usr/bin/wg_failover.sh --fail "Primary (Region A)" --ignore-cooldown

# Run a full end-to-end exercise test on all tunnels
/usr/bin/wg_failover.sh --exercise

# Exercise a single tunnel
/usr/bin/wg_failover.sh --exercise "Primary (Region A)"

# Dry-run an exercise with cooldown bypass
/usr/bin/wg_failover.sh --dry-run --exercise --ignore-cooldown
```

### Status Output

```
============================================
  wg_failover.sh v1.0.0 -- Tunnel Status
  2024-01-15 14:32:01
============================================
  Lock: none (no run in progress)

  [1] Primary (Region A)
  Interface : wgclient1
  Active    : Provider-RegionA-Server1 (peer_100)
  Handshake : OK -- 45s ago
  Keyword   : 'RegionA'
  Route tbl : 1001
  Peer pool : 3 peers
    . Provider-RegionA-Server1 (peer_100) [ACTIVE]
    . Provider-RegionA-Server2 (peer_101)
    . Provider-RegionA-Server3 (peer_102)
  Rotation  : disabled
  Ping test : PASS (1.1.1.1 reachable through tunnel)

  [2] Secondary (Region B)
  Interface : wgclient2
  Active    : Provider-RegionB-Server1 (peer_103)
  Handshake : OK -- 89s ago
  Keyword   : 'RegionB'
  Route tbl : 1002
  Peer pool : 2 peers
    . Provider-RegionB-Server1 (peer_103) [ACTIVE]
    . Provider-RegionB-Server2 (peer_104)
  Rotation  : every 6h or at 03:00 -- last rotated 2024-01-15 08:00 (22932s ago)
  Ping test : PASS (1.1.1.1 reachable through tunnel)

  Ping verify : enabled (target: 1.1.1.1)
  Log file    : /var/log/wg_failover.log
  State dir   : /tmp/wg_failover
  Webhook     : disabled
============================================
```

---

## Webhook Notifications

Set `WEBHOOK_URL` to receive a notification whenever a failover or rotation occurs.

### ntfy.sh (cloud-hosted, GET)

The simplest option- no account or server required for basic use:

```bash
WEBHOOK_URL='https://ntfy.sh/your-topic-name'
WEBHOOK_METHOD='GET'
```

### Gotify (self-hosted, POST)

[Gotify](https://gotify.net) is a self-hosted, open-source push notification server:

```bash
WEBHOOK_URL='https://your-gotify-server/message?token=YOUR_APP_TOKEN'
WEBHOOK_METHOD='POST'
```

> **Note:** Gotify expects `title`, `message`, and `priority` fields. The script sends its own payload structure- the notification will appear with a blank title in the Gotify UI. To fix this, modify the `send_webhook` function in the script:
>
> ```sh
> BODY="{\"title\":\"VPN Failover\",\"message\":\"${TUNNEL_LABEL}: ${FROM_PEER} -> ${TO_PEER} (${STATUS})\",\"priority\":5}"
> ```

### Custom Endpoint (POST)

```bash
WEBHOOK_URL='https://yourserver.com/webhook'
WEBHOOK_METHOD='POST'
```

POST payload:

```json
{
  "tunnel": "Primary (Region A)",
  "from": "Provider-RegionA-Server1",
  "to": "Provider-RegionA-Server2",
  "status": "switched"
}
```

GET equivalent:

```
?tunnel=Primary%20(Region%20A)&from=Provider-RegionA-Server1&to=Provider-RegionA-Server2&status=switched
```

### Status Values

| Status        | Meaning                                              |
| ------------- | ---------------------------------------------------- |
| `switched`    | Failover successful- new server verified             |
| `rotated`     | Scheduled rotation successful- new server verified   |
| `ping_failed` | Switched to new server but ping verification failed  |
| `all_failed`  | All servers in the pool are exhausted or in cooldown |

---

## Logs

Default location: `/var/log/wg_failover.log`

> **OpenWrt note:** `/var/log/` is stored in RAM on OpenWrt and is cleared on every reboot. Logs do not persist across reboots. This is normal behaviour.

| Level | What is logged                                                            |
| ----- | ------------------------------------------------------------------------- |
| `0`   | Nothing                                                                   |
| `1`   | Failovers, rotations, and errors only (recommended for production)        |
| `2`   | Also includes successful health checks (recommended during initial setup) |
| `3`   | Every check including handshake ages and peer pool details                |

Each switch is tagged with its reason in the log- `[failover]`, `[rotation]`, `[exercise]`, or `[revert]`- so you can distinguish scheduled rotations from emergency failovers at a glance.

```bash
# View recent entries
tail -50 /var/log/wg_failover.log

# Watch live
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

Verify your keyword matches actual server names- keywords are case-sensitive:

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

Increase `HANDSHAKE_TIMEOUT` to `240` or `300`. WireGuard re-handshakes roughly every 3 minutes under normal conditions but this can occasionally stretch longer on congested connections.

### Rotation fires multiple times in the same minute

This should not happen- a 1-hour re-trigger guard is built into the time-of-day check. If you see it, check that `STATE_DIR` is writable and the `.last_rotate` file is being created.

### A tunnel is off but the script still monitors it

The script checks whether each interface is administratively up before monitoring it- if you switch a tunnel off in the GL.iNet admin panel it will be skipped automatically. You can also set `TUNNEL_X_ENABLED=0` to permanently exclude a tunnel from monitoring without removing its definition from the script.

---

## License

MIT License- feel free to modify and distribute.

## Contributing

Issues and pull requests are welcome.

When submitting a fix or feature, test using dry-run and exercise mode first:

```bash
# Trace logic without touching live config
/usr/bin/wg_failover.sh --dry-run --fail "Your Tunnel Label"

# Run a full switch test and revert
/usr/bin/wg_failover.sh --exercise "Your Tunnel Label"
```

---

## Support

If this script has been useful to you, a coffee is always appreciated- thank you!

[![Buy Me A Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://buymeacoffee.com/92jackson)
