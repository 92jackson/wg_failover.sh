#!/bin/sh
# =============================================================================
# wg_failover.sh v1.0.0 — WireGuard Tunnel Failover for GL.iNet Routers (OpenWrt)
# =============================================================================
# Monitors one or more WireGuard tunnels and automatically switches to the
# next available peer when the current one goes stale. After switching,
# verifies the new connection with a ping test routed through the specific
# tunnel interface before declaring the failover successful.
#
# A lockfile prevents concurrent cron instances from running simultaneously,
# which is important since failover runs can exceed 60s.
#
# INSTALL:
#   1. Copy this script to /usr/bin/wg_failover.sh
#   2. Make executable:  chmod +x /usr/bin/wg_failover.sh
#   3. Configure:        vi /usr/bin/wg_failover.sh
#   4. Add to cron:      crontab -e
#      Add line:         * * * * * /usr/bin/wg_failover.sh
#   5. Restart cron:     /etc/init.d/cron restart
#
# SUBCOMMANDS:
#   status                    — print tunnel status and live ping test, then exit
#   reset                     — clear all state/cooldowns and exit
#
# FLAGS (can be combined freely):
#   --dry-run                 — run logic but make no real changes to the router
#   --fail <label>            — inject a simulated failure on the named tunnel
#   --exercise [label]        — run an end-to-end switch test (all tunnels, or one)
#   --revert                  — after a successful switch, revert to the original peer
#   --ignore-cooldown         — skip cooldown checks when selecting the next peer
#
# EXAMPLES:
#   # Normal cron operation:
#   /usr/bin/wg_failover.sh
#
#   # See what the failover logic would do without changing anything:
#   /usr/bin/wg_failover.sh --dry-run
#
#   # Trigger a real failover on a specific tunnel immediately:
#   /usr/bin/wg_failover.sh --fail "Primary (UK)"
#
#   # Dry-run a simulated failure to trace the decision logic:
#   /usr/bin/wg_failover.sh --dry-run --fail "Primary (UK)"
#
#   # Run a full end-to-end switch test on all tunnels:
#   /usr/bin/wg_failover.sh --exercise
#
#   # Run an end-to-end switch test on one specific tunnel:
#   /usr/bin/wg_failover.sh --exercise "Primary (UK)"
#
#   # Inject a failure AND revert after the switch (useful for testing alerting):
#   /usr/bin/wg_failover.sh --fail "Primary (UK)" --revert
#
#   # Inject a failure, bypassing cooldown on the next candidate:
#   /usr/bin/wg_failover.sh --fail "Primary (UK)" --ignore-cooldown
#
#   # Dry-run exercise with cooldown bypass:
#   /usr/bin/wg_failover.sh --dry-run --exercise --ignore-cooldown
#
# COMPATIBILITY:
#   - GL.iNet firmware 4.x, split-tunnel (VPN dashboard/policy) mode
#   - GL.iNet firmware 4.x, global VPN mode (single tunnel, no policies)
#   - Any OpenWrt device using uci wireguard peer config + ubus network control
#
# GLOBAL MODE USERS:
#   If you use a single global VPN (no split tunnel/policy routing), define
#   just one tunnel entry and leave TUNNEL_1_KEYWORD='' blank. All configured
#   peers will be used as the failover pool automatically.
# =============================================================================


# =============================================================================
# USER CONFIGURATION
# =============================================================================

# How often (seconds) to actually perform a check. Cron fires every minute;
# this throttle prevents checks running more often than desired.
# 60 = every minute, 300 = every 5 minutes.
CHECK_INTERVAL=60

# Seconds a WireGuard handshake can be stale before triggering failover.
# WireGuard re-handshakes roughly every 3 minutes under normal conditions.
# 180 = reliable minimum. Use 240-300 if you experience false positives.
HANDSHAKE_TIMEOUT=180

# Seconds to wait before retrying a peer that previously failed.
# Prevents the script cycling immediately back to a dead server.
# 600 = 10 minute cooldown per failed peer.
PEER_COOLDOWN=600

# Maximum seconds to wait for a new peer's handshake to appear after switching,
# before falling back to a timed wait. The script polls every few seconds
# during this window and reports exactly how long the handshake took.
# Used during normal failover and --exercise mode.
POST_SWITCH_HANDSHAKE_TIMEOUT=45

# If the handshake polling above times out (peer connected but no handshake yet),
# how many additional seconds to wait before attempting the ping test anyway.
# This acts as a last-resort grace period before the ping is tried.
POST_SWITCH_DELAY=20

# After a successful switch (peer verified or ping disabled), how many
# seconds before the tunnel is subject to normal handshake monitoring again.
# Should be >= POST_SWITCH_HANDSHAKE_TIMEOUT.
POST_SWITCH_GRACE=60

# Enable ping-based connectivity verification after switching peers.
# When enabled, the script pings PING_TARGET through the tunnel after the
# handshake is confirmed (or POST_SWITCH_DELAY has elapsed).
# If ping fails, the peer is marked failed and the next peer is tried.
# 1 = enabled (recommended), 0 = disabled (rely on handshake age only)
PING_VERIFY=1

# IP address to ping when verifying tunnel connectivity.
# Should be a reliable public IP reachable through the VPN.
# Avoid hostnames — DNS may not be up immediately after switching.
# Recommended: 1.1.1.1 (Cloudflare) or 8.8.8.8 (Google)
PING_TARGET='1.1.1.1'

# Number of ping packets to send during verification.
# The test passes if at least one packet gets a reply.
PING_COUNT=3

# Seconds to wait for each ping reply before timing out.
PING_TIMEOUT=5

# How often (seconds) to poll the handshake after switching, while waiting
# for the new peer to establish. Lower = faster detection, higher = less CPU.
HANDSHAKE_POLL_INTERVAL=3

# Maximum peers to try per failover cycle. 0 = try all available peers.
MAX_FAILOVER_ATTEMPTS=0

# Log file path. Set to '' to disable logging entirely.
LOG_FILE='/var/log/wg_failover.log'

# Maximum log file size in bytes before it is rotated (old content cleared).
# 102400 = 100KB
LOG_MAX_SIZE=102400

# Log level — controls how much is written to LOG_FILE:
#   0 = silent  (nothing logged)
#   1 = changes and errors only  (recommended for production)
#   2 = normal  (+ startup and OK health checks — good for initial setup)
#   3 = verbose (+ every check, handshake ages, peer pool details)
LOG_LEVEL=2

# Webhook URL for failover notifications. Set to '' to disable.
#
# GET  appends: ?tunnel=<label>&from=<old>&to=<new>&status=<state>
# POST sends JSON: {"tunnel":"...","from":"...","to":"...","status":"..."}
#
# Status values:
#   switched    — failover successful, new peer verified
#   rotated     — scheduled rotation successful, new peer verified
#   ping_failed — switched to new peer but ping verification failed
#   all_failed  — all peers exhausted or in cooldown
#
# Note: webhooks are suppressed in --dry-run mode and --exercise mode.
#
# Compatible services:
#   ntfy.sh:  'https://ntfy.sh/your-topic-name'
#   Gotify:   'https://your-gotify-server/message?token=YOUR_APP_TOKEN'
#   Custom:   'https://yourserver.com/webhook'
WEBHOOK_URL=''

# Webhook HTTP method: 'GET' or 'POST'
WEBHOOK_METHOD='GET'

# State directory — persists active peer, cooldowns, grace timers, lockfile.
# /tmp is cleared on reboot, which is acceptable (state re-detects cleanly).
STATE_DIR='/tmp/wg_failover'

# =============================================================================
# TUNNEL DEFINITIONS
#
# Define one block per tunnel. Variables per tunnel:
#
#   TUNNEL_<N>_IFACE        OpenWrt network interface name.
#                           Find yours: uci show network | grep wgclient
#
#   TUNNEL_<N>_WG_IF        WireGuard kernel interface name (usually same as IFACE).
#                           Verify with: wg show
#
#   TUNNEL_<N>_LABEL        Friendly label used in logs, webhooks, and flag
#                           targeting (--fail, --exercise). Case-sensitive.
#
#   TUNNEL_<N>_KEYWORD      Substring matched against peer names in uci to build
#                           the pool of usable peers for this tunnel.
#                           e.g. 'RegionA' matches all peers whose name contains
#                           'RegionA'. Case-sensitive.
#                           List all peers with:
#                             uci show wireguard | grep '\.name='
#
#                           LEAVE BLANK to use all peers not claimed by any
#                           other tunnel's keyword as this tunnel's pool.
#                           Only one tunnel may have a blank keyword.
#
#   TUNNEL_<N>_ROUTE_TABLE  Routing table number used to route pings through this
#                           specific tunnel during verification.
#                           Find yours: look for 'option ip4table' under your
#                           wgclient block in /etc/config/network
#                           Set to '' to use interface-bound ping fallback instead.
#
#   TUNNEL_<N>_ENABLED      1 = actively monitor this tunnel
#                           0 = skip (monitoring disabled for this tunnel only)
#
#   TUNNEL_<N>_ROTATE_INTERVAL
#                           Hours between forced server rotations regardless of
#                           health. 0 = disabled. e.g. 6 = rotate every 6 hours.
#                           The next peer is chosen sequentially from the pool.
#                           If the chosen peer is in cooldown, the one after it
#                           is tried (unless --ignore-cooldown is set).
#
#   TUNNEL_<N>_ROTATE_AT    Time-of-day to trigger a forced rotation, in HH:MM
#                           24-hour format. '' = disabled.
#                           e.g. '03:00' rotates daily at 3am.
#                           Both ROTATE_INTERVAL and ROTATE_AT can be set
#                           simultaneously; the first condition to trigger wins.
#                           Guard: once rotation fires, it will not fire again
#                           for at least 1 hour (prevents multiple cron ticks
#                           within the same minute from re-triggering).
#
# Set TUNNEL_COUNT to the total number of tunnel blocks defined below.
# =============================================================================

TUNNEL_COUNT=2

TUNNEL_1_IFACE='wgclient1'
TUNNEL_1_WG_IF='wgclient1'
TUNNEL_1_LABEL='Primary (UK)'
TUNNEL_1_KEYWORD='UK'
TUNNEL_1_ROUTE_TABLE='1001'
TUNNEL_1_ENABLED=1
TUNNEL_1_ROTATE_INTERVAL=0
TUNNEL_1_ROTATE_AT=''

TUNNEL_2_IFACE='wgclient2'
TUNNEL_2_WG_IF='wgclient2'
TUNNEL_2_LABEL='Streaming (Albania)'
TUNNEL_2_KEYWORD='AL'
TUNNEL_2_ROUTE_TABLE='1002'
TUNNEL_2_ENABLED=1
TUNNEL_2_ROTATE_INTERVAL=6
TUNNEL_2_ROTATE_AT='03:00'

# =============================================================================
# END OF USER CONFIGURATION — do not edit below unless you know what you're doing
# =============================================================================


# --- Globals ------------------------------------------------------------------

DRY_RUN=0
SUBCOMMAND=''
FLAG_FAIL=0
FLAG_FAIL_LABEL=''
FLAG_EXERCISE=0
FLAG_EXERCISE_LABEL=''
FLAG_REVERT=0
FLAG_IGNORE_COOLDOWN=0
INTERACTIVE=''
TEST_PASS=0
TEST_FAIL=0


# --- Argument parsing ---------------------------------------------------------
# Subcommands: status, reset
# Flags (all combinable): --dry-run, --fail <label>, --exercise [label],
#                         --revert, --ignore-cooldown
# Flags may appear in any order, before or after the subcommand.

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                INTERACTIVE=1
                shift
                ;;
            --fail)
                FLAG_FAIL=1
                INTERACTIVE=1
                shift
                if [ -z "$1" ] || echo "$1" | grep -q '^--'; then
                    echo "Error: --fail requires a tunnel label argument"
                    echo "Example: wg_failover.sh --fail \"Primary (UK)\""
                    exit 1
                fi
                FLAG_FAIL_LABEL="$1"
                shift
                ;;
            --exercise)
                FLAG_EXERCISE=1
                INTERACTIVE=1
                shift
                # Optional label — consume next arg if it doesn't start with --
                if [ -n "$1" ] && ! echo "$1" | grep -q '^--'; then
                    FLAG_EXERCISE_LABEL="$1"
                    shift
                fi
                ;;
            --revert)
                FLAG_REVERT=1
                shift
                ;;
            --ignore-cooldown)
                FLAG_IGNORE_COOLDOWN=1
                shift
                ;;
            status|reset)
                SUBCOMMAND="$1"
                shift
                ;;
            *)
                echo "Unknown argument: $1"
                echo "Usage: $0 [status|reset] [--dry-run] [--fail <label>] [--exercise [label]] [--revert] [--ignore-cooldown]"
                exit 1
                ;;
        esac
    done
}


# --- Safe execution wrapper ---------------------------------------------------
# All commands that change router state go through do_exec.
# In --dry-run mode the command is logged but not run.

do_exec() {
    if [ "$DRY_RUN" = "1" ]; then
        log_dryrun "Would run: $*"
    else
        "$@"
    fi
}


# --- Lockfile -----------------------------------------------------------------

LOCKFILE="${STATE_DIR}/wg_failover.lock"

acquire_lock() {
    mkdir -p "$STATE_DIR"

    if [ -f "$LOCKFILE" ]; then
        LOCKED_PID=$(cat "$LOCKFILE" 2>/dev/null)
        if [ -n "$LOCKED_PID" ] && kill -0 "$LOCKED_PID" 2>/dev/null; then
            log_verbose "Another instance (PID ${LOCKED_PID}) is still running — exiting"
            exit 0
        else
            log_verbose "Removing stale lockfile (PID ${LOCKED_PID} no longer running)"
            rm -f "$LOCKFILE"
        fi
    fi

    [ "$DRY_RUN" = "0" ] && echo $$ > "$LOCKFILE"
}

release_lock() {
    [ "$DRY_RUN" = "0" ] && rm -f "$LOCKFILE"
}

trap release_lock EXIT


# --- Logging ------------------------------------------------------------------

log() {
    LEVEL=$1
    MSG=$2
    [ "$LOG_LEVEL" -lt "$LEVEL" ] && return
    [ -z "$LOG_FILE" ] && return

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    ENTRY="[$TIMESTAMP] $MSG"

    # Don't write to log file in dry-run or exercise mode — stdout only
    if [ "$DRY_RUN" = "0" ] && [ "$FLAG_EXERCISE" = "0" ]; then
        if [ -f "$LOG_FILE" ]; then
            SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
            if [ "$SIZE" -gt "$LOG_MAX_SIZE" ]; then
                echo "[$TIMESTAMP] [INFO] Log rotated (exceeded ${LOG_MAX_SIZE} bytes)" > "$LOG_FILE"
            fi
        fi
        echo "$ENTRY" >> "$LOG_FILE"
    fi

    [ -n "$INTERACTIVE" ] && echo "$ENTRY"
}

log_info()    { log 2 "[INFO]   $1"; }
log_change()  { log 1 "[CHANGE] $1"; }
log_error()   { log 1 "[ERROR]  $1"; }
log_warn()    { log 1 "[WARN]   $1"; }
log_verbose() { log 3 "[DEBUG]  $1"; }
log_dryrun()  {
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] [DRY-RUN] $1"
}

# Exercise-mode step logger — always prints to stdout with clear pass/fail markers
test_step() {
    STATUS=$1
    MSG=$2
    TIMESTAMP=$(date '+%H:%M:%S')
    printf "  [%s] %-6s %s\n" "$TIMESTAMP" "$STATUS" "$MSG"
}

test_pass() { TEST_PASS=$((TEST_PASS + 1)); test_step "PASS" "$1"; }
test_fail() { TEST_FAIL=$((TEST_FAIL + 1)); test_step "FAIL" "$1"; }
test_info() { test_step "INFO" "$1"; }
test_warn() { test_step "WARN" "$1"; }


# --- Webhook ------------------------------------------------------------------

send_webhook() {
    TUNNEL_LABEL=$1
    FROM_PEER=$2
    TO_PEER=$3
    STATUS=$4

    [ -z "$WEBHOOK_URL" ] && return
    # Suppress webhooks in dry-run and exercise mode
    [ "$DRY_RUN" = "1" ] && log_dryrun "Would send webhook: status=${STATUS} tunnel='${TUNNEL_LABEL}' from='${FROM_PEER}' to='${TO_PEER}'" && return
    [ "$FLAG_EXERCISE" = "1" ] && return

    if [ "$WEBHOOK_METHOD" = "POST" ]; then
        BODY="{\"tunnel\":\"${TUNNEL_LABEL}\",\"from\":\"${FROM_PEER}\",\"to\":\"${TO_PEER}\",\"status\":\"${STATUS}\"}"
        wget -q -O /dev/null --timeout=10 \
            --post-data="$BODY" \
            --header="Content-Type: application/json" \
            "$WEBHOOK_URL" 2>/dev/null &
    else
        # URL-encode common special characters in the label
        ENCODED=$(printf '%s' "$TUNNEL_LABEL" \
            | sed 's/ /%20/g; s/&/%26/g; s/=/%3D/g; s/+/%2B/g')
        wget -q -O /dev/null --timeout=10 \
            "${WEBHOOK_URL}?tunnel=${ENCODED}&from=${FROM_PEER}&to=${TO_PEER}&status=${STATUS}" \
            2>/dev/null &
    fi

    log_verbose "Webhook sent: status=${STATUS} tunnel='${TUNNEL_LABEL}' from='${FROM_PEER}' to='${TO_PEER}'"
}


# --- Peer pool building -------------------------------------------------------

get_all_peers() {
    uci show wireguard 2>/dev/null \
        | grep "\.name=" \
        | sed "s/wireguard\.\(peer_[0-9]*\)\.name=.*/\1/"
}

get_peers_for_keyword() {
    uci show wireguard 2>/dev/null \
        | grep "\.name=.*${1}" \
        | sed "s/wireguard\.\(peer_[0-9]*\)\.name=.*/\1/"
}

get_peers_excluding_other_keywords() {
    SELF_INDEX=$1
    ALL_PEERS=$(get_all_peers)
    EXCLUDED=''

    j=1
    while [ "$j" -le "$TUNNEL_COUNT" ]; do
        [ "$j" = "$SELF_INDEX" ] && j=$((j + 1)) && continue
        eval "OTHER_KEYWORD=\$TUNNEL_${j}_KEYWORD"
        eval "OTHER_ENABLED=\$TUNNEL_${j}_ENABLED"
        if [ "$OTHER_ENABLED" = "1" ] && [ -n "$OTHER_KEYWORD" ]; then
            CLAIMED=$(get_peers_for_keyword "$OTHER_KEYWORD")
            EXCLUDED="$EXCLUDED $CLAIMED"
        fi
        j=$((j + 1))
    done

    for PEER in $ALL_PEERS; do
        SKIP=0
        for EX in $EXCLUDED; do
            [ "$PEER" = "$EX" ] && SKIP=1 && break
        done
        [ "$SKIP" = "0" ] && printf '%s ' "$PEER"
    done
}

get_peer_name() {
    uci get "wireguard.${1}.name" 2>/dev/null || echo "$1"
}

get_active_peer() {
    uci get "network.${1}.config" 2>/dev/null
}

# Returns 0 (true) if tunnel interface is administratively up and active.
is_tunnel_up() {
    IFACE=$1
    DISABLED=$(uci get "network.${IFACE}.disabled" 2>/dev/null)
    [ "$DISABLED" = "1" ] && return 1
    ubus call "network.interface.${IFACE}" status > /dev/null 2>&1 || return 1
    UP=$(ubus call "network.interface.${IFACE}" status 2>/dev/null | grep '"up":' | grep -c 'true')
    [ "$UP" -gt 0 ] && return 0
    return 1
}

get_handshake_age() {
    HANDSHAKE=$(wg show "$1" latest-handshakes 2>/dev/null \
        | awk '{print $2}' | head -n1)
    if [ -z "$HANDSHAKE" ] || [ "$HANDSHAKE" = "0" ]; then
        echo 9999
        return
    fi
    echo $(( $(date +%s) - HANDSHAKE ))
}


# --- Handshake polling --------------------------------------------------------
# Polls every HANDSHAKE_POLL_INTERVAL seconds until fresh or timeout.
# Outputs seconds taken, or the string 'timeout'.

wait_for_handshake() {
    WG_IF=$1
    START=$(date +%s)
    DEADLINE=$((START + POST_SWITCH_HANDSHAKE_TIMEOUT))

    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        AGE=$(get_handshake_age "$WG_IF")
        if [ "$AGE" -lt "$HANDSHAKE_TIMEOUT" ]; then
            echo $(( $(date +%s) - START ))
            return 0
        fi
        sleep "$HANDSHAKE_POLL_INTERVAL"
    done

    echo "timeout"
    return 1
}


# --- Ping verification --------------------------------------------------------

ping_through_tunnel() {
    WG_IF=$1
    ROUTE_TABLE=$2

    if [ "$DRY_RUN" = "1" ]; then
        log_dryrun "Would ping ${PING_TARGET} through tunnel '${WG_IF}' (table: ${ROUTE_TABLE:-none})"
        return 0
    fi

    if [ -n "$ROUTE_TABLE" ]; then
        log_verbose "Pinging ${PING_TARGET} via routing table ${ROUTE_TABLE}"
        ip route exec table "$ROUTE_TABLE" \
            ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_TARGET" \
            > /dev/null 2>&1 && return 0
        log_verbose "Table-based ping unavailable, trying interface-bound ping"
    fi

    log_verbose "Pinging ${PING_TARGET} bound to interface ${WG_IF}"
    ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -I "$WG_IF" "$PING_TARGET" \
        > /dev/null 2>&1 && return 0

    return 1
}


# --- Cooldown helpers ---------------------------------------------------------

set_peer_cooldown() {
    if [ "$DRY_RUN" = "1" ]; then
        log_dryrun "Would set cooldown on peer '$(get_peer_name $2)' for ${PEER_COOLDOWN}s"
        return
    fi
    echo "$(date +%s)" > "${STATE_DIR}/${1}.cooldown.${2}"
    log_verbose "Peer '$(get_peer_name $2)' on '${1}' cooling down for ${PEER_COOLDOWN}s"
}

peer_in_cooldown() {
    # If --ignore-cooldown is active, always report no cooldown
    [ "$FLAG_IGNORE_COOLDOWN" = "1" ] && return 1

    COOLDOWN_FILE="${STATE_DIR}/${1}.cooldown.${2}"
    [ ! -f "$COOLDOWN_FILE" ] && return 1
    ELAPSED=$(( $(date +%s) - $(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0) ))
    if [ "$ELAPSED" -ge "$PEER_COOLDOWN" ]; then
        rm -f "$COOLDOWN_FILE"
        return 1
    fi
    return 0
}


# --- Grace period helpers -----------------------------------------------------

set_grace_period() {
    if [ "$DRY_RUN" = "1" ]; then
        log_dryrun "Would set post-switch grace period on tunnel '${1}' (${POST_SWITCH_GRACE}s)"
        return
    fi
    echo "$(date +%s)" > "${STATE_DIR}/${1}.grace"
}

in_grace_period() {
    GRACE_FILE="${STATE_DIR}/${1}.grace"
    [ ! -f "$GRACE_FILE" ] && return 1
    ELAPSED=$(( $(date +%s) - $(cat "$GRACE_FILE" 2>/dev/null || echo 0) ))
    if [ "$ELAPSED" -ge "$POST_SWITCH_GRACE" ]; then
        rm -f "$GRACE_FILE"
        return 1
    fi
    REMAINING=$((POST_SWITCH_GRACE - ELAPSED))
    log_verbose "Tunnel '${1}': grace period (${REMAINING}s remaining)"
    return 0
}


# --- Rotation state helpers ---------------------------------------------------

set_last_rotate() {
    [ "$DRY_RUN" = "1" ] && return
    echo "$(date +%s)" > "${STATE_DIR}/${1}.last_rotate"
}

# Returns 0 if a scheduled rotation is due for this tunnel.
# ROTATE_INTERVAL is in hours (0 = disabled); ROTATE_AT is HH:MM or ''.
rotation_due() {
    IFACE=$1
    INTERVAL_HOURS=$2
    ROTATE_AT=$3

    NOW=$(date +%s)
    LAST=$(cat "${STATE_DIR}/${IFACE}.last_rotate" 2>/dev/null || echo 0)

    # Interval-based check
    if [ -n "$INTERVAL_HOURS" ] && [ "$INTERVAL_HOURS" -gt 0 ]; then
        INTERVAL_SECS=$((INTERVAL_HOURS * 3600))
        if [ $((NOW - LAST)) -ge "$INTERVAL_SECS" ]; then
            log_verbose "Tunnel '${IFACE}': rotation due (interval ${INTERVAL_HOURS}h elapsed)"
            return 0
        fi
    fi

    # Time-of-day check.
    # Guard: won't re-fire within 1 hour of the last rotation, so multiple
    # cron ticks within the target minute don't each trigger a rotation.
    if [ -n "$ROTATE_AT" ]; then
        CURRENT_TIME=$(date +%H:%M)
        ELAPSED_SINCE=$((NOW - LAST))
        if [ "$CURRENT_TIME" = "$ROTATE_AT" ] && [ "$ELAPSED_SINCE" -gt 3600 ]; then
            log_verbose "Tunnel '${IFACE}': rotation due (time-of-day ${ROTATE_AT} matched)"
            return 0
        fi
    fi

    return 1
}

# Selects the next peer in sequential pool order for rotation.
# Skips peers in cooldown (unless --ignore-cooldown is active).
# Does not skip back to the current peer — if only it is left, returns empty.
get_next_rotation_peer() {
    IFACE=$1
    CURRENT=$2
    shift 2
    POOL="$*"

    # Build ordered list: peers after current first, then peers before, wrapping around
    AFTER=''
    BEFORE=''
    FOUND=0
    for PEER in $POOL; do
        if [ "$PEER" = "$CURRENT" ]; then
            FOUND=1
            continue
        fi
        [ "$FOUND" = "1" ] && AFTER="$AFTER $PEER" || BEFORE="$BEFORE $PEER"
    done
    ORDERED="$AFTER $BEFORE"

    for PEER in $ORDERED; do
        if peer_in_cooldown "$IFACE" "$PEER"; then
            REMAINING=$((PEER_COOLDOWN - ( $(date +%s) - $(cat "${STATE_DIR}/${IFACE}.cooldown.${PEER}" 2>/dev/null || echo 0) )))
            log_verbose "Rotation: skipping '$(get_peer_name $PEER)' — cooldown ${REMAINING}s remaining"
            continue
        fi
        echo "$PEER"
        return
    done

    echo ""
}


# --- Switch peer --------------------------------------------------------------
# Switches a tunnel to a new peer, polls for handshake, then pings.
# Returns 0 on success, 1 if ping verification fails.
# SWITCH_REASON: 'failover', 'rotation', 'exercise', 'exercise-revert', 'revert'

switch_peer() {
    IFACE=$1
    WG_IF=$2
    NEW_PEER=$3
    OLD_NAME=$4
    ROUTE_TABLE=$5
    SWITCH_REASON=${6:-failover}
    NEW_NAME=$(get_peer_name "$NEW_PEER")

    log_change "Tunnel '${IFACE}': [${SWITCH_REASON}] '${OLD_NAME}' -> '${NEW_NAME}'"

    do_exec uci set "network.${IFACE}.config=${NEW_PEER}"
    do_exec uci commit network
    do_exec ubus call "network.interface.${IFACE}" down
    do_exec sleep 3
    do_exec ubus call "network.interface.${IFACE}" up

    [ "$DRY_RUN" = "0" ] && echo "$NEW_PEER" > "${STATE_DIR}/${IFACE}.active"

    if [ "$PING_VERIFY" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log_dryrun "Would poll handshake (max ${POST_SWITCH_HANDSHAKE_TIMEOUT}s) then ping ${PING_TARGET}"
            set_grace_period "$IFACE"
            return 0
        fi

        log_info "Tunnel '${IFACE}': waiting for handshake with '${NEW_NAME}'..."
        HANDSHAKE_RESULT=$(wait_for_handshake "$WG_IF")

        if [ "$HANDSHAKE_RESULT" = "timeout" ]; then
            log_warn "Tunnel '${IFACE}': handshake not seen within ${POST_SWITCH_HANDSHAKE_TIMEOUT}s — waiting ${POST_SWITCH_DELAY}s before pinging anyway"
            sleep "$POST_SWITCH_DELAY"
        else
            log_info "Tunnel '${IFACE}': handshake established in ${HANDSHAKE_RESULT}s"
        fi

        log_verbose "Tunnel '${IFACE}': running ping verification (${PING_COUNT} pings to ${PING_TARGET})"

        if ping_through_tunnel "$WG_IF" "$ROUTE_TABLE"; then
            log_change "Tunnel '${IFACE}': ping verification PASSED — '${NEW_NAME}' is working"
            set_grace_period "$IFACE"
            return 0
        else
            log_error "Tunnel '${IFACE}': ping verification FAILED — '${NEW_NAME}' is not routing traffic"
            set_peer_cooldown "$IFACE" "$NEW_PEER"
            return 1
        fi
    else
        log_verbose "Tunnel '${IFACE}': ping verification disabled — assuming '${NEW_NAME}' is OK"
        set_grace_period "$IFACE"
        return 0
    fi
}


# --- Find next available peer (failover) --------------------------------------

get_next_available_peer() {
    IFACE=$1
    CURRENT=$2
    shift 2
    POOL="$*"

    AFTER=''
    BEFORE=''
    FOUND=0
    for PEER in $POOL; do
        if [ "$PEER" = "$CURRENT" ]; then
            FOUND=1
            continue
        fi
        [ "$FOUND" = "1" ] && AFTER="$AFTER $PEER" || BEFORE="$BEFORE $PEER"
    done
    ORDERED="$AFTER $BEFORE"

    ATTEMPTS=0
    for PEER in $ORDERED; do
        [ "$MAX_FAILOVER_ATTEMPTS" -gt 0 ] && [ "$ATTEMPTS" -ge "$MAX_FAILOVER_ATTEMPTS" ] && break
        ATTEMPTS=$((ATTEMPTS + 1))

        if peer_in_cooldown "$IFACE" "$PEER"; then
            REMAINING=$((PEER_COOLDOWN - ( $(date +%s) - $(cat "${STATE_DIR}/${IFACE}.cooldown.${PEER}" 2>/dev/null || echo 0) )))
            log_verbose "Skipping '$(get_peer_name $PEER)' — cooldown ${REMAINING}s remaining"
            continue
        fi

        echo "$PEER"
        return
    done

    echo ""
}


# =============================================================================
# STATUS subcommand
# =============================================================================

cmd_status() {
    INTERACTIVE=1
    echo ""
    echo "============================================"
    echo "  wg_failover.sh v1.0.0 -- Tunnel Status"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================"

    if [ -f "$LOCKFILE" ]; then
        LOCKED_PID=$(cat "$LOCKFILE" 2>/dev/null)
        if [ -n "$LOCKED_PID" ] && kill -0 "$LOCKED_PID" 2>/dev/null; then
            echo "  Lock: active (PID ${LOCKED_PID} is running)"
        else
            echo "  Lock: stale (PID ${LOCKED_PID} no longer exists)"
        fi
    else
        echo "  Lock: none (no run in progress)"
    fi

    BLANK_KEYWORD_SEEN=0

    i=1
    while [ "$i" -le "$TUNNEL_COUNT" ]; do
        eval "IFACE=\$TUNNEL_${i}_IFACE"
        eval "WG_IF=\$TUNNEL_${i}_WG_IF"
        eval "LABEL=\$TUNNEL_${i}_LABEL"
        eval "KEYWORD=\$TUNNEL_${i}_KEYWORD"
        eval "ROUTE_TABLE=\$TUNNEL_${i}_ROUTE_TABLE"
        eval "ENABLED=\$TUNNEL_${i}_ENABLED"
        eval "ROTATE_INTERVAL=\$TUNNEL_${i}_ROTATE_INTERVAL"
        eval "ROTATE_AT=\$TUNNEL_${i}_ROTATE_AT"

        echo ""
        echo "  [$i] $LABEL"
        echo "  Interface : $IFACE"

        if [ "$ENABLED" != "1" ]; then
            echo "  Monitoring: DISABLED"
            i=$((i + 1))
            continue
        fi

        if ! is_tunnel_up "$IFACE"; then
            echo "  Status    : TUNNEL IS OFF (not monitoring)"
            i=$((i + 1))
            continue
        fi

        ACTIVE_PEER=$(get_active_peer "$IFACE")
        ACTIVE_NAME=$(get_peer_name "$ACTIVE_PEER")
        AGE=$(get_handshake_age "$WG_IF")

        if [ -z "$KEYWORD" ]; then
            if [ "$BLANK_KEYWORD_SEEN" = "1" ]; then
                echo "  Keyword   : (blank) -- SKIPPED: only one blank-keyword tunnel is allowed"
                i=$((i + 1))
                continue
            fi
            POOL=$(get_peers_excluding_other_keywords "$i")
            KEYWORD_DESC="(blank -- all unclaimed peers)"
            BLANK_KEYWORD_SEEN=1
        else
            POOL=$(get_peers_for_keyword "$KEYWORD")
            KEYWORD_DESC="'$KEYWORD'"
        fi

        POOL_COUNT=$(echo "$POOL" | wc -w)

        if [ "$AGE" -eq 9999 ]; then
            HEALTH="NO HANDSHAKE"
        elif [ "$AGE" -gt "$HANDSHAKE_TIMEOUT" ]; then
            HEALTH="STALE -- ${AGE}s (threshold: ${HANDSHAKE_TIMEOUT}s)"
        else
            HEALTH="OK -- ${AGE}s ago"
        fi

        GRACE_NOTE=""
        in_grace_period "$IFACE" && GRACE_NOTE=" [post-switch grace period active]"

        echo "  Active    : $ACTIVE_NAME ($ACTIVE_PEER)"
        echo "  Handshake : $HEALTH$GRACE_NOTE"
        echo "  Keyword   : $KEYWORD_DESC"
        echo "  Route tbl : ${ROUTE_TABLE:-not set (interface-bound ping fallback)}"
        echo "  Peer pool : $POOL_COUNT peers"

        for PEER in $POOL; do
            PNAME=$(get_peer_name "$PEER")
            MARKERS=""
            [ "$PEER" = "$ACTIVE_PEER" ] && MARKERS="${MARKERS} [ACTIVE]"
            if peer_in_cooldown "$IFACE" "$PEER"; then
                REMAINING=$((PEER_COOLDOWN - ( $(date +%s) - $(cat "${STATE_DIR}/${IFACE}.cooldown.${PEER}" 2>/dev/null || echo 0) )))
                MARKERS="${MARKERS} [COOLDOWN: ${REMAINING}s]"
            fi
            echo "    . $PNAME ($PEER)$MARKERS"
        done

        # Rotation status line
        ROTATE_DESC="disabled"
        if [ -n "$ROTATE_INTERVAL" ] && [ "$ROTATE_INTERVAL" -gt 0 ] && [ -n "$ROTATE_AT" ]; then
            ROTATE_DESC="every ${ROTATE_INTERVAL}h or at ${ROTATE_AT}"
        elif [ -n "$ROTATE_INTERVAL" ] && [ "$ROTATE_INTERVAL" -gt 0 ]; then
            ROTATE_DESC="every ${ROTATE_INTERVAL}h"
        elif [ -n "$ROTATE_AT" ]; then
            ROTATE_DESC="daily at ${ROTATE_AT}"
        fi

        if [ "$ROTATE_DESC" != "disabled" ]; then
            LAST_ROT=$(cat "${STATE_DIR}/${IFACE}.last_rotate" 2>/dev/null || echo 0)
            if [ "$LAST_ROT" = "0" ]; then
                ROTATE_STATUS="never rotated"
            else
                ELAPSED_ROT=$(( $(date +%s) - LAST_ROT ))
                # date -d is GNU; date -r is BSD/BusyBox — try both
                LAST_ROT_FMT=$(date -d "@${LAST_ROT}" '+%Y-%m-%d %H:%M' 2>/dev/null \
                    || date -r "$LAST_ROT" '+%Y-%m-%d %H:%M' 2>/dev/null \
                    || echo "ts=${LAST_ROT}")
                ROTATE_STATUS="last rotated ${LAST_ROT_FMT} (${ELAPSED_ROT}s ago)"
            fi
            echo "  Rotation  : $ROTATE_DESC -- $ROTATE_STATUS"
        else
            echo "  Rotation  : $ROTATE_DESC"
        fi

        if [ "$PING_VERIFY" = "1" ]; then
            printf "  Ping test : "
            if ping_through_tunnel "$WG_IF" "$ROUTE_TABLE"; then
                echo "PASS (${PING_TARGET} reachable through tunnel)"
            else
                echo "FAIL (${PING_TARGET} not reachable through tunnel)"
            fi
        fi

        i=$((i + 1))
    done

    echo ""
    echo "  Ping verify : $([ "$PING_VERIFY" = "1" ] && echo "enabled (target: ${PING_TARGET})" || echo "disabled")"
    echo "  Log file    : ${LOG_FILE:-disabled}"
    echo "  State dir   : $STATE_DIR"
    echo "  Webhook     : ${WEBHOOK_URL:-disabled}"
    echo "============================================"
    echo ""
}


# =============================================================================
# RESET subcommand
# =============================================================================

cmd_reset() {
    INTERACTIVE=1
    echo "Clearing all wg_failover state (cooldowns, grace periods, run timer, rotation timestamps, lockfile)..."
    rm -f "${STATE_DIR}/"* 2>/dev/null
    echo "Done. Peer selections are unchanged -- only monitoring state was reset."
    echo "The next cron run will perform a fresh check immediately."
}


# =============================================================================
# EXERCISE mode  (--exercise [label])
# =============================================================================
# Performs a verified forward switch then a verified return switch on each
# tunnel. Always reverts — the point is to test the mechanism, not change state.
# Respects --ignore-cooldown and --dry-run. Webhooks suppressed. Log not written.

run_exercise_tunnel() {
    IFACE=$1
    WG_IF=$2
    LABEL=$3
    ROUTE_TABLE=$4
    POOL=$5

    echo ""
    echo "  +------------------------------------------"
    echo "  | Exercise: $LABEL"
    echo "  +------------------------------------------"

    # --- Pre-flight -----------------------------------------------------------

    if ! is_tunnel_up "$IFACE"; then
        test_fail "Tunnel interface '${IFACE}' is not up -- cannot test"
        return 1
    fi
    test_pass "Tunnel interface '${IFACE}' is up"

    POOL_COUNT=$(echo "$POOL" | wc -w)
    if [ "$POOL_COUNT" -lt 2 ]; then
        test_fail "Only 1 peer in pool -- need at least 2 to exercise failover"
        return 1
    fi
    test_info "Peer pool contains $POOL_COUNT peers"

    ORIGINAL_PEER=$(get_active_peer "$IFACE")
    ORIGINAL_NAME=$(get_peer_name "$ORIGINAL_PEER")
    test_info "Original peer: $ORIGINAL_NAME ($ORIGINAL_PEER)"

    UCI_PEER=$(uci get "network.${IFACE}.config" 2>/dev/null)
    if [ "$UCI_PEER" = "$ORIGINAL_PEER" ] || [ "$DRY_RUN" = "1" ]; then
        test_pass "Router confirms active peer: $ORIGINAL_NAME"
    else
        test_fail "Router reports different peer (expected '$ORIGINAL_PEER', got '$UCI_PEER')"
    fi

    # Pick the first peer in the pool that isn't the current one.
    # Exercise always ignores cooldowns so there's always a candidate to test with.
    NEXT_PEER=''
    for PEER in $POOL; do
        [ "$PEER" != "$ORIGINAL_PEER" ] && NEXT_PEER="$PEER" && break
    done

    if [ -z "$NEXT_PEER" ]; then
        test_fail "Could not find an alternative peer to switch to"
        return 1
    fi
    NEXT_NAME=$(get_peer_name "$NEXT_PEER")
    test_info "Will switch to: $NEXT_NAME ($NEXT_PEER)"

    # --- Forward switch -------------------------------------------------------

    echo ""
    test_info "--- Forward switch: $ORIGINAL_NAME -> $NEXT_NAME ---"

    if switch_peer "$IFACE" "$WG_IF" "$NEXT_PEER" "$ORIGINAL_NAME" "$ROUTE_TABLE" "exercise"; then
        REPORTED=$(uci get "network.${IFACE}.config" 2>/dev/null)
        if [ "$REPORTED" = "$NEXT_PEER" ] || [ "$DRY_RUN" = "1" ]; then
            test_pass "Forward switch to '$NEXT_NAME' succeeded"
        else
            test_fail "Router still reports old peer after forward switch (got '$REPORTED')"
        fi
    else
        test_fail "Forward switch to '$NEXT_NAME' failed ping verification"
    fi

    # --- Return switch --------------------------------------------------------

    echo ""
    test_info "--- Return switch: $NEXT_NAME -> $ORIGINAL_NAME ---"

    if switch_peer "$IFACE" "$WG_IF" "$ORIGINAL_PEER" "$NEXT_NAME" "$ROUTE_TABLE" "exercise-revert"; then
        REPORTED=$(uci get "network.${IFACE}.config" 2>/dev/null)
        if [ "$REPORTED" = "$ORIGINAL_PEER" ] || [ "$DRY_RUN" = "1" ]; then
            test_pass "Tunnel restored to original peer: $ORIGINAL_NAME"
        else
            test_fail "Router does not show original peer after return switch (got '$REPORTED')"
            test_warn "IMPORTANT: tunnel may be left on the wrong peer -- check manually"
        fi
    else
        test_fail "Return switch to '$ORIGINAL_NAME' failed ping verification"
        test_warn "IMPORTANT: tunnel may be left on '$NEXT_NAME' -- check manually"
    fi

    echo ""
}

cmd_exercise() {
    TEST_PASS=0
    TEST_FAIL=0

    echo ""
    echo "============================================"
    echo "  wg_failover.sh v1.0.0 -- Exercise Mode"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    if [ -n "$FLAG_EXERCISE_LABEL" ]; then
        echo "  Scope         : tunnel '$FLAG_EXERCISE_LABEL' only"
    else
        echo "  Scope         : all enabled tunnels"
    fi
    [ "$FLAG_IGNORE_COOLDOWN" = "1" ] && echo "  Cooldown      : BYPASSED (--ignore-cooldown)"
    [ "$DRY_RUN" = "1" ]             && echo "  Mode          : DRY RUN -- no real changes"
    echo "  Note          : webhooks suppressed, log not written"
    echo "============================================"

    BLANK_KEYWORD_SEEN=0
    TUNNELS_TESTED=0

    i=1
    while [ "$i" -le "$TUNNEL_COUNT" ]; do
        eval "IFACE=\$TUNNEL_${i}_IFACE"
        eval "WG_IF=\$TUNNEL_${i}_WG_IF"
        eval "LABEL=\$TUNNEL_${i}_LABEL"
        eval "KEYWORD=\$TUNNEL_${i}_KEYWORD"
        eval "ROUTE_TABLE=\$TUNNEL_${i}_ROUTE_TABLE"
        eval "ENABLED=\$TUNNEL_${i}_ENABLED"

        if [ -n "$FLAG_EXERCISE_LABEL" ] && [ "$FLAG_EXERCISE_LABEL" != "$LABEL" ]; then
            i=$((i + 1))
            continue
        fi

        if [ "$ENABLED" != "1" ]; then
            test_info "Tunnel '$LABEL': monitoring disabled -- skipping"
            i=$((i + 1))
            continue
        fi

        if [ -z "$KEYWORD" ]; then
            if [ "$BLANK_KEYWORD_SEEN" = "1" ]; then
                test_warn "Tunnel '$LABEL': multiple blank-keyword tunnels -- skipping"
                i=$((i + 1))
                continue
            fi
            POOL=$(get_peers_excluding_other_keywords "$i")
            BLANK_KEYWORD_SEEN=1
        else
            POOL=$(get_peers_for_keyword "$KEYWORD")
        fi

        run_exercise_tunnel "$IFACE" "$WG_IF" "$LABEL" "$ROUTE_TABLE" "$POOL"
        TUNNELS_TESTED=$((TUNNELS_TESTED + 1))

        i=$((i + 1))
    done

    echo "============================================"
    echo "  Exercise Summary"
    echo "  Tunnels tested : $TUNNELS_TESTED"
    echo "  Checks passed  : $TEST_PASS"
    echo "  Checks failed  : $TEST_FAIL"
    if [ "$TEST_FAIL" -eq 0 ] && [ "$TUNNELS_TESTED" -gt 0 ]; then
        echo "  Result         : ALL PASSED"
    elif [ "$TUNNELS_TESTED" -eq 0 ]; then
        echo "  Result         : NO TUNNELS TESTED"
        [ -n "$FLAG_EXERCISE_LABEL" ] && echo "  (Label '$FLAG_EXERCISE_LABEL' not found or not enabled)"
    else
        echo "  Result         : FAILED ($TEST_FAIL check(s) did not pass)"
    fi
    echo "============================================"
    echo ""

    [ "$TEST_FAIL" -gt 0 ] && exit 1
    exit 0
}


# =============================================================================
# MAIN -- normal operation (cron, --fail, --revert)
# =============================================================================

parse_args "$@"

mkdir -p "$STATE_DIR"

# Pure subcommands — no lock needed
case "$SUBCOMMAND" in
    status) cmd_status; exit 0 ;;
    reset)  cmd_reset;  exit 0 ;;
esac

# Exercise mode acquires lock and fully exits inside cmd_exercise
if [ "$FLAG_EXERCISE" = "1" ]; then
    acquire_lock
    cmd_exercise
fi

# Dry-run / modifier banner for normal operation
if [ "$DRY_RUN" = "1" ] || [ "$FLAG_FAIL" = "1" ] || [ "$FLAG_REVERT" = "1" ] || [ "$FLAG_IGNORE_COOLDOWN" = "1" ]; then
    echo ""
    echo "========================================"
    echo "  wg_failover.sh v1.0.0"
    [ "$DRY_RUN" = "1" ]             && echo "  Mode          : DRY RUN -- no changes will be made"
    [ "$FLAG_FAIL" = "1" ]           && echo "  Simulated fail: '$FLAG_FAIL_LABEL'"
    [ "$FLAG_REVERT" = "1" ]         && echo "  Revert        : YES -- will switch back after success"
    [ "$FLAG_IGNORE_COOLDOWN" = "1" ] && echo "  Cooldown      : BYPASSED"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo ""
fi

acquire_lock

# Throttle check — skipped when --fail is active so it always runs immediately
if [ "$DRY_RUN" = "0" ] && [ "$FLAG_FAIL" = "0" ]; then
    LAST_RUN_FILE="${STATE_DIR}/last_run"
    NOW=$(date +%s)

    if [ -f "$LAST_RUN_FILE" ]; then
        ELAPSED=$(( NOW - $(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0) ))
        if [ "$ELAPSED" -lt "$CHECK_INTERVAL" ]; then
            log_verbose "Skipping -- ${ELAPSED}s since last run (interval: ${CHECK_INTERVAL}s)"
            exit 0
        fi
    fi

    echo "$NOW" > "$LAST_RUN_FILE"
fi

DRYFLAG=""
[ "$DRY_RUN" = "1" ]             && DRYFLAG="$DRYFLAG [DRY RUN]"
[ "$FLAG_FAIL" = "1" ]           && DRYFLAG="$DRYFLAG [SIMULATED FAIL: ${FLAG_FAIL_LABEL}]"
[ "$FLAG_IGNORE_COOLDOWN" = "1" ] && DRYFLAG="$DRYFLAG [IGNORE COOLDOWN]"
[ "$FLAG_REVERT" = "1" ]         && DRYFLAG="$DRYFLAG [REVERT ON SWITCH]"
log_verbose "=== Check started (PID $$)${DRYFLAG} ==="

BLANK_KEYWORD_SEEN=0

i=1
while [ "$i" -le "$TUNNEL_COUNT" ]; do

    eval "IFACE=\$TUNNEL_${i}_IFACE"
    eval "WG_IF=\$TUNNEL_${i}_WG_IF"
    eval "LABEL=\$TUNNEL_${i}_LABEL"
    eval "KEYWORD=\$TUNNEL_${i}_KEYWORD"
    eval "ROUTE_TABLE=\$TUNNEL_${i}_ROUTE_TABLE"
    eval "ENABLED=\$TUNNEL_${i}_ENABLED"
    eval "ROTATE_INTERVAL=\$TUNNEL_${i}_ROTATE_INTERVAL"
    eval "ROTATE_AT=\$TUNNEL_${i}_ROTATE_AT"

    if [ "$ENABLED" != "1" ]; then
        log_verbose "Tunnel '${LABEL}': monitoring disabled -- skipping"
        i=$((i + 1))
        continue
    fi

    if ! is_tunnel_up "$IFACE"; then
        log_verbose "Tunnel '${LABEL}' (${IFACE}): interface is off -- skipping"
        i=$((i + 1))
        continue
    fi

    if in_grace_period "$IFACE"; then
        i=$((i + 1))
        continue
    fi

    if [ -z "$KEYWORD" ]; then
        if [ "$BLANK_KEYWORD_SEEN" = "1" ]; then
            log_error "Tunnel '${LABEL}': multiple blank-keyword tunnels -- only one allowed, skipping"
            i=$((i + 1))
            continue
        fi
        POOL=$(get_peers_excluding_other_keywords "$i")
        log_verbose "Tunnel '${LABEL}': blank keyword -- using all unclaimed peers as pool"
        BLANK_KEYWORD_SEEN=1
    else
        POOL=$(get_peers_for_keyword "$KEYWORD")
    fi

    POOL_COUNT=$(echo "$POOL" | wc -w)

    if [ -z "$POOL" ]; then
        if [ -z "$KEYWORD" ]; then
            log_error "Tunnel '${LABEL}' (${IFACE}): no unclaimed peers available"
        else
            log_error "Tunnel '${LABEL}' (${IFACE}): no peers found matching keyword '${KEYWORD}'"
        fi
        i=$((i + 1))
        continue
    fi

    if [ "$POOL_COUNT" -lt 2 ]; then
        log_verbose "Tunnel '${LABEL}' (${IFACE}): only 1 peer in pool -- failover not possible"
        i=$((i + 1))
        continue
    fi

    ACTIVE_PEER=$(get_active_peer "$IFACE")
    ACTIVE_NAME=$(get_peer_name "$ACTIVE_PEER")

    # -------------------------------------------------------------------------
    # Scheduled rotation check
    # Runs before handshake/failure logic. Skipped during --fail runs.
    # -------------------------------------------------------------------------
    if [ "$FLAG_FAIL" = "0" ] && rotation_due "$IFACE" "$ROTATE_INTERVAL" "$ROTATE_AT"; then
        log_change "Tunnel '${LABEL}' (${IFACE}): scheduled rotation -- current peer: '${ACTIVE_NAME}'"

        NEXT_ROT_PEER=$(get_next_rotation_peer "$IFACE" "$ACTIVE_PEER" $POOL)

        if [ -z "$NEXT_ROT_PEER" ]; then
            log_warn "Tunnel '${LABEL}': all peers in cooldown -- skipping scheduled rotation"
            # Record timestamp anyway so we don't hammer this check every minute
            set_last_rotate "$IFACE"
        else
            NEXT_ROT_NAME=$(get_peer_name "$NEXT_ROT_PEER")
            if switch_peer "$IFACE" "$WG_IF" "$NEXT_ROT_PEER" "$ACTIVE_NAME" "$ROUTE_TABLE" "rotation"; then
                set_last_rotate "$IFACE"
                send_webhook "$LABEL" "$ACTIVE_NAME" "$NEXT_ROT_NAME" "rotated"
                log_info "Tunnel '${LABEL}': rotation complete -- now on '${NEXT_ROT_NAME}'"
            else
                log_error "Tunnel '${LABEL}': rotation peer '${NEXT_ROT_NAME}' failed ping verification -- staying on '${ACTIVE_NAME}'"
                send_webhook "$LABEL" "$ACTIVE_NAME" "$NEXT_ROT_NAME" "ping_failed"
                # Still record a rotate timestamp so we don't immediately retry
                set_last_rotate "$IFACE"
            fi
        fi

        i=$((i + 1))
        continue
    fi

    # -------------------------------------------------------------------------
    # Handshake / failure check
    # -------------------------------------------------------------------------

    SIMULATE_THIS=0
    [ "$FLAG_FAIL" = "1" ] && [ "$FLAG_FAIL_LABEL" = "$LABEL" ] && SIMULATE_THIS=1

    if [ "$SIMULATE_THIS" = "1" ]; then
        AGE=9999
        log_change "Tunnel '${LABEL}': SIMULATED FAILURE -- treating as stale"
    else
        AGE=$(get_handshake_age "$WG_IF")
        log_verbose "Tunnel '${LABEL}': peer='${ACTIVE_NAME}' handshake_age=${AGE}s"
    fi

    if [ "$AGE" -le "$HANDSHAKE_TIMEOUT" ]; then
        rm -f "${STATE_DIR}/${IFACE}.cooldown.${ACTIVE_PEER}" 2>/dev/null
        log_info "Tunnel '${LABEL}': OK -- '${ACTIVE_NAME}' (${AGE}s)"
        i=$((i + 1))
        continue
    fi

    log_change "Tunnel '${LABEL}' (${IFACE}): stale handshake (${AGE}s > ${HANDSHAKE_TIMEOUT}s) -- failing over"
    set_peer_cooldown "$IFACE" "$ACTIVE_PEER"

    CURRENT_PEER="$ACTIVE_PEER"
    CURRENT_NAME="$ACTIVE_NAME"
    SWITCHED_TO_PEER=""
    SWITCHED_TO_NAME=""

    while true; do
        NEXT_PEER=$(get_next_available_peer "$IFACE" "$CURRENT_PEER" $POOL)

        if [ -z "$NEXT_PEER" ]; then
            log_error "Tunnel '${LABEL}': ALL peers exhausted or in cooldown -- cannot failover"
            log_error "Tunnel '${LABEL}': will retry when cooldowns expire (max ${PEER_COOLDOWN}s)"
            send_webhook "$LABEL" "$ACTIVE_NAME" "none" "all_failed"
            break
        fi

        NEXT_NAME=$(get_peer_name "$NEXT_PEER")

        if switch_peer "$IFACE" "$WG_IF" "$NEXT_PEER" "$CURRENT_NAME" "$ROUTE_TABLE" "failover"; then
            SWITCHED_TO_PEER="$NEXT_PEER"
            SWITCHED_TO_NAME="$NEXT_NAME"
            send_webhook "$LABEL" "$ACTIVE_NAME" "$NEXT_NAME" "switched"
            log_info "Tunnel '${LABEL}': failover complete -- now on '${NEXT_NAME}'"
            break
        else
            log_warn "Tunnel '${LABEL}': '${NEXT_NAME}' failed ping verification -- trying next peer"
            send_webhook "$LABEL" "$CURRENT_NAME" "$NEXT_NAME" "ping_failed"
            CURRENT_PEER="$NEXT_PEER"
            CURRENT_NAME="$NEXT_NAME"
            sleep 2
        fi
    done

    # --revert: if a switch succeeded, switch back to the original peer
    if [ "$FLAG_REVERT" = "1" ] && [ -n "$SWITCHED_TO_PEER" ]; then
        log_change "Tunnel '${LABEL}': --revert active -- switching back to original peer '${ACTIVE_NAME}'"
        if switch_peer "$IFACE" "$WG_IF" "$ACTIVE_PEER" "$SWITCHED_TO_NAME" "$ROUTE_TABLE" "revert"; then
            # Clear the cooldown we placed on the original peer if the failure was simulated
            [ "$SIMULATE_THIS" = "1" ] && rm -f "${STATE_DIR}/${IFACE}.cooldown.${ACTIVE_PEER}" 2>/dev/null
            log_info "Tunnel '${LABEL}': reverted to '${ACTIVE_NAME}'"
        else
            log_error "Tunnel '${LABEL}': revert to '${ACTIVE_NAME}' failed ping verification -- remaining on '${SWITCHED_TO_NAME}'"
        fi
    fi

    i=$((i + 1))
done

log_verbose "=== Check complete (PID $$) ==="
exit 0
