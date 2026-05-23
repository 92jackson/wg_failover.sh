#!/bin/sh
# =================================================================================
VER='2.2.0'
# WireGuard VPN Tunnel Failover and Auto-Rotate for OpenWrt
#
# GitHub : https://github.com/92jackson/wg_failover.sh
# License: MIT
# =================================================================================
#
# UPGRADE NOTICE
# ---------------------------------------------------------------------------------
# v2.0.0 changes several config names and behaviors from v1.x.x.
# If updating from any v1 release, rebuild/remake your config from the v2 template
# instead of copying the old config block across unchanged.
#
# WHAT THIS SCRIPT DOES
# ---------------------------------------------------------------------------------
# Keeps your router permanently connected to a working VPN by monitoring multiple
# WireGuard tunnels and automatically switching when a tunnel loses connectivity.
#
# Designed for unattended, multi-VPN router deployments.
#
# CORE FEATURES
# ---------------------------------------------------------------------------------
# • Automatic failover between WireGuard peers
# • Optional scheduled VPN rotation (interval or time-of-day)
# • WAN pre-flight check (prevents failover during ISP outages)
# • Dual ping verification to avoid false positives
# • Persistent switch history logging
# • Optional current-peer throughput benchmarking
# • Optional webhook notifications (ntfy.sh, Gotify, custom)
# • Optional GL.iNet dashboard API sync (keeps router UI in sync after peer switch)
# • Built for GL.iNet firmware 4.x and OpenWrt
#
# INSTALL
# ---------------------------------------------------------------------------------
#   1. Copy script     :  scp wg_failover.sh root@192.168.8.1:/usr/bin/
#   2. Make executable :  chmod +x /usr/bin/wg_failover.sh
#   3. Configure       :  vi /usr/bin/wg_failover.sh   (see readme for details)
#   4. Add to cron     :  echo "* * * * * /usr/bin/wg_failover.sh" >> /etc/crontabs/root
#   5. Restart cron    :  /etc/init.d/cron restart
#
# SUBCOMMANDS
# ---------------------------------------------------------------------------------
#   status                    — print tunnel status and live ping test
#   status --json             — print status as JSON for scripting
#   status --webhook          — send status summary to webhook
#   benchmarks                — print benchmark history summary
#   benchmarks --json         — print benchmark summary as JSON
#   benchmarks --webhook      — send benchmark summary to webhook
#   reset                     — clear all state/cooldowns and exit
#   reset --keep-history      — reset state but preserve switch history files
#
# FLAGS
# ---------------------------------------------------------------------------------
#   --dry-run                 — run logic without making changes
#   --exercise [label]        — run an end-to-end switch test
#   --force-rotate [label]    — immediately rotate to the next peer
#   --fail <label>            — simulate failure on tunnel
#   --fail-wan                — simulate a WAN outage
#   --benchmark [label]       — benchmark current peer on one or more tunnels
#   --benchmark --all-peers   — benchmark all peers on one or more tunnels
#   --revert                  — after a successful switch, revert to the original peer
#   --ignore-cooldown         — skip cooldown checks when selecting the next peer
#   --switch-method <method>  — override GLINET_SWITCH_METHOD for this run
#                               values: auto | api | uci
#   --debug                   — force verbose logging and send webhooks regardless of mode
#   --version                 — print version and exit
#   --check-update            — check for updates and exit
#
#
#   --iface <iface>           — use interface name in place of label
#                               ex. --force-rotate --iface wgclient1
#
# COMPATIBILITY
# ---------------------------------------------------------------------------------
# • GL.iNet firmware 4.x (split-tunnel and global VPN mode)
# • Any OpenWrt device using UCI WireGuard + ubus network control
# =================================================================================


# =================================================================================
# =================================================================================
# USER CONFIGURATION
# =================================================================================
# =================================================================================


# =============================================================================
# QUICK START — WHAT YOU ACTUALLY NEED TO EDIT
# =============================================================================
# REQUIRED:
#   • Configure your TUNNELS DEFINITIONS (script will not run correctly without it)
#
# OPTIONAL:
#   • WAN Safety Guard (prevents exhausting peers during ISP outages)
#   • Privacy routing (when sending WAN health checks and optional webhooks)
#   • GL.iNet API integration
#   • Failover timer tuning
#   • Logging, webhook notifications, rotation, etc.
# =============================================================================


# =============================================================================
# TUNNEL DEFINITIONS (REQUIRED)
# At least one tunnel must be defined for the script to function.
#
# Use these commands to discover values before editing:
#   (a) List interfaces:            uci show network | grep '\.config='
#   (b) List peers (servers):       uci show wireguard | grep '\.name='
#   (c) Routing tables (optional):  uci show network | grep ip4table
# For more detail on setting up tunnels, see: https://github.com/92jackson/wg_failover.sh#step-2--run-discovery-commands
# =============================================================================

TUNNEL_COUNT=1                     # Number of tunnels on router AND defined below

# TUNNEL 1 EXAMPLE
TUNNEL_1_LABEL='Primary'           # Friendly name for logs/webhooks (free text)
TUNNEL_1_IFACE='wgclient1'         # (a) OpenWrt interface name
TUNNEL_1_WG_IF='wgclient1'         # (a) WireGuard kernel interface (usually same as _IFACE)
TUNNEL_1_KEYWORD=''                # (b) Substring matching this tunnel's peers. '' = all unallocated peers
TUNNEL_1_ROUTE_TABLE=''            # (c) Routing table
TUNNEL_1_FAILOVER_ENABLED=1        # 1 = Script monitors tunnel for failover
TUNNEL_1_ROTATE=''                 # CSV rotation schedule. e.g. '21600' (secs) | '03:00' (daily) | '21600,03:00,21:00' (either)
TUNNEL_1_BENCHMARK_URL=''          # Optional benchmark URL override. '' = use global BENCHMARK_URL
TUNNEL_1_PEER_ORDER='sequential'   # Peer selection order: 'sequential' (default) | 'random'

# TUNNEL 2 EXAMPLE
#TUNNEL_2_LABEL='Streaming'
#TUNNEL_2_IFACE='wgclient2'
#TUNNEL_2_WG_IF='wgclient2'
#TUNNEL_2_KEYWORD='CCwGTV'         # Example matches peers with 'CCwGTV' in their name
#TUNNEL_2_ROUTE_TABLE='1002'
#TUNNEL_2_FAILOVER_ENABLED=1
#TUNNEL_2_ROTATE='21600,03:00'     # Rotate every 6h and daily at 03:00
#TUNNEL_2_BENCHMARK_URL='http://ipv4.download.thinkbroadband.com/20MB.zip'
#TUNNEL_2_PEER_ORDER='random'      # Peer selection order: 'sequential' (default) | 'random'


# =============================================================================
# WAN SAFETY GUARD (RECOMMENDED)
# Prevents cooling down all peers when your ISP/WAN is down.
# =============================================================================

WAN_IFACE=''                          # WAN interface override. '' = auto-detect via ubus
WAN_PING_TARGETS='1.1.1.1 8.8.8.8'    # Ping targets to confirm internet access. '' = skip ping check
WAN_STABILITY_THRESHOLD=120           # Min WAN uptime (seconds) before acting on tunnel state. 0 = disabled


# =============================================================================
# PRIVACY ROUTING (OPTIONAL)
# Routes non-local outbound traffic via tunnels.
# Affects update checks, webhooks, and WAN reachability checks.
# If no usable tunnel exists, privacy-routed requests fail instead of falling back.
# If enabled with only 1 tunnel defined, WAN ping checks are bypassed because the
# script cannot distinguish WAN outage from tunnel failure in that setup. In that
# case, WAN stability relies on WAN interface uptime only.
# =============================================================================

PRIVACY_ROUTE_VIA_TUNNEL=0            # 1 = route non-local outbound traffic via tunnels


# =============================================================================
# GL.iNet DASHBOARD API (OPTIONAL)
# Enables router dashboard awareness of peer switches.
#
# If NOT used:
#   [-] Web UI will not reflect script-initiated peer changes.
#   [-] Reboots return to last GUI-selected peer.
#   [+] Failover, routing, DNS and connectivity still work normally.
#   [+] UCI switching is faster and avoids storing router credentials in this script.
#
# Only enable if dashboard sync matters to you, otherwise, leave GLINET_SWITCH_METHOD='uci'.
#
# API is automatically disabled if GLINET_ROUTER, GLINET_USER or GLINET_PASS is empty.
# =============================================================================

GLINET_SWITCH_METHOD='auto'            # auto=API then fallback | api=API only | uci=skip API
GLINET_ROUTER='http://192.168.8.1/rpc' # Router JSON-RPC endpoint, usually {ROUTER_IP}/rpc
GLINET_USER='root'                     # Router admin username
GLINET_PASS=''                         # Router admin password (use: chmod 700 /usr/bin/wg_failover.sh)


# =============================================================================
# OPTIONAL TUNING
# Tune only if you see false failovers or slow tunnel startup.
# =============================================================================

HANDSHAKE_TIMEOUT=180               # Max handshake age before failover triggers
PRE_FAILOVER_PING=1                 # 1=ping current peer before failing over | 0=act on stale handshake alone
POST_SWITCH_HANDSHAKE_TIMEOUT=45    # Time allowed for new peer handshake
POST_SWITCH_DELAY=20                # Extra grace before ping tests begin if no handshake
PEER_COOLDOWN=600                   # Time before retrying a failed peer


# =============================================================================
# NORMAL OPERATION (SAFE DEFAULTS)
# Most users can leave these unchanged.
# =============================================================================

CHECK_INTERVAL=60                   # Script run frequency (cron still every min)
PING_VERIFY=1                       # Verify internet after switching
PING_TARGETS='1.1.1.1 8.8.8.8'      # Space-separated IPs to ping through tunnel. First success = pass
PING_COUNT=3                        # Packets per test
PING_TIMEOUT=5                      # Seconds per ping
MAX_FAILOVER_ATTEMPTS=0             # 0 = try all peers before giving up
HANDSHAKE_POLL_INTERVAL=3           # How often to poll for new handshake


# =============================================================================
# LOGGING
# =============================================================================

LOG_FILE='/var/log/wg_failover.log' # Log location. '' to disable
LOG_MAX_SIZE=102400                 # Rotate log when exceeding size (bytes)
LOG_MAX_LINES=500                   # Lines kept after rotation
LOG_LEVEL=2                         # 0 silent | 1 errors | 2 normal | 3 verbose
HISTORY_MAX_LINES=500               # Switch history retention
STATE_DIR='/tmp/wg_failover'        # Runtime state


# =============================================================================
# WEBHOOK NOTIFICATIONS (OPTIONAL)
# See: https://github.com/92jackson/wg_failover.sh/tree/main#webhook-notifications
# =============================================================================

WEBHOOK_URL=''                      # Set endpoint to enable notifications. '' to disable
WEBHOOK_PROCESSOR=''                # '' = GET request, POST request: 'text' | 'json' | 'ntfy' | 'gotify'
WEBHOOK_REPEAT_INTERVAL=300         # Seconds before repeating the same event
STATUS_WEBHOOK_INTERVAL=''          # CSV schedule:
# CSV schedule format: comma-separated intervals in seconds (e.g. '21600') or HH:MM daily times
# (e.g. '03:00'), or a mix of both (e.g. '21600,03:00,15:00'). Seconds trigger repeatedly
# at that interval; HH:MM times trigger once daily within one cron tick of the scheduled time.


# =============================================================================
# BENCHMARKING (OPTIONAL)
# Uses a public test file to estimate throughput for the currently active peer.
# Run manually with --benchmark or schedule with BENCHMARK_INTERVAL.
# =============================================================================

BENCHMARK_URL='https://ash-speed.hetzner.com/100MB.bin' # Default test file URL
BENCHMARK_TIMEOUT=30                                    # Max seconds per benchmark request
BENCHMARK_HISTORY_MAX_LINES=200                         # Max benchmark history entries to retain per peer. '' = unlimited
BENCHMARK_INTERVAL=''                                   # CSV schedule (see note on STATUS_WEBHOOK_INTERVAL explaining CSV format)
BENCHMARK_INTERVAL_ALL_PEERS=0                          # 1 = sweep all peers on interval benchmark run (cycles through all, returns to original)
BENCHMARK_SWEEP_TUNNEL=''                               # Tunnel index (1, 2, ...) to use for cross-tunnel all-peer sweeps. '' = disabled
BENCHMARK_INTERVAL_WEBHOOK=0                            # 0=disabled, 1=send after every run, -1=send only on last interval CSV entry

# =================================================================================
# =================================================================================
# END OF USER CONFIGURATION — do not edit below unless you know what you're doing!
# =================================================================================
# =================================================================================



# --- Globals ------------------------------------------------------------------

DRY_RUN=0
SUBCOMMAND=''
STATUS_JSON=0
STATUS_WEBHOOK=0
BENCHMARKS_JSON=0
BENCHMARKS_WEBHOOK=0
RESET_KEEP_HISTORY=0
FLAG_FAIL=0
FLAG_FAIL_LABEL=''
FLAG_FAIL_IFACE=''
FLAG_FAIL_WAN=0
FLAG_EXERCISE=0
FLAG_EXERCISE_LABEL=''
FLAG_EXERCISE_IFACE=''
FLAG_REVERT=0
FLAG_IGNORE_COOLDOWN=0
FLAG_FORCE_ROTATE=0
FLAG_FORCE_ROTATE_LABEL=''
FLAG_FORCE_ROTATE_IFACE=''
FLAG_BENCHMARK=0
FLAG_BENCHMARK_LABEL=''
FLAG_BENCHMARK_IFACE=''
FLAG_BENCHMARK_ALL_PEERS=0
FLAG_SWITCH_METHOD=''
INTERACTIVE=0
TEST_PASS=0
TEST_FAIL=0
FLAG_DEBUG=0
FLAG_CHECK_UPDATE=0
SCHEDULE_TRIGGERED_ENTRY=""

# --- Argument parsing ---------------------------------------------------------
# Subcommands: status, benchmarks, reset
# Flags (all combinable): --dry-run, --fail [--iface] <target>, --fail-wan,
#                         --exercise [--iface] [target], --force-rotate [--iface] [target]
#                         --benchmark [--iface] [target], --revert, --ignore-cooldown
# Flags may appear in any order, before or after the subcommand.
#
# --iface is a sub-qualifier consumed immediately after --fail / --exercise /
# --force-rotate. It signals that the following argument is an interface name
# (e.g. wgclient1) rather than a tunnel label.

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
				# Check for --iface qualifier
				if [ "$1" = "--iface" ]; then
					shift
					if [ -z "$1" ] || echo "$1" | grep -q '^--'; then
						echo "Error: --fail --iface requires an interface name argument"
						echo "Example: wg_failover.sh --fail --iface wgclient1"
						exit 1
					fi
					FLAG_FAIL_IFACE="$1"
					shift
				else
					if [ -z "$1" ] || echo "$1" | grep -q '^--'; then
						echo "Error: --fail requires a tunnel label or --iface <name>"
						echo "Examples:"
						echo "  wg_failover.sh --fail \"Primary (UK)\""
						echo "  wg_failover.sh --fail --iface wgclient1"
						exit 1
					fi
					FLAG_FAIL_LABEL="$1"
					shift
				fi
				;;
			--fail-wan)
				FLAG_FAIL_WAN=1
				INTERACTIVE=1
				shift
				;;
			--exercise)
				FLAG_EXERCISE=1
				INTERACTIVE=1
				shift
				# Check for --iface qualifier first, then optional label
				if [ "$1" = "--iface" ]; then
					shift
					if [ -z "$1" ] || echo "$1" | grep -q '^--'; then
						echo "Error: --exercise --iface requires an interface name argument"
						echo "Example: wg_failover.sh --exercise --iface wgclient1"
						exit 1
					fi
					FLAG_EXERCISE_IFACE="$1"
					shift
				elif [ -n "$1" ] && ! echo "$1" | grep -q '^--'; then
					FLAG_EXERCISE_LABEL="$1"
					shift
				fi
				;;
			--force-rotate)
				FLAG_FORCE_ROTATE=1
				INTERACTIVE=1
				shift
				# Check for --iface qualifier first, then optional label
				if [ "$1" = "--iface" ]; then
					shift
					if [ -z "$1" ] || echo "$1" | grep -q '^--'; then
						echo "Error: --force-rotate --iface requires an interface name argument"
						echo "Example: wg_failover.sh --force-rotate --iface wgclient1"
						exit 1
					fi
					FLAG_FORCE_ROTATE_IFACE="$1"
					shift
				elif [ -n "$1" ] && ! echo "$1" | grep -q '^--'; then
					FLAG_FORCE_ROTATE_LABEL="$1"
					shift
				fi
				;;
			--benchmark)
				FLAG_BENCHMARK=1
				INTERACTIVE=1
				shift
				if [ "$1" = "--iface" ]; then
					shift
					if [ -z "$1" ] || echo "$1" | grep -q '^--'; then
						echo "Error: --benchmark --iface requires an interface name argument"
						echo "Example: wg_failover.sh --benchmark --iface wgclient1"
						exit 1
					fi
					FLAG_BENCHMARK_IFACE="$1"
					shift
				elif [ -n "$1" ] && ! echo "$1" | grep -q '^--'; then
					FLAG_BENCHMARK_LABEL="$1"
					shift
				fi
				# Optional --all-peers qualifier (may appear after label/iface or alone)
				if [ "$1" = "--all-peers" ]; then
					FLAG_BENCHMARK_ALL_PEERS=1
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
			--switch-method)
				shift
				if [ -z "$1" ] || echo "$1" | grep -q '^--'; then
					echo "Error: --switch-method requires a value: auto | api | uci"
					exit 1
				fi
				case "$1" in
					auto|api|uci) FLAG_SWITCH_METHOD="$1" ;;
					*)
						echo "Error: --switch-method value must be one of: auto | api | uci (got: '$1')"
						exit 1
						;;
				esac
				shift
				;;
			--debug)
				FLAG_DEBUG=1
				INTERACTIVE=1
				shift
				;;
			--check-update)
				FLAG_CHECK_UPDATE=1
				INTERACTIVE=1
				shift
				;;
			status)
				SUBCOMMAND="$1"
				shift
				# Optional --json qualifier
				if [ "$1" = "--json" ]; then
					STATUS_JSON=1
					shift
				fi
				# Optional --webhook qualifier
				if [ "$1" = "--webhook" ]; then
					STATUS_WEBHOOK=1
					shift
				fi
				;;
			benchmarks)
				SUBCOMMAND="$1"
				shift
				if [ "$1" = "--json" ]; then
					BENCHMARKS_JSON=1
					shift
				fi
				if [ "$1" = "--webhook" ]; then
					BENCHMARKS_WEBHOOK=1
					shift
				fi
				;;
			reset)
				SUBCOMMAND="$1"
				shift
				# Optional --keep-history qualifier
				if [ "$1" = "--keep-history" ]; then
					RESET_KEEP_HISTORY=1
					shift
				fi
				;;
			--version)
				echo "wg_failover.sh v${VER}"
				exit 0
				;;
			*)
				echo "Unknown argument: $1"
				echo "Usage: $0 [status [--json|--webhook]|benchmarks [--json|--webhook]|reset [--keep-history]] [--dry-run] [--version] [--debug] [--check-update]"
				echo "          [--fail [--iface] <target>] [--fail-wan]"
				echo "          [--exercise [--iface] [target]] [--force-rotate [--iface] [target]]"
				echo "          [--benchmark [--iface] [target] [--all-peers]]"
				exit 1
				;;
		esac
	done

	# Warn when --fail-wan and --fail are combined
	if [ "$FLAG_FAIL_WAN" = "1" ] && [ "$FLAG_FAIL" = "1" ]; then
		clear
		echo ""
		echo "Note: --fail-wan and --fail are combined."
		echo "  This will simulate a WAN drop DURING the failover tunnel handshake check."
		echo "  The prior WAN pre-flight checks will show as OK."
		echo ""
		echo ""
	fi
}

# --- Logging ------------------------------------------------------------------

# Colour helpers
if [ -t 1 ]; then
	_C_RESET=$(printf '\033[0m')
	_C_BOLD=$(printf '\033[1m')
	_C_DIM=$(printf '\033[2m')
	_C_WHITE=$(printf '\033[97m')
	_C_GREY=$(printf '\033[38;5;244m')
	_C_GREEN=$(printf '\033[38;5;82m')
	_C_BLUE=$(printf '\033[38;5;75m')
	_C_AMBER=$(printf '\033[38;5;214m')
	_C_LAVENDER=$(printf '\033[38;5;183m')
	_C_RED=$(printf '\033[38;5;196m')
	_C_ORANGE=$(printf '\033[38;5;202m')
	_C_GOLD=$(printf '\033[38;5;220m')
else
	_C_RESET='' _C_BOLD='' _C_DIM='' _C_WHITE=''
	_C_GREY='' _C_GREEN='' _C_BLUE='' _C_AMBER=''
	_C_LAVENDER='' _C_RED='' _C_ORANGE='' _C_GOLD=''
fi

# Prints a status section header.
status_section() {
	printf "\n${_C_BOLD}${_C_WHITE}  ── %s %s${_C_RESET}\n" "$1" \
		"$(printf '%.0s─' $(seq 1 $((42 - ${#1}))))"
}

# Prints one status row.
status_row() {
	_SR_LABEL=$1
	_SR_VALUE=$2
	_SR_COLOUR=${3:-}
	printf "  ${_C_DIM}%-14s${_C_RESET} ${_SR_COLOUR}%s${_C_RESET}\n" "$_SR_LABEL" "$_SR_VALUE"
}

# Colored inline badges for status output.
badge_ok()   { printf "${_C_GREEN}%s${_C_RESET}" "$1"; }
badge_warn() { printf "${_C_AMBER}%s${_C_RESET}" "$1"; }
badge_err()  { printf "${_C_RED}%s${_C_RESET}" "$1"; }

log() {
	LEVEL=$1
	MSG=$2
	[ "$FLAG_DEBUG" = "0" ] && [ "$LOG_LEVEL" -lt "$LEVEL" ] && return
	[ -z "$LOG_FILE" ] && return

	TIME_ONLY=$(date '+%H:%M:%S')
	FULL_TS=$(date '+%Y-%m-%d %H:%M:%S')

	# Don't write to log file in dry-run or exercise mode (unless --debug)
	_SHOULD_LOG_FILE=0
	if [ "$DRY_RUN" = "0" ] && [ "$FLAG_EXERCISE" = "0" ]; then
		if [ -z "$INTERACTIVE" ] || [ "$FLAG_DEBUG" = "1" ]; then
			_SHOULD_LOG_FILE=1
		fi
	fi

	if [ "$_SHOULD_LOG_FILE" = "1" ]; then
		if [ -f "$LOG_FILE" ]; then
			SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
			if [ "$SIZE" -gt "$LOG_MAX_SIZE" ]; then
				if [ "${LOG_MAX_LINES:-0}" -gt 0 ]; then
					# Trim to last LOG_MAX_LINES lines via tmp file
					_LOG_TMP=$(mktemp /tmp/wglog.XXXXXX)
					tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$_LOG_TMP" 2>/dev/null
					echo "[$FULL_TS] [INFO] Log trimmed to last ${LOG_MAX_LINES} lines (exceeded ${LOG_MAX_SIZE} bytes)" >> "$_LOG_TMP"
					mv "$_LOG_TMP" "$LOG_FILE"
				else
					echo "[$FULL_TS] [INFO] Log rotated (exceeded ${LOG_MAX_SIZE} bytes)" > "$LOG_FILE"
				fi
			fi
		fi
		echo "[$FULL_TS] $MSG" >> "$LOG_FILE"
	fi

	if [ -n "$INTERACTIVE" ]; then
		# Strip existing [INFO]/[CHANGE] prefix into a STATUS column
		STATUS=$(printf "%s" "$MSG" | sed -n 's/^\[\([^]]*\)\][ ]*//p')
		if [ -n "$STATUS" ]; then
			PREFIX=$(printf "%s" "$MSG" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
			test_step "$PREFIX" "$STATUS"
		else
			test_step "LOG" "$MSG"
		fi
	fi
}

log_info()    { log 2 "[INFO]   $1"; }
log_change()  { log 1 "[CHANGE] $1"; }
log_error()   { log 1 "[ERROR]  $1"; }
log_warn()    { log 1 "[WARN]   $1"; }
log_success() { log 1 "[OK]     $1"; }
log_fail()    { log 1 "[FAIL]   $1"; }
log_verbose() { log 3 "[DEBUG]  $1"; }
log_dryrun()  {
	TIME_ONLY=$(date '+%H:%M:%S')
	printf "  [%s] ${_C_AMBER}%-8s${_C_RESET} %s\n" "$TIME_ONLY" "DRY-RUN" "$1"
}

# Prints one exercise-mode log step.
test_step() {
	_TS_STATUS=$1
	_TS_MSG=$2
	_TS_TIMESTAMP=$(date '+%H:%M:%S')

	case "$_TS_STATUS" in
		PASS)    _TS_COLOUR="$_C_GREEN"    ;;
		OK)      _TS_COLOUR="$_C_GREEN"    ;;
		INFO)    _TS_COLOUR="$_C_BLUE"     ;;
		WARN)    _TS_COLOUR="$_C_AMBER"    ;;
		DRY-RUN) _TS_COLOUR="$_C_LAVENDER" ;;
		ERROR)   _TS_COLOUR="$_C_RED"      ;;
		FAIL)    _TS_COLOUR="$_C_ORANGE"   ;;
		CHANGE)  _TS_COLOUR="$_C_GOLD"     ;;
		*)       _TS_COLOUR="$_C_GREY"     ;;
	esac

	printf "  [%s] ${_TS_COLOUR}%-8s${_C_RESET} %s\n" \
		"$_TS_TIMESTAMP" "$_TS_STATUS" "$_TS_MSG" >&2
}

test_pass() { TEST_PASS=$((TEST_PASS + 1)); test_step "PASS" "$1"; }
test_fail() { TEST_FAIL=$((TEST_FAIL + 1)); test_step "FAIL" "$1"; }
test_info() { test_step "INFO" "$1"; }
test_warn() { test_step "WARN" "$1"; }


# --- Dependency check ---------------------------------------------------------
# Verifies required external commands before any work starts.
# This avoids partial execution when a dependency is missing.

check_dependencies() {
	_MISSING=''
	for _CMD in uci ubus wg ip ping grep sed date curl; do
		command -v "$_CMD" > /dev/null 2>&1 || _MISSING="${_MISSING} ${_CMD}"
	done

	# GL.iNet API dependencies — only required when API switching is active
	_EFFECTIVE_METHOD="${FLAG_SWITCH_METHOD:-$GLINET_SWITCH_METHOD}"

	# If API/auto selected but credentials missing, force fallback to UCI
	if [ "$_EFFECTIVE_METHOD" = "auto" ] || [ "$_EFFECTIVE_METHOD" = "api" ]; then
		if [ -z "$GLINET_ROUTER" ] || [ -z "$GLINET_USER" ] || [ -z "$GLINET_PASS" ]; then
			FLAG_SWITCH_METHOD="uci"
			_EFFECTIVE_METHOD="uci"
		fi
	fi

	# Only check API tool dependencies if still using API after fallback
	if [ "$_EFFECTIVE_METHOD" = "auto" ] || [ "$_EFFECTIVE_METHOD" = "api" ]; then
		for _CMD in curl jsonfilter openssl; do
			command -v "$_CMD" > /dev/null 2>&1 || _MISSING="${_MISSING} ${_CMD}"
		done
	fi

	if [ -n "$_MISSING" ]; then
		echo "Error: wg_failover.sh requires the following commands which were not found:"
		for _CMD in $_MISSING; do
			echo "  missing: ${_CMD}"
		done
		echo "Install the relevant packages or check your PATH."
		exit 1
	fi
}

resolve_privacy_route_config() {
	if [ "${PRIVACY_ROUTE_VIA_TUNNEL+x}" != "x" ]; then
		PRIVACY_ROUTE_VIA_TUNNEL="${PRIVACY_ROUTE_VIA_TUNNEL:-0}"
	elif [ "${WAN_CHECK_VIA_TUNNEL+x}" = "x" ]; then
		PRIVACY_ROUTE_VIA_TUNNEL="${WAN_CHECK_VIA_TUNNEL:-0}"
	else
		PRIVACY_ROUTE_VIA_TUNNEL=0
	fi
}

privacy_route_enabled() {
	[ "${PRIVACY_ROUTE_VIA_TUNNEL:-0}" = "1" ]
}

external_curl() {
	if ! privacy_route_enabled; then
		curl "$@"
		return $?
	fi

	_EC_i=1
	while [ "$_EC_i" -le "$TUNNEL_COUNT" ]; do
		eval "_EC_IFACE=\$TUNNEL_${_EC_i}_IFACE"
		eval "_EC_WG_IF=\$TUNNEL_${_EC_i}_WG_IF"
		eval "_EC_RT=\$TUNNEL_${_EC_i}_ROUTE_TABLE"
		if is_tunnel_up "$_EC_IFACE"; then
			if [ -n "$_EC_RT" ]; then
				ip route exec table "$_EC_RT" curl "$@" && return 0
			fi
			curl --interface "$_EC_WG_IF" "$@" && return 0
		fi
		_EC_i=$(( _EC_i + 1 ))
	done
	return 1
}

check_for_update() {
	_CFU_COMMIT_URL='https://api.github.com/repos/92jackson/wg_failover.sh/commits/main'
	_CFU_RAW_URL='https://raw.githubusercontent.com/92jackson/wg_failover.sh/refs/heads/main/wg_failover.sh'
	UPDATE_CHECK_STATUS='error'
	UPDATE_REMOTE_VER=''
	UPDATE_CHECK_MESSAGE='check failed'

	if command -v jsonfilter >/dev/null 2>&1; then
		UPDATE_REMOTE_VER=$(
			external_curl -fsL --max-time 5 \
				-H "User-Agent: wg_failover.sh" \
				"$_CFU_COMMIT_URL" 2>/dev/null \
			| jsonfilter -e '@.commit.message' 2>/dev/null \
			| sed -n '1p' \
			| grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' \
			| head -n1
		)
	fi

	if [ -z "$UPDATE_REMOTE_VER" ]; then
		UPDATE_REMOTE_VER=$(
			external_curl -fsL --max-time 5 "$_CFU_RAW_URL" 2>/dev/null \
			| sed -n "3s/^VER='\([0-9][0-9.]*\)'.*/\1/p"
		)
	fi

	[ -z "$UPDATE_REMOTE_VER" ] && return 1

	if [ "$UPDATE_REMOTE_VER" = "$VER" ]; then
		UPDATE_CHECK_STATUS='current'
		UPDATE_CHECK_MESSAGE="up to date (v${VER})"
	else
		UPDATE_CHECK_STATUS='update'
		UPDATE_CHECK_MESSAGE="update available: v${UPDATE_REMOTE_VER} (current: v${VER})"
	fi
	return 0
}

cmd_check_update() {
	check_for_update >/dev/null 2>&1
	case "$UPDATE_CHECK_STATUS" in
		current)
			echo "Update check: ${UPDATE_CHECK_MESSAGE}"
			;;
		update)
			echo "Update check: ${UPDATE_CHECK_MESSAGE}"
			;;
		*)
			echo "Update check: failed"
			return 1
			;;
	esac
}


# --- Validation ---------------------------------------------------------------

validate_config() {
	if [ -z "$TUNNEL_COUNT" ] || [ "$TUNNEL_COUNT" -lt 1 ] 2>/dev/null; then
		echo "Error: TUNNEL_COUNT must be a positive integer (got: '${TUNNEL_COUNT:-<empty>}')"
		exit 1
	fi

	# Validation helpers used only during config checks.
	validate_bool_01() {
		_VB_NAME=$1
		_VB_VALUE=$2
		case "$_VB_VALUE" in
			0|1) return 0 ;;
			*)
				echo "Error: ${_VB_NAME} must be 0 or 1 (got: '${_VB_VALUE:-<empty>}')"
				return 1
				;;
		esac
	}

	validate_benchmark_webhook_mode() {
		_VBW_NAME=$1
		_VBW_VALUE=$2
		case "$_VBW_VALUE" in
			0|1|-1) return 0 ;;
			*)
				echo "Error: ${_VBW_NAME} must be 0, 1, or -1 (got: '${_VBW_VALUE:-<empty>}')"
				return 1
				;;
		esac
	}

	validate_non_negative_int() {
		_VN_NAME=$1
		_VN_VALUE=$2
		case "$_VN_VALUE" in
			''|*[!0-9]*)
				echo "Error: ${_VN_NAME} must be a non-negative integer (got: '${_VN_VALUE:-<empty>}')"
				return 1
				;;
			*)
				return 0
				;;
		esac
	}

	validate_schedule_csv() {
		_VS_NAME=$1
		_VS_CSV=$2
		[ -z "$_VS_CSV" ] && return 0

		_VS_OLDIFS=$IFS
		IFS=','
		for _VS_ENTRY in $_VS_CSV; do
			IFS=$_VS_OLDIFS
			_VS_ENTRY=$(printf '%s' "$_VS_ENTRY" | sed 's/^ *//;s/ *$//')
			if [ -z "$_VS_ENTRY" ]; then
				echo "Error: ${_VS_NAME} contains an empty schedule entry"
				return 1
			fi

			case "$_VS_ENTRY" in
				*:*)
					if ! printf '%s' "$_VS_ENTRY" | grep -Eq '^[0-9][0-9]:[0-9][0-9]$'; then
						echo "Error: ${_VS_NAME} contains invalid time '${_VS_ENTRY}' (expected HH:MM)"
						return 1
					fi
					_VS_HOUR=${_VS_ENTRY%%:*}
					_VS_MIN=${_VS_ENTRY##*:}
					if [ "$_VS_HOUR" -gt 23 ] || [ "$_VS_MIN" -gt 59 ]; then
						echo "Error: ${_VS_NAME} contains out-of-range time '${_VS_ENTRY}'"
						return 1
					fi
					;;
				*)
					if ! printf '%s' "$_VS_ENTRY" | grep -Eq '^[1-9][0-9]*$'; then
						echo "Error: ${_VS_NAME} contains invalid interval '${_VS_ENTRY}' (expected positive integer seconds)"
						return 1
					fi
					;;
			esac
			IFS=','
		done
		IFS=$_VS_OLDIFS
		return 0
	}

	validate_http_url() {
		_VU_NAME=$1
		_VU_VALUE=$2
		[ -z "$_VU_VALUE" ] && return 0
		if ! printf '%s' "$_VU_VALUE" | grep -Eq '^https?://[^[:space:]]+$'; then
			echo "Error: ${_VU_NAME} must be a http(s) URL (got: '${_VU_VALUE}')"
			return 1
		fi
	}

	resolve_privacy_route_config

	case "${GLINET_SWITCH_METHOD:-}" in
		auto|api|uci) ;;
		*)
			echo "Error: GLINET_SWITCH_METHOD must be one of: auto | api | uci (got: '${GLINET_SWITCH_METHOD:-<empty>}')"
			exit 1
			;;
	esac

	case "${WEBHOOK_PROCESSOR:-}" in
		''|get|text|json|ntfy|gotify) ;;
		*)
			echo "Error: WEBHOOK_PROCESSOR must be one of: '' | get | text | json | ntfy | gotify (got: '${WEBHOOK_PROCESSOR:-<empty>}')"
			exit 1
			;;
	esac

	validate_bool_01 "PRIVACY_ROUTE_VIA_TUNNEL" "${PRIVACY_ROUTE_VIA_TUNNEL:-0}" || exit 1
	validate_bool_01 "PRE_FAILOVER_PING" "${PRE_FAILOVER_PING:-0}" || exit 1
	validate_bool_01 "PING_VERIFY" "${PING_VERIFY:-0}" || exit 1
	validate_benchmark_webhook_mode "BENCHMARK_INTERVAL_WEBHOOK" "${BENCHMARK_INTERVAL_WEBHOOK:-0}" || exit 1
	validate_non_negative_int "WAN_STABILITY_THRESHOLD" "${WAN_STABILITY_THRESHOLD:-0}" || exit 1
	validate_non_negative_int "HANDSHAKE_TIMEOUT" "${HANDSHAKE_TIMEOUT:-0}" || exit 1
	validate_non_negative_int "POST_SWITCH_HANDSHAKE_TIMEOUT" "${POST_SWITCH_HANDSHAKE_TIMEOUT:-0}" || exit 1
	validate_non_negative_int "POST_SWITCH_DELAY" "${POST_SWITCH_DELAY:-0}" || exit 1
	validate_non_negative_int "PEER_COOLDOWN" "${PEER_COOLDOWN:-0}" || exit 1
	validate_non_negative_int "CHECK_INTERVAL" "${CHECK_INTERVAL:-0}" || exit 1
	validate_non_negative_int "PING_COUNT" "${PING_COUNT:-0}" || exit 1
	validate_non_negative_int "PING_TIMEOUT" "${PING_TIMEOUT:-0}" || exit 1
	validate_non_negative_int "MAX_FAILOVER_ATTEMPTS" "${MAX_FAILOVER_ATTEMPTS:-0}" || exit 1
	validate_non_negative_int "HANDSHAKE_POLL_INTERVAL" "${HANDSHAKE_POLL_INTERVAL:-0}" || exit 1
	validate_non_negative_int "LOG_MAX_SIZE" "${LOG_MAX_SIZE:-0}" || exit 1
	validate_non_negative_int "LOG_MAX_LINES" "${LOG_MAX_LINES:-0}" || exit 1
	validate_non_negative_int "LOG_LEVEL" "${LOG_LEVEL:-0}" || exit 1
	validate_non_negative_int "HISTORY_MAX_LINES" "${HISTORY_MAX_LINES:-0}" || exit 1
	validate_non_negative_int "WEBHOOK_REPEAT_INTERVAL" "${WEBHOOK_REPEAT_INTERVAL:-0}" || exit 1
	validate_non_negative_int "BENCHMARK_TIMEOUT" "${BENCHMARK_TIMEOUT:-0}" || exit 1
	validate_non_negative_int "BENCHMARK_HISTORY_MAX_LINES" "${BENCHMARK_HISTORY_MAX_LINES:-0}" || exit 1

	validate_schedule_csv "STATUS_WEBHOOK_INTERVAL" "$STATUS_WEBHOOK_INTERVAL" || exit 1
	validate_schedule_csv "BENCHMARK_INTERVAL" "$BENCHMARK_INTERVAL" || exit 1
	validate_http_url "GLINET_ROUTER" "$GLINET_ROUTER" || exit 1
	validate_http_url "BENCHMARK_URL" "$BENCHMARK_URL" || exit 1

	if [ -n "$BENCHMARK_SWEEP_TUNNEL" ]; then
		if ! printf '%s' "$BENCHMARK_SWEEP_TUNNEL" | grep -Eq '^[0-9]+$' || \
		   [ "$BENCHMARK_SWEEP_TUNNEL" -lt 1 ] || \
		   [ "$BENCHMARK_SWEEP_TUNNEL" -gt "$TUNNEL_COUNT" ]; then
			echo "Error: BENCHMARK_SWEEP_TUNNEL must be a tunnel index between 1 and ${TUNNEL_COUNT} (got: '${BENCHMARK_SWEEP_TUNNEL}')"
			exit 1
		fi
	fi

	_BLANK_KEYWORD_COUNT=0
	_SEEN_LABELS=''
	_SEEN_IFACES=''
	_SEEN_WG_IFS=''
	_SEEN_ROUTE_TABLES=''
	i=1
	while [ "$i" -le "$TUNNEL_COUNT" ]; do
		eval "_VC_IFACE=\$TUNNEL_${i}_IFACE"
		eval "_VC_WG_IF=\$TUNNEL_${i}_WG_IF"
		eval "_VC_LABEL=\$TUNNEL_${i}_LABEL"
		eval "_VC_KEYWORD=\$TUNNEL_${i}_KEYWORD"
		eval "_VC_ROUTE_TABLE=\$TUNNEL_${i}_ROUTE_TABLE"
		eval "_VC_FAILOVER=\$TUNNEL_${i}_FAILOVER_ENABLED"
		eval "_VC_ROTATE=\$TUNNEL_${i}_ROTATE"
		eval "_VC_BENCHMARK_URL=\$TUNNEL_${i}_BENCHMARK_URL"

		[ -z "$_VC_IFACE" ] && echo "Error: TUNNEL_${i}_IFACE is required" && exit 1
		[ -z "$_VC_WG_IF" ] && echo "Error: TUNNEL_${i}_WG_IF is required" && exit 1
		[ -z "$_VC_LABEL" ] && echo "Error: TUNNEL_${i}_LABEL is required" && exit 1
		[ -z "$_VC_FAILOVER" ] && echo "Error: TUNNEL_${i}_FAILOVER_ENABLED is required" && exit 1

		validate_bool_01 "TUNNEL_${i}_FAILOVER_ENABLED" "$_VC_FAILOVER" || exit 1
		validate_schedule_csv "TUNNEL_${i}_ROTATE" "$_VC_ROTATE" || exit 1
		validate_http_url "TUNNEL_${i}_BENCHMARK_URL" "$_VC_BENCHMARK_URL" || exit 1

		if [ -n "$_VC_ROUTE_TABLE" ] && ! printf '%s' "$_VC_ROUTE_TABLE" | grep -Eq '^[0-9]+$'; then
			echo "Error: TUNNEL_${i}_ROUTE_TABLE must be numeric or blank (got: '${_VC_ROUTE_TABLE}')"
			exit 1
		fi

		if printf '%s\n' "$_SEEN_LABELS" | grep -Fqx "$_VC_LABEL"; then
			echo "Error: duplicate tunnel label detected: '${_VC_LABEL}'"
			exit 1
		fi
		_SEEN_LABELS="${_SEEN_LABELS}
$_VC_LABEL"

		if printf '%s\n' "$_SEEN_IFACES" | grep -Fqx "$_VC_IFACE"; then
			echo "Error: duplicate TUNNEL_X_IFACE detected: '${_VC_IFACE}'"
			exit 1
		fi
		_SEEN_IFACES="${_SEEN_IFACES}
$_VC_IFACE"

		if printf '%s\n' "$_SEEN_WG_IFS" | grep -Fqx "$_VC_WG_IF"; then
			echo "Error: duplicate TUNNEL_X_WG_IF detected: '${_VC_WG_IF}'"
			exit 1
		fi
		_SEEN_WG_IFS="${_SEEN_WG_IFS}
$_VC_WG_IF"

		if [ -n "$_VC_ROUTE_TABLE" ]; then
			if printf '%s\n' "$_SEEN_ROUTE_TABLES" | grep -Fqx "$_VC_ROUTE_TABLE"; then
				echo "Error: duplicate TUNNEL_X_ROUTE_TABLE detected: '${_VC_ROUTE_TABLE}'"
				exit 1
			fi
			_SEEN_ROUTE_TABLES="${_SEEN_ROUTE_TABLES}
$_VC_ROUTE_TABLE"
		fi

		[ -z "$_VC_KEYWORD" ] && _BLANK_KEYWORD_COUNT=$(( _BLANK_KEYWORD_COUNT + 1 ))
		i=$((i + 1))
	done

	if [ "$_BLANK_KEYWORD_COUNT" -gt 1 ]; then
		echo "Error: only one tunnel may use a blank TUNNEL_X_KEYWORD"
		exit 1
	fi

}

# --- Target matching ----------------------------------------------------------
# Shared target matcher for --fail, --exercise, and --force-rotate.
# Usage: tunnel_matches_target "$LABEL" "$IFACE" "$TARGET_LABEL" "$TARGET_IFACE"
# Returns: 0 = match, 1 = no match, 2 = no filter set.

tunnel_matches_target() {
	_LABEL=$1
	_IFACE=$2
	_TARGET_LABEL=$3
	_TARGET_IFACE=$4

	# No filter set — match all tunnels
	if [ -z "$_TARGET_LABEL" ] && [ -z "$_TARGET_IFACE" ]; then
		return 2
	fi

	# Interface filter
	if [ -n "$_TARGET_IFACE" ]; then
		[ "$_IFACE" = "$_TARGET_IFACE" ] && return 0
		return 1
	fi

	# Label filter
	[ "$_LABEL" = "$_TARGET_LABEL" ] && return 0
	return 1
}

# Prints available tunnel labels and interfaces for "no match" errors.
print_available_tunnels() {
	j=1
	while [ "$j" -le "$TUNNEL_COUNT" ]; do
		eval "_L=\$TUNNEL_${j}_LABEL"
		eval "_IF=\$TUNNEL_${j}_IFACE"
		printf "    %-30s  (iface: %s)\n" "$_L" "$_IF"
		j=$((j + 1))
	done
}

# Loads standard tunnel variables for index $1 into unprefixed globals.
# Sets: IFACE WG_IF LABEL KEYWORD ROUTE_TABLE ENABLED
load_tunnel_vars() {
	eval "IFACE=\$TUNNEL_${1}_IFACE"
	eval "WG_IF=\$TUNNEL_${1}_WG_IF"
	eval "LABEL=\$TUNNEL_${1}_LABEL"
	eval "KEYWORD=\$TUNNEL_${1}_KEYWORD"
	eval "ROUTE_TABLE=\$TUNNEL_${1}_ROUTE_TABLE"
	eval "ENABLED=\$TUNNEL_${1}_FAILOVER_ENABLED"
}

# Builds POOL and POOL_COUNT for the current tunnel index $1.
# Requires LABEL and KEYWORD to already be set (via load_tunnel_vars).
# Manages BLANK_KEYWORD_SEEN guard. Returns 1 if tunnel should be skipped.
build_tunnel_pool() {
	if [ -z "$KEYWORD" ]; then
		if [ "$BLANK_KEYWORD_SEEN" = "1" ]; then
			log_error "Tunnel '${LABEL}': multiple blank-keyword tunnels -- only one allowed, skipping"
			return 1
		fi
		POOL=$(get_peers_excluding_other_keywords "$1")
		BLANK_KEYWORD_SEEN=1
	else
		POOL=$(get_peers_for_keyword "$KEYWORD")
	fi
	set -- $POOL; POOL_COUNT=$#
}

# Prints a no-match warning if a targeted command matched no enabled tunnels.
# Args: command  count  label  iface
# Prints nothing if count > 0 or no target was given.
warn_no_tunnel_match() {
	[ "$2" -gt 0 ] && return
	[ -z "$3" ] && [ -z "$4" ] && return
	echo ""
	if [ -n "$4" ]; then
		echo "Warning: --${1} --iface '${4}' did not match any enabled tunnel."
	else
		echo "Warning: --${1} label '${3}' did not match any enabled tunnel."
	fi
	echo "Available tunnels:"
	print_available_tunnels
}

# Runs state-changing commands, with dry-run support.
do_exec() {
	if [ "$DRY_RUN" = "1" ]; then
		log_dryrun "Would run: $*"
	else
		"$@"
	fi
}

# Formats a duration in seconds.
format_duration() {
	_FD_SECS=$1
	if [ "$_FD_SECS" -ge 3600 ]; then
		_FD_H=$(( _FD_SECS / 3600 ))
		_FD_M=$(( (_FD_SECS % 3600) / 60 ))
		printf '%dh %dm' "$_FD_H" "$_FD_M"
	elif [ "$_FD_SECS" -ge 60 ]; then
		_FD_M=$(( _FD_SECS / 60 ))
		_FD_S=$(( _FD_SECS % 60 ))
		printf '%dm %ds' "$_FD_M" "$_FD_S"
	else
		printf '%ds' "$_FD_SECS"
	fi
}

format_epoch_human() {
	_FEH_EPOCH=$1
	[ -z "$_FEH_EPOCH" ] && { printf 'none'; return; }
	[ "$_FEH_EPOCH" -le 0 ] 2>/dev/null && { printf 'none'; return; }
	date -d "@$_FEH_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'none'
}


# --- GL.iNet dashboard API helpers --------------------------------------------
#
# GL.iNet API helpers shared by peer switching and the status command.
#
#   glinet_api_challenge()  — Steps 1 and 2: get salt/nonce, generate hash
#                             Populates: GLINET_API_SALT, GLINET_API_NONCE,
#                                        GLINET_API_HASH, GLINET_API_RC,
#                                        GLINET_API_BODY
#   glinet_api_login()      — Step 3: exchange hash for session token
#                             Populates: GLINET_API_SESSION
#   glinet_api_switch()     — Steps 4 and 5: get_tunnel, set_tunnel
#                             Calls both helpers, then switches the peer
#
#   glinet_api_logout()     — Step 6: logout
# ------------------------------------------------------------------------------

glinet_api_challenge() {
	# Outputs (globals): GLINET_API_SALT, GLINET_API_NONCE, GLINET_API_HASH
	#                    GLINET_API_RC, GLINET_API_BODY
	GLINET_API_SALT=''
	GLINET_API_NONCE=''
	GLINET_API_HASH=''
	GLINET_API_RC=''
	GLINET_API_BODY=''

	# STEP 1 — Request login challenge
	GLINET_API_BODY=$(curl -s --max-time 10 "$GLINET_ROUTER" \
		-H 'Content-Type: application/json' \
		-d '{"jsonrpc":"2.0","id":1,"method":"challenge","params":{"username":"'"$GLINET_USER"'"}}' \
		2>/dev/null)
	GLINET_API_RC=$?

	log_verbose "GL.iNet API: challenge curl_rc=${GLINET_API_RC} body='${GLINET_API_BODY}'"

	GLINET_API_SALT=$(echo  "$GLINET_API_BODY" | jsonfilter -e '@.result.salt'  2>/dev/null)
	GLINET_API_NONCE=$(echo "$GLINET_API_BODY" | jsonfilter -e '@.result.nonce' 2>/dev/null)

	if [ -z "$GLINET_API_SALT" ] || [ -z "$GLINET_API_NONCE" ]; then
		log_warn "GL.iNet API: failed to obtain login challenge from ${GLINET_ROUTER} (curl_rc=${GLINET_API_RC})"
		return 1
	fi

	# STEP 2 — Generate login hash: sha256( user : sha512crypt(pass,salt) : nonce )
	_GC_CRYPT=$(openssl passwd -5 -salt "$GLINET_API_SALT" "$GLINET_PASS" 2>/dev/null)
	if [ -z "$_GC_CRYPT" ]; then
		log_warn "GL.iNet API: openssl passwd failed (openssl-util installed?)"
		return 1
	fi

	GLINET_API_HASH=$(printf '%s' "${GLINET_USER}:${_GC_CRYPT}:${GLINET_API_NONCE}" \
		| sha256sum 2>/dev/null | awk '{print $1}')
	if [ -z "$GLINET_API_HASH" ]; then
		log_warn "GL.iNet API: sha256sum failed"
		return 1
	fi

	return 0
}

glinet_api_login() {
	# Requires: GLINET_API_HASH (from glinet_api_challenge)
	# Outputs (global): GLINET_API_SESSION
	GLINET_API_SESSION=''

	# STEP 3 — Login. curl -i includes headers in the response body.
	# Strip \r\n from the extracted token.
	_GL_RESPONSE=$(curl -i -s --max-time 10 -X POST "$GLINET_ROUTER" \
		-H 'Content-Type: application/json' \
		-d '{"jsonrpc":"2.0","id":2,"method":"login","params":{"username":"'"$GLINET_USER"'","hash":"'"$GLINET_API_HASH"'"}}' \
		2>/dev/null)
	_GL_RC=$?

	log_verbose "GL.iNet API: login curl_rc=${_GL_RC}"
	log_verbose "GL.iNet API: login response='${_GL_RESPONSE}'"

	GLINET_API_SESSION=$(echo "$_GL_RESPONSE" \
		| grep -i 'Set-Cookie' \
		| sed -n 's/.*Admin-Token=\([^;]*\).*/\1/p' \
		| tr -d '\r\n')

	if [ -z "$GLINET_API_SESSION" ]; then
		log_warn "GL.iNet API: login failed -- no Admin-Token in response (curl_rc=${_GL_RC}, wrong password?)"
		return 1
	fi

	log_verbose "GL.iNet API: session token obtained (${#GLINET_API_SESSION} chars)"
	return 0
}

glinet_api_switch() {
	_GA_WG_IF=$1      # WireGuard kernel interface, e.g. wgclient1
	_GA_NEW_PEER=$2   # UCI peer key, e.g. peer_2001

	# Derive GL.iNet peer_id by stripping 'peer_' prefix
	_GA_PEER_ID=$(echo "$_GA_NEW_PEER" | sed 's/^peer_//')

	glinet_api_challenge || return 1
	glinet_api_login     || return 1

	_GA_SESSION="$GLINET_API_SESSION"

	# ------------------------------------------------------------------
	# STEP 4 — Fetch tunnel list and find tunnel_id + group_id for WG_IF
	# ------------------------------------------------------------------
	_GA_TUNNELS_JSON=$(curl -s --max-time 10 -X POST "$GLINET_ROUTER" \
		-H 'Content-Type: application/json' \
		-H "Cookie: Admin-Token=${_GA_SESSION}" \
		-d '{"jsonrpc":"2.0","id":3,"method":"call","params":["'"$_GA_SESSION"'","vpn-client","get_tunnel",{}]}' \
		2>/dev/null)

	log_verbose "GL.iNet API: get_tunnel body='${_GA_TUNNELS_JSON}'"

	_GA_COUNT=$(echo "$_GA_TUNNELS_JSON" \
		| jsonfilter -e '@.result.tunnels[*].tunnel_id' 2>/dev/null | wc -l)
	log_verbose "GL.iNet API: tunnel count=${_GA_COUNT}"

	_GA_TUNNEL_ID=''
	_GA_GROUP_ID=''
	_GA_IDX=0

	while [ "$_GA_IDX" -lt "$_GA_COUNT" ]; do
		_GA_VIA=$(echo "$_GA_TUNNELS_JSON" \
			| jsonfilter -e "@.result.tunnels[${_GA_IDX}].via.via" 2>/dev/null)
		log_verbose "GL.iNet API: tunnel[${_GA_IDX}] via='${_GA_VIA}'"

		# Skip empty or novpn rows
		if [ -z "$_GA_VIA" ] || [ "$_GA_VIA" = "novpn" ]; then
			_GA_IDX=$((_GA_IDX + 1))
			continue
		fi

		if [ "$_GA_VIA" = "$_GA_WG_IF" ]; then
			_GA_TUNNEL_ID=$(echo "$_GA_TUNNELS_JSON" \
				| jsonfilter -e "@.result.tunnels[${_GA_IDX}].tunnel_id"   2>/dev/null)
			_GA_GROUP_ID=$(echo "$_GA_TUNNELS_JSON" \
				| jsonfilter -e "@.result.tunnels[${_GA_IDX}].via.group_id" 2>/dev/null)
			break
		fi

		_GA_IDX=$((_GA_IDX + 1))
	done

	if [ -z "$_GA_TUNNEL_ID" ] || [ -z "$_GA_GROUP_ID" ]; then
		log_warn "GL.iNet API: could not find tunnel entry for interface '${_GA_WG_IF}' (checked ${_GA_COUNT} tunnel(s))"
		return 1
	fi

	log_verbose "GL.iNet API: matched tunnel_id=${_GA_TUNNEL_ID} group_id=${_GA_GROUP_ID} for ${_GA_WG_IF}"

	# ------------------------------------------------------------------
	# STEP 5 — Switch peer via set_tunnel
	# ------------------------------------------------------------------
	_GA_SWITCH_RESPONSE=$(curl -s --max-time 10 -X POST "$GLINET_ROUTER" \
		-H 'Content-Type: application/json' \
		-H "Cookie: Admin-Token=${_GA_SESSION}" \
		-d '{"jsonrpc":"2.0","id":4,"method":"call","params":["'"$_GA_SESSION"'","vpn-client","set_tunnel",{"via":{"type":"wireguard","group_id":'"$_GA_GROUP_ID"',"peer_id":'"$_GA_PEER_ID"'},"isTapS2s":false,"tunnel_id":'"$_GA_TUNNEL_ID"'}]}' \
		2>/dev/null)
	_GA_CURL_RC=$?

	log_verbose "GL.iNet API: set_tunnel curl_rc=${_GA_CURL_RC} body='${_GA_SWITCH_RESPONSE}'"

	if echo "$_GA_SWITCH_RESPONSE" | grep -q '"error"'; then
		_GA_ERR=$(echo "$_GA_SWITCH_RESPONSE" \
			| jsonfilter -e '@.error.message' 2>/dev/null || echo "unknown")
		log_warn "GL.iNet API: set_tunnel returned error: ${_GA_ERR}"
		return 1
	fi
	log_verbose "GL.iNet API: dashboard updated -- tunnel_id=${_GA_TUNNEL_ID} peer_id=${_GA_PEER_ID}"

	# STEP 6 — Logout
	glinet_api_logout
	return 0
}

glinet_api_logout() {
	# Best-effort dashboard session cleanup
	curl -s --max-time 5 -X POST "$GLINET_ROUTER" \
		-H 'Content-Type: application/json' \
		-d '{"jsonrpc":"2.0","id":1992,"method":"logout","params":{"sid":"'"$GLINET_API_SESSION"'"}}' \
		>/dev/null 2>&1
	log_verbose "GL.iNet API: session logout attempted"
	return 0
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


# --- Webhooks -----------------------------------------------------------------

# URL-encode a string for safe use in GET query parameters
urlencode() {
	_UE_INPUT="$1"
	_UE_OUT=""
	while [ -n "$_UE_INPUT" ]; do
		_UE_CHAR="${_UE_INPUT%"${_UE_INPUT#?}"}"
		_UE_INPUT="${_UE_INPUT#?}"
		case "$_UE_CHAR" in
			[A-Za-z0-9\-_.~])
				_UE_OUT="${_UE_OUT}${_UE_CHAR}"
				;;
			*)
				_UE_HEX=$(printf '%02X' "'${_UE_CHAR}")
				_UE_OUT="${_UE_OUT}%${_UE_HEX}"
				;;
		esac
	done
	printf '%s' "$_UE_OUT"
}

send_webhook() {
	TUNNEL_LABEL=$1
	FROM_PEER=$2
	TO_PEER=$3
	STATUS=$4

	[ -z "$WEBHOOK_URL" ] && return
	[ "$DRY_RUN" = "1" ] && [ "$FLAG_DEBUG" = "0" ] && log_dryrun "Would send webhook: status=${STATUS} tunnel='${TUNNEL_LABEL}' from='${FROM_PEER}' to='${TO_PEER}'" && return
	[ -n "$INTERACTIVE" ] && [ "$FLAG_DEBUG" = "0" ] && return

	send_webhook_payload "$TUNNEL_LABEL" "$FROM_PEER" "$TO_PEER" "$STATUS"
	log_verbose "Webhook sent: status=${STATUS} tunnel='${TUNNEL_LABEL}' from='${FROM_PEER}' to='${TO_PEER}'"
}

# Sends WAN transition webhooks using persisted state in STATE_DIR.
send_wan_webhook() {
	_WAN_EVENT=$1   # 'down' or 'up'
	[ -z "$WEBHOOK_URL" ] && return
	[ "$DRY_RUN" = "1" ] && [ "$FLAG_DEBUG" = "0" ] && log_dryrun "Would send WAN webhook: status=wan_${_WAN_EVENT}" && return
	[ -n "$INTERACTIVE" ] && [ "$FLAG_DEBUG" = "0" ] && return

	# WAN_STATE_FILE holds either 'up' or 'down'.
	WAN_STATE_FILE="${STATE_DIR}/wan_state"
	_PREV_STATE=$(cat "$WAN_STATE_FILE" 2>/dev/null || echo "up")

	# Send on down transition, and on up transition after prior down.
	if [ "$_WAN_EVENT" = "down" ]; then
		echo "down" > "$WAN_STATE_FILE"
		send_webhook_payload "wan" "" "" "wan_down"
		log_verbose "WAN webhook sent: wan_down"
	elif [ "$_WAN_EVENT" = "up" ]; then
		if [ "$_PREV_STATE" = "down" ]; then
			echo "up" > "$WAN_STATE_FILE"
			# Recovery event.
			log_success "WAN restored — internet connectivity is back"
			send_webhook_payload "wan" "" "" "wan_up"
			log_verbose "WAN webhook sent: wan_up"
		fi
	fi
}

# Sends tunnel up/down transition webhooks using per-interface state files.
send_tunnel_state_webhook() {
	_TSW_IFACE=$1
	_TSW_LABEL=$2
	_TSW_EVENT=$3   # 'up' or 'down'
	[ -z "$WEBHOOK_URL" ] && return
	[ "$DRY_RUN" = "1" ] && [ "$FLAG_DEBUG" = "0" ] && return
	[ -n "$INTERACTIVE" ] && [ "$FLAG_DEBUG" = "0" ] && return

	# _TSW_STATE_FILE holds 'up' or 'down' for this interface.
	_TSW_STATE_FILE="${STATE_DIR}/${_TSW_IFACE}.tunnel_state"
	_TSW_PREV=$(cat "$_TSW_STATE_FILE" 2>/dev/null || echo "unknown")

	if [ "$_TSW_EVENT" = "down" ]; then
		echo "down" > "$_TSW_STATE_FILE"
		if [ "$_TSW_PREV" != "down" ]; then
			send_webhook_payload "$_TSW_LABEL" "" "" "tunnel_down"
			log_verbose "Tunnel webhook sent: ${_TSW_LABEL} tunnel_down"
		fi
	elif [ "$_TSW_EVENT" = "up" ]; then
		echo "up" > "$_TSW_STATE_FILE"
		if [ "$_TSW_PREV" = "down" ]; then
			log_info "Tunnel '${_TSW_LABEL}' (${_TSW_IFACE}): interface restored — monitoring resumed"
			send_webhook_payload "$_TSW_LABEL" "" "" "tunnel_up"
			log_verbose "Tunnel webhook sent: ${_TSW_LABEL} tunnel_up"
		fi
	fi
}

# --- Webhook processors -------------------------------------------------------
# Builds and sends a consolidated status webhook payload.
send_status_webhook() {
	[ -z "$WEBHOOK_URL" ] && log_error "status --webhook: WEBHOOK_URL is not set" && return 1

	_SSW_NOW=$(date +%s)

	# WAN — live reachability + cached ubus interface info
	get_wan_info
	if wan_is_reachable; then
		_SSW_WAN_STATE="up"
	else
		_SSW_WAN_STATE="down"
	fi
	_SSW_WAN_IFACE="$_WAN_INFO_IFACE"
	_SSW_WAN_UPTIME_SECS="$_WAN_INFO_UPTIME_SECS"

	# WAN stability
	_SSW_WAN_STABLE=false
	_SSW_WAN_STABLE_FOR=0
	_SSW_WAN_STABLE_REMAINING=0
	if wan_is_stable; then
		_SSW_WAN_STABLE=true
		_SSW_WAN_STABLE_SINCE=$(cat "${STATE_DIR}/wan_stable_since" 2>/dev/null || echo 0)
		[ "$_SSW_WAN_STABLE_SINCE" != "0" ] && \
			_SSW_WAN_STABLE_FOR=$(( $(date +%s) - _SSW_WAN_STABLE_SINCE ))
	else
		_SSW_WAN_STABLE_SINCE=$(cat "${STATE_DIR}/wan_stable_since" 2>/dev/null || echo 0)
		if [ "$_SSW_WAN_STABLE_SINCE" != "0" ]; then
			_SSW_WAN_STABLE_FOR=$(( $(date +%s) - _SSW_WAN_STABLE_SINCE ))
			_SSW_WAN_STABLE_REMAINING=$(( WAN_STABILITY_THRESHOLD - _SSW_WAN_STABLE_FOR ))
			[ "$_SSW_WAN_STABLE_REMAINING" -lt 0 ] && _SSW_WAN_STABLE_REMAINING=0
		else
			_SSW_WAN_STABLE_REMAINING="$WAN_STABILITY_THRESHOLD"
		fi
	fi
	if [ -n "$_SSW_WAN_UPTIME_SECS" ] && [ "$_SSW_WAN_UPTIME_SECS" -gt 0 ] 2>/dev/null; then
		_SSW_WAN_UPTIME=$(format_duration "$_SSW_WAN_UPTIME_SECS")
	else
		_SSW_WAN_UPTIME=""
	fi

	# Health ladder: ok < degraded < stale < offline/no_peers/single_peer
	_SSW_OVERALL="ok"

	# Per-tunnel structured data stored as delimited string for processor use
	# Format per entry: LABEL|IFACE|STATE|PEER|PING|ROT_NEXT|TOTAL|AVAIL|FAILOVERS_24H|LAST_FAILOVER_AGO|FAILOVERS_30D
	_SSW_TUNNEL_DATA=""
	_SSW_TUNNELS_JSON=""
	_SSW_FIRST=1

	_SSW_i=1
	while [ "$_SSW_i" -le "$TUNNEL_COUNT" ]; do
		eval "_SSW_LABEL=\$TUNNEL_${_SSW_i}_LABEL"
		eval "_SSW_IFACE=\$TUNNEL_${_SSW_i}_IFACE"
		eval "_SSW_WG_IF=\$TUNNEL_${_SSW_i}_WG_IF"
		eval "_SSW_ROUTE_TABLE=\$TUNNEL_${_SSW_i}_ROUTE_TABLE"
		eval "_SSW_ENABLED=\$TUNNEL_${_SSW_i}_FAILOVER_ENABLED"
		eval "_SSW_ROTATE=\$TUNNEL_${_SSW_i}_ROTATE"
		_SSW_PING_VERIFY="${PING_VERIFY:-0}"

		_SSW_STATE="ok"
		_SSW_PEER=""
		_SSW_PING="null"
		_SSW_TOTAL_PEERS=0
		_SSW_AVAIL_PEERS=0
		_SSW_ALT_AVAIL=0

		if [ "$_SSW_ENABLED" != "1" ]; then
			_SSW_STATE="failover_disabled"
		elif ! is_tunnel_up "$_SSW_IFACE"; then
			_SSW_STATE="offline"
		else
			_SSW_ACTIVE_PEER=$(get_active_peer "$_SSW_IFACE")
			_SSW_PEER=$(get_peer_name "$_SSW_ACTIVE_PEER")
			_SSW_AGE=$(get_handshake_age "$_SSW_IFACE" "$_SSW_ACTIVE_PEER")
			if [ "$_SSW_AGE" -gt "$HANDSHAKE_TIMEOUT" ]; then
				_SSW_STATE="stale"
			elif [ "$_SSW_PING_VERIFY" = "1" ]; then
				if ping_through_tunnel "$_SSW_WG_IF" "$_SSW_ROUTE_TABLE" > /dev/null 2>&1; then
					_SSW_STATE="ok"
					_SSW_PING="true"
				else
					_SSW_STATE="degraded"
					_SSW_PING="false"
				fi
			fi
		fi

		# Pool counts — use same pool logic as main loop
		eval "_SSW_KEYWORD=\$TUNNEL_${_SSW_i}_KEYWORD"
		if [ -z "$_SSW_KEYWORD" ]; then
			_SSW_POOL=$(get_peers_excluding_other_keywords "$_SSW_i")
		else
			_SSW_POOL=$(get_peers_for_keyword "$_SSW_KEYWORD")
		fi
		for _SSW_P in $_SSW_POOL; do
			_SSW_TOTAL_PEERS=$(( _SSW_TOTAL_PEERS + 1 ))
			if ! peer_in_cooldown "$_SSW_IFACE" "$_SSW_P"; then
				_SSW_AVAIL_PEERS=$(( _SSW_AVAIL_PEERS + 1 ))
				[ "$_SSW_P" != "$_SSW_ACTIVE_PEER" ] && _SSW_ALT_AVAIL=$(( _SSW_ALT_AVAIL + 1 ))
			fi
		done

		if [ "$_SSW_ENABLED" = "1" ] && [ "$_SSW_TOTAL_PEERS" -ge 2 ] && [ "$_SSW_ALT_AVAIL" -eq 0 ]; then
			case "$_SSW_STATE" in
				ok|degraded)
					_SSW_STATE="degraded_no_failover"
					;;
			esac
		fi

		load_failover_summary_for_iface "$_SSW_IFACE" "$_SSW_NOW"
		_SSW_FAILOVERS_24H=$F_H_24
		_SSW_FAILOVERS_30D=$F_H_30
		_SSW_LAST_FAILOVER_AGO=$F_H_LAST_AGO

		# Worst state wins — also factor WAN into overall
		case "$_SSW_STATE" in
			offline|no_peers|single_peer) _SSW_OVERALL="critical" ;;
			stale|degraded|degraded_no_failover)
				[ "$_SSW_OVERALL" = "ok" ] && _SSW_OVERALL="warning" ;;
		esac

		# Next rotation
		_SSW_ROT_NEXT="null"
		if [ -n "$_SSW_ROTATE" ]; then
			_SSW_LAST_ROT=$(cat "${STATE_DIR}/${_SSW_IFACE}.last_rotate" 2>/dev/null || echo 0)
			_SSW_ROT_NEXT=$(schedule_next_due "$_SSW_ROTATE" "$_SSW_LAST_ROT")
		fi

		# Store structured per-tunnel data for processors
		_SSW_ENTRY="${_SSW_LABEL}|${_SSW_IFACE}|${_SSW_STATE}|${_SSW_PEER}|${_SSW_PING}|${_SSW_ROT_NEXT}|${_SSW_TOTAL_PEERS}|${_SSW_AVAIL_PEERS}|${_SSW_FAILOVERS_24H}|${_SSW_LAST_FAILOVER_AGO}|${_SSW_FAILOVERS_30D}"
		if [ -z "$_SSW_TUNNEL_DATA" ]; then
			_SSW_TUNNEL_DATA="$_SSW_ENTRY"
		else
			_SSW_TUNNEL_DATA="${_SSW_TUNNEL_DATA}
${_SSW_ENTRY}"
		fi

		# JSON entry
		[ "$_SSW_FIRST" = "0" ] && _SSW_TUNNELS_JSON="${_SSW_TUNNELS_JSON},"
		_SSW_TUNNELS_JSON="${_SSW_TUNNELS_JSON}{\"label\":\"${_SSW_LABEL}\",\"iface\":\"${_SSW_IFACE}\",\"state\":\"${_SSW_STATE}\",\"peer\":\"${_SSW_PEER}\",\"ping\":${_SSW_PING},\"rotation_next\":\"${_SSW_ROT_NEXT}\",\"peers_total\":${_SSW_TOTAL_PEERS},\"peers_available\":${_SSW_AVAIL_PEERS},\"failovers_24h\":${_SSW_FAILOVERS_24H},\"failovers_30d\":${_SSW_FAILOVERS_30D},\"recent_failover_ago\":\"${_SSW_LAST_FAILOVER_AGO}\"}"
		_SSW_FIRST=0
		_SSW_i=$(( _SSW_i + 1 ))
	done

	# WAN affects overall health too
	[ "$_SSW_WAN_STATE" = "down" ] && _SSW_OVERALL="critical"
	[ "$_SSW_WAN_STABLE" = "false" ] && [ "${WAN_STABILITY_THRESHOLD:-0}" -gt 0 ] && \
		[ "$_SSW_OVERALL" = "ok" ] && _SSW_OVERALL="warning"

	# Full condensed JSON
	_SSW_JSON="{\"type\":\"status\",\"wan\":\"${_SSW_WAN_STATE}\",\"wan_iface\":\"${_SSW_WAN_IFACE}\",\"wan_uptime\":\"${_SSW_WAN_UPTIME}\",\"wan_stable\":${_SSW_WAN_STABLE},\"wan_stable_for_s\":${_SSW_WAN_STABLE_FOR},\"wan_stable_remaining_s\":${_SSW_WAN_STABLE_REMAINING},\"overall\":\"${_SSW_OVERALL}\",\"tunnels\":[${_SSW_TUNNELS_JSON}]}"

	case "$WEBHOOK_PROCESSOR" in
		ntfy)   _webhook_ntfy   "status" "$_SSW_OVERALL" "$_SSW_TUNNEL_DATA" "$_SSW_WAN_STATE" "$_SSW_WAN_IFACE" "$_SSW_WAN_UPTIME" "$_SSW_WAN_STABLE" "$_SSW_WAN_STABLE_FOR" "$_SSW_WAN_STABLE_REMAINING" ;;
		gotify) _webhook_gotify "status" "$_SSW_OVERALL" "$_SSW_TUNNEL_DATA" "$_SSW_WAN_STATE" "$_SSW_WAN_IFACE" "$_SSW_WAN_UPTIME" "$_SSW_WAN_STABLE" "$_SSW_WAN_STABLE_FOR" "$_SSW_WAN_STABLE_REMAINING" ;;
		json)   _webhook_json   "status" "" "" "" "$_SSW_JSON" ;;
		get)    _webhook_get    "status" "" "" "" "$_SSW_JSON" ;;
		*)      _webhook_plain  "status" "$_SSW_OVERALL" "$_SSW_TUNNEL_DATA" "$_SSW_WAN_STATE" "$_SSW_WAN_IFACE" "$_SSW_WAN_UPTIME" "$_SSW_WAN_STABLE" "$_SSW_WAN_STABLE_FOR" "$_SSW_WAN_STABLE_REMAINING" ;;
	esac
}

# Sends one webhook payload with repeat suppression.
send_webhook_payload() {
	_WP_TUN=$1
	_WP_FROM=$2
	_WP_TO=$3
	_WP_ST=$4

	_WP_STATUS_FILE="${STATE_DIR}/${_WP_TUN}.webhook_last_status"
	_WP_TS_FILE="${STATE_DIR}/${_WP_TUN}.webhook_last_ts"
	_WP_LAST_STATUS=$(cat "$_WP_STATUS_FILE" 2>/dev/null || echo '')
	_WP_LAST_TS=$(cat "$_WP_TS_FILE" 2>/dev/null || echo 0)
	_WP_NOW=$(date +%s)
	_WP_ELAPSED=$(( _WP_NOW - _WP_LAST_TS ))

	if [ "$_WP_ST" = "$_WP_LAST_STATUS" ] && [ "$_WP_ELAPSED" -lt "$WEBHOOK_REPEAT_INTERVAL" ]; then
		log_verbose "Webhook suppressed: status=${_WP_ST} tunnel=${_WP_TUN} (repeat, ${_WP_ELAPSED}s ago, interval=${WEBHOOK_REPEAT_INTERVAL}s)"
		return
	fi

	echo "$_WP_ST" > "$_WP_STATUS_FILE"
	echo "$_WP_NOW" > "$_WP_TS_FILE"

	case "$WEBHOOK_PROCESSOR" in
		ntfy)   _webhook_ntfy   "$_WP_ST" "$_WP_TUN" "$_WP_FROM" "$_WP_TO" ;;
		gotify) _webhook_gotify "$_WP_ST" "$_WP_TUN" "$_WP_FROM" "$_WP_TO" ;;
		json)   _webhook_json   "$_WP_ST" "$_WP_TUN" "$_WP_FROM" "$_WP_TO" ;;
		get)    _webhook_get    "$_WP_ST" "$_WP_TUN" "$_WP_FROM" "$_WP_TO" ;;
		*)      _webhook_plain  "$_WP_ST" "$_WP_TUN" "$_WP_FROM" "$_WP_TO" ;;
	esac
}
# ---------------------------------------------------------------------------
# Webhook event metadata shared by ntfy and gotify.
# Sets: _META_TITLE _META_MSG _META_PRI_NAME _META_PRI_NUM _META_TAGS
# Args: $1=status $2=tun $3=from $4=to
# ---------------------------------------------------------------------------
_event_meta() {
	_EM_ST=$1 _EM_TUN=$2 _EM_FROM=$3 _EM_TO=$4
	case "$_EM_ST" in
		switched_failover)
			_META_TITLE="VPN Failover [${_EM_TUN}]"
			_META_MSG="From: ${_EM_FROM}
To: ${_EM_TO}"
			_META_PRI_NAME="default" _META_PRI_NUM=5 _META_TAGS="white_check_mark" ;;
		switched_revert)
			_META_TITLE="VPN Reverted [${_EM_TUN}]"
			_META_MSG="From: ${_EM_FROM}
To: ${_EM_TO}"
			_META_PRI_NAME="low" _META_PRI_NUM=3 _META_TAGS="leftwards_arrow_with_hook" ;;
		rotated_scheduled)
			_META_TITLE="VPN Rotation [${_EM_TUN}]"
			_META_MSG="From: ${_EM_FROM}
To: ${_EM_TO}"
			_META_PRI_NAME="low" _META_PRI_NUM=3 _META_TAGS="arrows_counterclockwise" ;;
		rotated_manual)
			_META_TITLE="VPN Manual Rotation [${_EM_TUN}]"
			_META_MSG="From: ${_EM_FROM}
To: ${_EM_TO}"
			_META_PRI_NAME="low" _META_PRI_NUM=3 _META_TAGS="arrows_counterclockwise" ;;
		tunnel_up)
			_META_TITLE="Tunnel Restored [${_EM_TUN}]"
			_META_MSG="Interface is up again, monitoring resumed"
			_META_PRI_NAME="default" _META_PRI_NUM=5 _META_TAGS="white_check_mark" ;;
		tunnel_down)
			_META_TITLE="Tunnel Down [${_EM_TUN}]"
			_META_MSG="Interface is down, monitoring skipped"
			_META_PRI_NAME="high" _META_PRI_NUM=7 _META_TAGS="warning" ;;
		single_peer)
			_META_TITLE="Single Peer [${_EM_TUN}]"
			_META_MSG="Only one peer in pool, failover not possible"
			_META_PRI_NAME="high" _META_PRI_NUM=7 _META_TAGS="warning" ;;
		rotation_all_cooldown)
			_META_TITLE="Rotation Skipped [${_EM_TUN}]"
			_META_MSG="All peers in cooldown, scheduled rotation skipped"
			_META_PRI_NAME="low" _META_PRI_NUM=3 _META_TAGS="warning" ;;
		all_failed_wan_lost)
			_META_TITLE="WAN Lost Mid-Failover [${_EM_TUN}]"
			_META_MSG="WAN dropped while failing over from ${_EM_FROM}, peer cycle aborted"
			_META_PRI_NAME="urgent" _META_PRI_NUM=9 _META_TAGS="rotating_light" ;;
		failover_ping_failed)
			_META_TITLE="Peer Unreachable [${_EM_TUN}]"
			_META_MSG="From: ${_EM_FROM}
To: ${_EM_TO}"
			_META_PRI_NAME="high" _META_PRI_NUM=7 _META_TAGS="warning" ;;
		rotation_ping_failed)
			_META_TITLE="Rotation Failed [${_EM_TUN}]"
			_META_MSG="From: ${_EM_FROM}
To: ${_EM_TO}"
			_META_PRI_NAME="low" _META_PRI_NUM=3 _META_TAGS="warning" ;;
		all_failed)
			_META_TITLE="All Peers Down [${_EM_TUN}]"
			_META_MSG="No peers available on ${_EM_TUN}"
			_META_PRI_NAME="urgent" _META_PRI_NUM=9 _META_TAGS="rotating_light" ;;
		wan_down)
			_META_TITLE="WAN Down"
			_META_MSG="Internet connectivity lost"
			_META_PRI_NAME="urgent" _META_PRI_NUM=9 _META_TAGS="rotating_light" ;;
		wan_up)
			_META_TITLE="WAN Restored"
			_META_MSG="Internet connectivity restored"
			_META_PRI_NAME="default" _META_PRI_NUM=5 _META_TAGS="white_check_mark" ;;
		failover_disabled)
			_META_TITLE="Failover Disabled [${_EM_TUN}]"
			_META_MSG="Auto-failover is disabled for this tunnel"
			_META_PRI_NAME="min" _META_PRI_NUM=1 _META_TAGS="" ;;
		benchmarks)
			_META_TITLE="Benchmark Summary"
			_META_MSG=""
			_META_PRI_NAME="default" _META_PRI_NUM=4 _META_TAGS="bar_chart" ;;
		*)
			_META_TITLE="VPN Notice [${_EM_TUN}]"
			_META_MSG="Status: ${_EM_ST}
From: ${_EM_FROM}
To: ${_EM_TO}"
			_META_PRI_NAME="default" _META_PRI_NUM=5 _META_TAGS="" ;;
	esac
}

# ---------------------------------------------------------------------------
# Status line builder used by plain/gotify and ntfy output.
# Args: $1=format (plain|rich)  $2..7=wan args (state iface uptime stable stable_for stable_rem)
# Reads _SSW_TUNNEL_DATA from scope
# ---------------------------------------------------------------------------
_build_status_lines() {
	_BSL_FMT=$1
	_BSL_WAN_STATE=$2 _BSL_WAN_IFACE=$3 _BSL_WAN_UPTIME=$4
	_BSL_WAN_STABLE=$5 _BSL_WAN_STABLE_FOR=$6 _BSL_WAN_STABLE_REM=$7

	printf '%s\n' "$_SSW_TUNNEL_DATA" | while IFS='|' read -r _L _IF _ST _PEER _PING _ROT _TOTAL _AVAIL _F24 _LA _F30; do
		_BSL_IDX=1
		while [ "$_BSL_IDX" -le "$TUNNEL_COUNT" ]; do
			eval "_BSL_CHECK=\$TUNNEL_${_BSL_IDX}_IFACE"
			[ "$_BSL_CHECK" = "$_IF" ] && break
			_BSL_IDX=$((_BSL_IDX + 1))
		done
		_BSL_NOW_EPOCH=$(date +%s)
		parse_benchmark_tunnel_summary \
			"$(get_benchmark_report_for_tunnel_index "$_BSL_IDX" "$_BSL_NOW_EPOCH" | sed -n '1p')" \
			"$_BSL_NOW_EPOCH"
		_BSL_AVG30_INT=$(awk -v x="${B_T_AVG30:-0}" 'BEGIN { printf "%.0f", x+0 }')

		if [ "$_BSL_FMT" = "rich" ]; then
			_IND=$(_state_emoji "$_ST" "$_F24")
			# Paragraph header
			case "$_ST" in
				offline)  printf '%s %s: %s\n' "$_IND" "$_L" "offline" ;;
				no_peers) printf '%s %s: %s\n' "$_IND" "$_L" "no peers" ;;
				*)        printf '%s %s: %s\n' "$_IND" "$_L" "$_PEER" ;;
			esac
			
			printf '      Peers Available: %s/%s\n' "$_AVAIL" "$_TOTAL"
			[ "$_BSL_LAST_TS" != "none" ] && printf '      30d Avg D/L: %s Mbps\n' "$_BSL_AVG30_INT"
			if [ "${_F30:-0}" -gt 0 ] 2>/dev/null; then
				if [ "$_F24" -gt 0 ] 2>/dev/null && [ -n "$_LA" ]; then
					printf '      30d Failovers: %s (last %s ago)\n' "${_F30:-0}" "$_LA"
				else
					printf '      30d Failovers: %s\n' "${_F30:-0}"
				fi
			fi
			[ "$_ST" = "stale" ]            && printf '%s\n' '      Handshake: Stale'
			[ "$_ST" = "degraded" ]         && printf '%s\n' '      Ping: Failing'
			[ "$_ST" = "degraded_no_failover" ] && printf '%s\n' '      Failover: All Peers in Cooldown'
			[ "$_ST" = "single_peer" ]      && printf '%s\n' '      Failover: No failover available'
			[ "$_ST" = "failover_disabled" ] && printf '%s\n' '      Failover: Disabled'
			[ "$_ROT" != "null" ] && [ "$_ST" = "ok" ] && printf '      Next Rotation: %s\n' "$_ROT"
			printf '\n'
		else
			_IND=$(_state_badge "$_ST" "$_F24")
			case "$_ST" in
				ok)               _LINE="${_IND} ${_L}: ${_PEER} (${_AVAIL}/${_TOTAL} peers)" ;;
				degraded)         _LINE="${_IND} ${_L}: ${_PEER} -- ping failing (${_AVAIL}/${_TOTAL} peers)" ;;
				degraded_no_failover) _LINE="${_IND} ${_L}: ${_PEER} -- All Failover Peers in Cooldown" ;;
				stale)            _LINE="${_IND} ${_L}: ${_PEER} -- stale handshake (${_AVAIL}/${_TOTAL} peers)" ;;
				offline)          _LINE="${_IND} ${_L}: offline" ;;
				single_peer)      _LINE="${_IND} ${_L}: ${_PEER} -- no failover available" ;;
				no_peers)         _LINE="${_IND} ${_L}: no peers available" ;;
				failover_disabled) _LINE="${_IND} ${_L}: auto-failover disabled" ;;
				*)                _LINE="${_IND} ${_L}: ${_ST}" ;;
			esac
			[ "$_BSL_LAST_TS" != "none" ] && _LINE="${_LINE}, 30d avg d/l: ${_BSL_AVG30_INT} Mbps"
			_LINE="${_LINE}, 30d failovers: ${_F30:-0}"
			[ "$_ST" != "offline" ] && [ "$_ST" != "no_peers" ] && [ "$_ST" != "failover_disabled" ] && \
				[ "$_F24" -gt 0 ] 2>/dev/null && [ -n "$_LA" ] && _LINE="${_LINE}, last ${_LA} ago"
			[ "$_ST" = "ok" ] && [ "$_ROT" != "null" ] && _LINE="${_LINE}, next rotation: ${_ROT}"
			printf '%s\n' "$_LINE"
		fi
	done

	# WAN line/paragraph
	if [ "$_BSL_FMT" = "rich" ]; then
		_WAN_IND=$(_state_emoji "$_BSL_WAN_STATE")
		printf '%s WAN' "$_WAN_IND"
		[ -n "$_BSL_WAN_IFACE" ] && printf ' (%s)' "$_BSL_WAN_IFACE"
		printf '\n'
		[ -n "$_BSL_WAN_UPTIME" ] && printf '      Uptime: %s\n' "$_BSL_WAN_UPTIME"
		if [ "${WAN_STABILITY_THRESHOLD:-0}" -gt 0 ]; then
			if [ "$_BSL_WAN_STABLE" = "true" ]; then
				printf '      Stability: Confirmed (%s)\n' "$(format_duration "$_BSL_WAN_STABLE_FOR")"
			else
				printf '      Stability: Not yet stable\n'
				printf '      Remaining: %s\n' "$(format_duration "$_BSL_WAN_STABLE_REM")"
				printf '%s\n' '      Failover: Suppressed'
			fi
		fi
	else
		_WAN_IND=$(_state_badge "$_BSL_WAN_STATE")
		_WAN_LINE="${_WAN_IND} WAN"
		[ -n "$_BSL_WAN_IFACE" ]  && _WAN_LINE="${_WAN_LINE} (${_BSL_WAN_IFACE})"
		[ -n "$_BSL_WAN_UPTIME" ] && _WAN_LINE="${_WAN_LINE}: ${_BSL_WAN_UPTIME} uptime"
		if [ "${WAN_STABILITY_THRESHOLD:-0}" -gt 0 ]; then
			if [ "$_BSL_WAN_STABLE" = "true" ]; then
				_WAN_LINE="${_WAN_LINE}, stable for $(format_duration "$_BSL_WAN_STABLE_FOR")"
			else
				_WAN_LINE="${_WAN_LINE}, [NOT STABLE] $(format_duration "$_BSL_WAN_STABLE_REM") remaining"
			fi
		fi
		printf '%s\n' "$_WAN_LINE"
	fi
}

# Helper: state badge (plain/get/json)
_state_badge() {
	_SB_STATE=$1
	_SB_F24=${2:-0}

	if [ "$_SB_STATE" = "ok" ] && [ "$_SB_F24" -gt 0 ] 2>/dev/null; then
		printf '[OK, RECENT FAILOVER]'
		return
	fi

	case "$_SB_STATE" in
		ok)                printf '[OK]' ;;
		degraded)          printf '[DEGRADED]' ;;
		degraded_no_failover) printf '[PAUSED, NO FAILOVER]' ;;
		stale)             printf '[STALE]' ;;
		offline)           printf '[OFFLINE]' ;;
		single_peer)       printf '[SINGLE PEER]' ;;
		no_peers)          printf '[NO PEERS]' ;;
		up)                printf '[UP]' ;;
		down)              printf '[DOWN]' ;;
		failover_disabled) printf '[FAILOVER DISABLED]' ;;
		*)                 printf '[UNKNOWN]' ;;
	esac
}

# Helper: state emoji (ntfy/gotify)
_state_emoji() {
	_SE_STATE=$1
	_SE_F24=${2:-0}

	# If tunnel is currently healthy but had failovers in the last 24h,
	# highlight it as recently unstable.
	if [ "$_SE_STATE" = "ok" ] && [ "$_SE_F24" -gt 0 ] 2>/dev/null; then
		printf '⚠️'
		return
	fi

	case "$_SE_STATE" in
		ok|up)                 printf '🟢' ;;
		degraded)              printf '⚠️' ;;
		degraded_no_failover)  printf '⏸️' ;;
		stale)                 printf '⏳' ;;
		offline|down)          printf '🔴' ;;
		no_peers)              printf '🚫' ;;
		single_peer)           printf '1️⃣' ;;
		failover_disabled)     printf '⏸️' ;;
		*)                     printf '❓' ;;
	esac
}

# ---------------------------------------------------------------------------
# Processors
# ---------------------------------------------------------------------------

_webhook_plain() {
	_ST=$1
	if [ "$_ST" = "status" ]; then
		_MSG=$(_build_status_lines "plain" "$4" "$5" "$6" "$7" "$8" "$9")
	elif [ "$_ST" = "benchmarks" ]; then
		_MSG=$(_build_benchmark_lines)
	else
		_TUN=$2 _FROM=$3 _TO=$4
		case "$_ST" in
			switched_failover)     _MSG="${_TUN}
From: ${_FROM}
To: ${_TO}" ;;
			switched_revert)       _MSG="${_TUN}
From: ${_FROM}
To: ${_TO}" ;;
			rotated_scheduled)     _MSG="${_TUN}
From: ${_FROM}
To: ${_TO}" ;;
			rotated_manual)        _MSG="${_TUN}
From: ${_FROM}
To: ${_TO}" ;;
			tunnel_up)             _MSG="${_TUN} - tunnel interface is back up, monitoring resumed" ;;
			tunnel_down)           _MSG="${_TUN} - tunnel interface is down, monitoring skipped" ;;
			single_peer)           _MSG="${_TUN} - only one peer in pool, failover not possible" ;;
			rotation_all_cooldown) _MSG="${_TUN} - all peers in cooldown, rotation skipped" ;;
			all_failed_wan_lost)   _MSG="${_TUN} - WAN lost mid-failover on ${_FROM}, peer cycle aborted" ;;
			failover_ping_failed)  _MSG="${_TUN}
From: ${_FROM}
To: ${_TO}" ;;
			rotation_ping_failed)  _MSG="${_TUN}
From: ${_FROM}
To: ${_TO}" ;;
			all_failed)            _MSG="${_TUN} - all peers exhausted, no failover possible" ;;
			wan_down)              _MSG="WAN offline" ;;
			wan_up)                _MSG="WAN restored" ;;
			failover_disabled)     _MSG="${_TUN} - auto-failover disabled" ;;
			*)                     _MSG="${_TUN}
Status: ${_ST}
From: ${_FROM}
To: ${_TO}" ;;
		esac
		[ -n "$INTERACTIVE" ] && _MSG="[[TEST]] ${_MSG}"
	fi
	external_curl -s -o /dev/null --max-time 10 -d "$_MSG" "$WEBHOOK_URL" &
}

_webhook_json() {
	_ST=$1 _RAW=${5:-}
	[ -n "$INTERACTIVE" ] && [ "$_ST" != "status" ] && _ST="[[TEST]] ${_ST}"
	if [ "$_ST" = "status" ]; then
		_BODY=$_RAW
	elif [ "$_ST" = "benchmarks" ]; then
		_BODY=$(cmd_benchmarks_internal_json)
	else
		_TUN=$2 _FROM=$3 _TO=$4
		case "$_ST" in
			all_failed|all_failed_wan_lost)
				_BODY="{\"tunnel\":\"${_TUN}\",\"from\":\"${_FROM}\",\"status\":\"${_ST}\"}" ;;
			tunnel_up|tunnel_down|single_peer|rotation_all_cooldown|failover_disabled)
				_BODY="{\"tunnel\":\"${_TUN}\",\"status\":\"${_ST}\"}" ;;
			wan_down|wan_up)
				_BODY="{\"status\":\"${_ST}\"}" ;;
			*)
				_BODY="{\"tunnel\":\"${_TUN}\",\"from\":\"${_FROM}\",\"to\":\"${_TO}\",\"status\":\"${_ST}\"}" ;;
		esac
	fi
	external_curl -s -o /dev/null --max-time 10 \
		-H "Content-Type: application/json" \
		-d "$_BODY" "$WEBHOOK_URL" &
}

_webhook_get() {
	_ST=$1 _RAW=${5:-}
	[ -n "$INTERACTIVE" ] && [ "$_ST" != "status" ] && _ST="[[TEST]] ${_ST}"
	if [ "$_ST" = "status" ]; then
		_QUERY="type=status&data=$(urlencode "$_RAW")"
	elif [ "$_ST" = "benchmarks" ]; then
		_QUERY="type=benchmarks&data=$(urlencode "$(cmd_benchmarks_internal_json)")"
	else
		_TUN=$2 _FROM=$3 _TO=$4
		case "$_ST" in
			all_failed|all_failed_wan_lost)
				_QUERY="tunnel=$(urlencode "$_TUN")&from=$(urlencode "$_FROM")&status=$(urlencode "$_ST")" ;;
			tunnel_up|tunnel_down|single_peer|rotation_all_cooldown|failover_disabled)
				_QUERY="tunnel=$(urlencode "$_TUN")&status=$(urlencode "$_ST")" ;;
			wan_down|wan_up)
				_QUERY="status=$(urlencode "$_ST")" ;;
			*)
				_QUERY="tunnel=$(urlencode "$_TUN")&from=$(urlencode "$_FROM")&to=$(urlencode "$_TO")&status=$(urlencode "$_ST")" ;;
		esac
	fi
	external_curl -s -o /dev/null --max-time 10 "${WEBHOOK_URL}?${_QUERY}" &
}

_webhook_ntfy() {
	_ST=$1
	if [ "$_ST" = "status" ]; then
		_OVERALL=$2 _WAN_STATE=$4
		_PROBLEMS=$(printf '%s\n' "$_SSW_TUNNEL_DATA" | grep -c '|offline\|degraded\|stale\|single_peer\|no_peers\|failover_disabled' 2>/dev/null)
		_PROBLEMS=$(printf '%s' "${_PROBLEMS:-0}" | head -n1)
		[ -z "$_PROBLEMS" ] && _PROBLEMS=0
		[ "$_WAN_STATE" = "down" ] && _PROBLEMS=$(( _PROBLEMS + 1 ))
		case "$_OVERALL" in
			ok)       _TITLE="VPN Status: All Systems Online"
					  _PRI="min"     _TAGS="white_check_mark" ;;
			warning)  _TITLE="VPN Status: ${_PROBLEMS} Issue$([ "$_PROBLEMS" != "1" ] && printf 's') Detected"
					  _PRI="default" _TAGS="warning" ;;
			critical) _TITLE="VPN Status: ${_PROBLEMS} Critical Issue$([ "$_PROBLEMS" != "1" ] && printf 's')"
					  _PRI="high"    _TAGS="rotating_light" ;;
			*)        _TITLE="📊 VPN Status"
					  _PRI="min"     _TAGS="" ;;
		esac
		_MSG=$(_build_status_lines "rich" "$4" "$5" "$6" "$7" "$8" "$9")
	elif [ "$_ST" = "benchmarks" ]; then
		_event_meta "benchmarks" "" "" ""
		_TITLE="$_META_TITLE" _MSG="$(_build_benchmark_lines)"
		_PRI="$_META_PRI_NAME" _TAGS="$_META_TAGS"
	else
		_event_meta "$_ST" "$2" "$3" "$4"
		_TITLE="$_META_TITLE" _MSG="$_META_MSG"
		_PRI="$_META_PRI_NAME" _TAGS="$_META_TAGS"
		[ -n "$INTERACTIVE" ] && _MSG="[🛠️] ${_MSG}"
	fi
	external_curl -s -o /dev/null --max-time 10 \
		-H "Title: ${_TITLE}" \
		-H "Priority: ${_PRI}" \
		-H "Tags: ${_TAGS}" \
		-d "$_MSG" "$WEBHOOK_URL" &
}

_webhook_gotify() {
	_ST=$1
	if [ "$_ST" = "status" ]; then
		_OVERALL=$2 _WAN_STATE=$4
		case "$_OVERALL" in
			ok)       _TITLE="VPN Status: All Systems Online" ; _PRI=1 ;;
			warning)  _TITLE="VPN Status: Issues Detected"    ; _PRI=5 ;;
			critical) _TITLE="VPN Status: Critical Issues"    ; _PRI=8 ;;
			*)        _TITLE="VPN Status"                      ; _PRI=1 ;;
		esac
		_MSG=$(_build_status_lines "plain" "$4" "$5" "$6" "$7" "$8" "$9")
	elif [ "$_ST" = "benchmarks" ]; then
		_event_meta "benchmarks" "" "" ""
		_TITLE="$_META_TITLE" _MSG="$(_build_benchmark_lines)" _PRI="$_META_PRI_NUM"
	else
		_event_meta "$_ST" "$2" "$3" "$4"
		_TITLE="$_META_TITLE" _MSG="$_META_MSG" _PRI="$_META_PRI_NUM"
		[ -n "$INTERACTIVE" ] && _MSG="[[TEST]] ${_MSG}"
	fi
	_BODY="{\"title\":\"${_TITLE}\",\"message\":\"${_MSG}\",\"priority\":${_PRI}}"
	external_curl -s -o /dev/null --max-time 10 \
		-H "Content-Type: application/json" \
		-d "$_BODY" "$WEBHOOK_URL" &
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
		eval "OTHER_ENABLED=\$TUNNEL_${j}_FAILOVER_ENABLED"
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

# Returns a deduplicated space-separated list of all peers across all enabled tunnels.
# Uses existing per-tunnel pool functions, so keyword scoping is respected.
# Sets _GATP_BLANK_SEEN internally to correctly handle blank-keyword tunnels.
get_all_tunnel_peers() {
	_GATP_ALL=''
	_GATP_BLANK_SEEN=0
	_GATP_i=1
	while [ "$_GATP_i" -le "$TUNNEL_COUNT" ]; do
		eval "_GATP_ENABLED=\$TUNNEL_${_GATP_i}_FAILOVER_ENABLED"
		eval "_GATP_KEYWORD=\$TUNNEL_${_GATP_i}_KEYWORD"

		if [ "$_GATP_ENABLED" != "1" ]; then
			_GATP_i=$((_GATP_i + 1)); continue
		fi

		if [ -z "$_GATP_KEYWORD" ]; then
			if [ "$_GATP_BLANK_SEEN" = "1" ]; then
				_GATP_i=$((_GATP_i + 1)); continue
			fi
			_GATP_PEERS=$(get_peers_excluding_other_keywords "$_GATP_i")
			_GATP_BLANK_SEEN=1
		else
			_GATP_PEERS=$(get_peers_for_keyword "$_GATP_KEYWORD")
		fi

		for _GATP_PEER in $_GATP_PEERS; do
			case " $_GATP_ALL " in
				*" $_GATP_PEER "*) ;;  # already in list
				*) _GATP_ALL="$_GATP_ALL $_GATP_PEER" ;;
			esac
		done

		_GATP_i=$((_GATP_i + 1))
	done
	printf '%s' "$_GATP_ALL"
}

# Returns space-separated peer list for tunnel index $1, respecting keyword scoping.
get_peers_for_tunnel_index() {
	eval "_GPTI_KEYWORD=\$TUNNEL_${1}_KEYWORD"
	if [ -z "$_GPTI_KEYWORD" ]; then
		get_peers_excluding_other_keywords "$1"
	else
		get_peers_for_keyword "$_GPTI_KEYWORD"
	fi
}

# Returns the tunnel index that owns peer $1, or '' if not found.
get_tunnel_index_for_peer() {
	_GTIP_PEER=$1
	_GTIP_i=1
	_GTIP_BLANK_SEEN=0
	while [ "$_GTIP_i" -le "$TUNNEL_COUNT" ]; do
		eval "_GTIP_ENABLED=\$TUNNEL_${_GTIP_i}_FAILOVER_ENABLED"
		eval "_GTIP_KEYWORD=\$TUNNEL_${_GTIP_i}_KEYWORD"

		if [ "$_GTIP_ENABLED" != "1" ]; then
			_GTIP_i=$((_GTIP_i + 1)); continue
		fi

		if [ -z "$_GTIP_KEYWORD" ]; then
			[ "$_GTIP_BLANK_SEEN" = "1" ] && { _GTIP_i=$((_GTIP_i + 1)); continue; }
			_GTIP_PEERS=$(get_peers_excluding_other_keywords "$_GTIP_i")
			_GTIP_BLANK_SEEN=1
		else
			_GTIP_PEERS=$(get_peers_for_keyword "$_GTIP_KEYWORD")
		fi

		for _GTIP_P in $_GTIP_PEERS; do
			if [ "$_GTIP_P" = "$_GTIP_PEER" ]; then
				echo "$_GTIP_i"
				return 0
			fi
		done

		_GTIP_i=$((_GTIP_i + 1))
	done
	echo ''
}

# Resolves the tunnel to use for a cross-tunnel benchmark sweep.
# Reads BENCHMARK_SWEEP_TUNNEL (label match) and falls back to first enabled tunnel.
# Sets: SWEEP_IFACE SWEEP_WG_IF SWEEP_LABEL SWEEP_RT
resolve_sweep_tunnel() {
	SWEEP_IFACE=''; SWEEP_WG_IF=''; SWEEP_LABEL=''; SWEEP_RT=''; SWEEP_IDX=''

	if [ -z "$BENCHMARK_SWEEP_TUNNEL" ]; then
		return 1
	fi

	eval "_RST_ENABLED=\$TUNNEL_${BENCHMARK_SWEEP_TUNNEL}_FAILOVER_ENABLED"
	if [ "$_RST_ENABLED" != "1" ]; then
		log_error "BENCHMARK_SWEEP_TUNNEL ${BENCHMARK_SWEEP_TUNNEL} is not enabled"
		return 1
	fi

	eval "SWEEP_IFACE=\$TUNNEL_${BENCHMARK_SWEEP_TUNNEL}_IFACE"
	eval "SWEEP_WG_IF=\$TUNNEL_${BENCHMARK_SWEEP_TUNNEL}_WG_IF"
	eval "SWEEP_LABEL=\$TUNNEL_${BENCHMARK_SWEEP_TUNNEL}_LABEL"
	eval "SWEEP_RT=\$TUNNEL_${BENCHMARK_SWEEP_TUNNEL}_ROUTE_TABLE"
	SWEEP_IDX="$BENCHMARK_SWEEP_TUNNEL"
	return 0
}

get_peer_name() {
	uci get "wireguard.${1}.name" 2>/dev/null || echo "$1"
}

get_active_peer() {
	uci get "network.${1}.config" 2>/dev/null
}

get_iface_endpoint() {
	wg show "$1" endpoints 2>/dev/null | awk '{print $2}'
}

# Returns 0 if the tunnel interface is administratively up and active.
is_tunnel_up() {
	IFACE=$1
	DISABLED=$(uci get "network.${IFACE}.disabled" 2>/dev/null)
	[ "$DISABLED" = "1" ] && return 1
	_STATUS=$(ubus call "network.interface.${IFACE}" status 2>/dev/null) || return 1
	echo "$_STATUS" | grep -q '"up": *true' && return 0
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
# Polls for a fresh handshake until timeout.
# Output: seconds taken, or 'timeout'.
wait_for_handshake() {
	WG_IF=$1
	_WFH_MIN_EPOCH=${2:-0}   # if set, handshake must post-date this epoch
	START=$(date +%s)
	DEADLINE=$((START + POST_SWITCH_HANDSHAKE_TIMEOUT))

	# Brief pause to let the interface fully come up before polling begins
	sleep 2

	while [ "$(date +%s)" -lt "$DEADLINE" ]; do
		AGE=$(get_handshake_age "$WG_IF")
		_WFH_HS_TIME=$(date -d "@$(( $(date +%s) - AGE ))" '+%H:%M:%S' 2>/dev/null || date -r "$(( $(date +%s) - AGE ))" '+%H:%M:%S' 2>/dev/null || echo 'unknown')
		log_verbose "Tunnel '${WG_IF}': handshake age ${AGE}s -- last handshake at ${_WFH_HS_TIME} (threshold: ${HANDSHAKE_TIMEOUT}s)"
		if [ "$AGE" -lt "$HANDSHAKE_TIMEOUT" ]; then
			if [ "$_WFH_MIN_EPOCH" -gt 0 ] 2>/dev/null; then
				_WFH_HS_EPOCH=$(( $(date +%s) - AGE ))
				if [ "$_WFH_HS_EPOCH" -lt "$_WFH_MIN_EPOCH" ]; then
					log_verbose "Tunnel '${WG_IF}': handshake predates switch (hs_epoch=${_WFH_HS_EPOCH}, switch_ts=${_WFH_MIN_EPOCH}) -- waiting for fresh session"
					sleep "$HANDSHAKE_POLL_INTERVAL"
					continue
				fi
			fi
			echo $(( $(date +%s) - START ))
			return 0
		fi
		sleep "$HANDSHAKE_POLL_INTERVAL"
	done

	echo "timeout"
	return 1
}

# --- Post-API-switch handshake wait -------------------------------------------
# After a GL.iNet API switch the daemon restarts the interface internally.
# Unlike the uci/ubus path (where we explicitly bounce the interface and know
# exactly when it went down), here we must detect the restart ourselves by:
#   1. Waiting until the existing handshake goes stale (old session is gone)
#   2. Then polling for a fresh handshake (new peer is up)
# Each phase respects POST_SWITCH_HANDSHAKE_TIMEOUT. Returns 0 on success,
# 1 if either phase times out.

wait_for_api_switch() {
	_WA_WG_IF=$1
	_WA_START=$(date +%s)
	_WA_DEADLINE=$((_WA_START + POST_SWITCH_HANDSHAKE_TIMEOUT))

	# Phase 1 — wait for old handshake to go stale (age >= HANDSHAKE_TIMEOUT)
	log_verbose "Tunnel '${_WA_WG_IF}': API switch -- waiting for old session to drop..."
	while [ "$(date +%s)" -lt "$_WA_DEADLINE" ]; do
		_WA_AGE=$(get_handshake_age "$_WA_WG_IF")
		if [ "$_WA_AGE" -ge "$HANDSHAKE_TIMEOUT" ]; then
			log_verbose "Tunnel '${_WA_WG_IF}': old session gone (handshake age ${_WA_AGE}s)"
			break
		fi
		sleep "$HANDSHAKE_POLL_INTERVAL"
	done

	if [ "$(date +%s)" -ge "$_WA_DEADLINE" ]; then
		log_warn "Tunnel '${_WA_WG_IF}': timed out waiting for old session to drop -- proceeding anyway"
	fi

	# Phase 2 — wait for fresh handshake from new peer
	log_verbose "Tunnel '${_WA_WG_IF}': API switch -- polling for new peer handshake..."
	_WA_DEADLINE=$(( $(date +%s) + POST_SWITCH_HANDSHAKE_TIMEOUT ))
	while [ "$(date +%s)" -lt "$_WA_DEADLINE" ]; do
		_WA_AGE=$(get_handshake_age "$_WA_WG_IF")
		if [ "$_WA_AGE" -lt "$HANDSHAKE_TIMEOUT" ]; then
			log_info "Tunnel '${_WA_WG_IF}': new peer handshake established (age ${_WA_AGE}s)"
			return 0
		fi
		sleep "$HANDSHAKE_POLL_INTERVAL"
	done

	log_warn "Tunnel '${_WA_WG_IF}': timed out waiting for new peer handshake after API switch"
	return 1
}


# --- WAN check -----------------------------------------------------
# Fetches and caches WAN interface info from ubus once per script run.
# Sets: _WAN_INFO_IFACE, _WAN_INFO_UPTIME_SECS
_WAN_INFO_IFACE=""
_WAN_INFO_UPTIME_SECS=""
_WAN_INFO_LOADED=0

get_wan_info() {
	[ "$_WAN_INFO_LOADED" = "1" ] && return 0
	_WAN_UBUS=$(ubus call network.interface.wan status 2>/dev/null)
	_WAN_INFO_IFACE=$(printf '%s' "$_WAN_UBUS" \
		| grep '"l3_device"' \
		| sed 's/.*"l3_device": "\([^"]*\)".*/\1/')
	_WAN_INFO_UPTIME_SECS=$(printf '%s' "$_WAN_UBUS" \
		| grep '"uptime"' \
		| grep -o '[0-9]*')
	[ -n "$WAN_IFACE" ] && _WAN_INFO_IFACE="$WAN_IFACE"
	_WAN_INFO_LOADED=1
}

# Pings WAN_PING_TARGETS through the WAN interface.
# Returns 0 if any target replies, 1 if all fail.
# Empty WAN_PING_TARGETS skips ping test and returns 0.
wan_is_reachable() {
	[ "$FLAG_FAIL_WAN" = "1" ] && \
		log_verbose "WAN pre-flight: SIMULATED OUTAGE (--fail-wan)" && return 1

	get_wan_info

	[ -z "$WAN_PING_TARGETS" ] && \
		log_verbose "WAN pre-flight: ping check disabled (WAN_PING_TARGETS empty)" && return 0

	if privacy_route_enabled; then
		if [ "${TUNNEL_COUNT:-0}" -le 1 ]; then
			log_warn "WAN pre-flight: bypassing ping check (PRIVACY_ROUTE_VIA_TUNNEL=1 with only one tunnel)"
			log_warn "WAN pre-flight: WAN stability will rely on WAN interface uptime only"
			return 0
		fi
		# Ping through each usable tunnel until one target responds
		_WIR_i=1
		while [ "$_WIR_i" -le "$TUNNEL_COUNT" ]; do
			eval "_WIR_IFACE=\$TUNNEL_${_WIR_i}_IFACE"
			eval "_WIR_WG_IF=\$TUNNEL_${_WIR_i}_WG_IF"
			eval "_WIR_RT=\$TUNNEL_${_WIR_i}_ROUTE_TABLE"
			if is_tunnel_up "$_WIR_IFACE"; then
				for _WIR_TARGET in $WAN_PING_TARGETS; do
					if [ -n "$_WIR_RT" ]; then
						ip route exec table "$_WIR_RT" \
							ping -c 2 -W 3 "$_WIR_TARGET" > /dev/null 2>&1 \
							&& log_verbose "WAN pre-flight: ${_WIR_TARGET} reachable via tunnel ${_WIR_WG_IF}" \
							&& return 0
					fi
					ping -c 2 -W 3 -I "$_WIR_WG_IF" "$_WIR_TARGET" > /dev/null 2>&1 \
						&& log_verbose "WAN pre-flight: ${_WIR_TARGET} reachable via tunnel ${_WIR_WG_IF}" \
						&& return 0
				done
			fi
			_WIR_i=$(( _WIR_i + 1 ))
		done
		log_verbose "WAN pre-flight: no usable tunnel could reach any WAN_PING_TARGETS"
		return 1
	else
		# Ping directly via WAN interface
		[ -z "$_WAN_INFO_IFACE" ] && \
			log_verbose "WAN pre-flight: no WAN interface detected — skipping ping check" && return 0

		for _WIR_TARGET in $WAN_PING_TARGETS; do
			if ping -c 2 -W 3 -I "$_WAN_INFO_IFACE" "$_WIR_TARGET" > /dev/null 2>&1; then
				log_verbose "WAN pre-flight: ${_WIR_TARGET} reachable via ${_WAN_INFO_IFACE}"
				return 0
			fi
			log_verbose "WAN pre-flight: ${_WIR_TARGET} unreachable via ${_WAN_INFO_IFACE}"
		done
		return 1
	fi
}

# Tracks confirmed WAN stability using uptime and ping checks.
# Any failure resets the timer.
# WAN_STABILITY_THRESHOLD=0 disables state tracking.
wan_is_stable() {
	[ "$FLAG_FAIL_WAN" = "1" ] && return 1

	get_wan_info

	_WIS_NOW=$(date +%s)
	_WIS_STABLE_FILE="${STATE_DIR}/wan_stable_since"

	# Single-run mode when threshold disabled
	if [ "${WAN_STABILITY_THRESHOLD:-0}" -eq 0 ]; then
		wan_is_reachable && return 0 || return 1
	fi

	# Stage 1: uptime check
	_WIS_UPTIME="${_WAN_INFO_UPTIME_SECS:-0}"
	if [ "$_WIS_UPTIME" -lt "$WAN_STABILITY_THRESHOLD" ]; then
		log_warn "WAN stability: uptime only $(format_duration "$_WIS_UPTIME") — below threshold, resetting stable timer"
		rm -f "$_WIS_STABLE_FILE"
		return 1
	fi

	# Stage 2: ping check
	if ! wan_is_reachable; then
		log_warn "WAN stability: ping failed — resetting stable timer"
		rm -f "$_WIS_STABLE_FILE"
		return 1
	fi

	# Both checks passed. Record or read the stable-since timestamp.
	if [ ! -f "$_WIS_STABLE_FILE" ]; then
		echo "$_WIS_NOW" > "$_WIS_STABLE_FILE"
		log_verbose "WAN stability: checks passing — stable timer started"
		return 1  # First passing run; wait for the full threshold before acting.
	fi

	_WIS_STABLE_SINCE=$(cat "$_WIS_STABLE_FILE" 2>/dev/null || echo "$_WIS_NOW")
	_WIS_STABLE_FOR=$(( _WIS_NOW - _WIS_STABLE_SINCE ))

	if [ "$_WIS_STABLE_FOR" -ge "$WAN_STABILITY_THRESHOLD" ]; then
		log_verbose "WAN stability: stable for $(format_duration "$_WIS_STABLE_FOR") — threshold met"
		return 0
	fi

	_WIS_REMAINING=$(( WAN_STABILITY_THRESHOLD - _WIS_STABLE_FOR ))
	log_verbose "WAN stability: stable for $(format_duration "$_WIS_STABLE_FOR") — threshold not yet met ($(format_duration "$_WIS_REMAINING") remaining)"
	return 1
}

wan_stable_for_seconds() {
	_WSF_STABLE_SINCE=$(cat "${STATE_DIR}/wan_stable_since" 2>/dev/null || echo 0)
	if [ "$_WSF_STABLE_SINCE" -gt 0 ] 2>/dev/null; then
		echo $(( $(date +%s) - _WSF_STABLE_SINCE ))
	else
		echo 0
	fi
}

# --- Ping verification --------------------------------------------------------
# Tries each target in PING_TARGETS through the tunnel.
# Returns 0 as soon as any target replies. All must fail to return 1.
# Each target is tried via routing table first, then interface-bound fallback.

ping_through_tunnel() {
	_PTT_IF=$1
	_PTT_TABLE=$2

	if [ "$DRY_RUN" = "1" ]; then
		log_dryrun "Would ping ${PING_TARGETS} through tunnel '${_PTT_IF}' (table: ${_PTT_TABLE:-none})"
		return 0
	fi

	for _PTT_TARGET in $PING_TARGETS; do
		[ -z "$_PTT_TARGET" ] && continue

		if [ -n "$_PTT_TABLE" ]; then
			if ip route exec table "$_PTT_TABLE" \
				ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$_PTT_TARGET" \
				> /dev/null 2>&1; then
				log_verbose "Ping verification: ${_PTT_TARGET} reachable via route table ${_PTT_TABLE}"
				return 0
			fi
		fi

		if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -I "$_PTT_IF" "$_PTT_TARGET" \
			> /dev/null 2>&1; then
			log_verbose "Ping verification: ${_PTT_TARGET} reachable via interface ${_PTT_IF}"
			return 0
		fi
	done

	return 1
}


# --- Cooldown helpers ---------------------------------------------------------

set_peer_cooldown() {
	if [ "$DRY_RUN" = "1" ]; then
		log_dryrun "Would set cooldown on peer '$(get_peer_name "$2")' for ${PEER_COOLDOWN}s"
		return
	fi
	echo "$(date +%s)" > "${STATE_DIR}/${1}.cooldown.${2}"
	log_verbose "Peer '$(get_peer_name "$2")' on '${1}' cooling down for ${PEER_COOLDOWN}s"
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

# Returns remaining cooldown seconds for a peer.
# Call only after peer_in_cooldown confirms cooldown is active.
get_cooldown_remaining() {
	echo $(( PEER_COOLDOWN - ( $(date +%s) - $(cat "${STATE_DIR}/${1}.cooldown.${2}" 2>/dev/null || echo 0) ) ))
}


# --- Rotation state helpers ---------------------------------------------------

set_last_rotate() {
	if [ "$DRY_RUN" = "1" ]; then
		log_dryrun "Would record rotation timestamp for '${1}'"
		return
	fi
	echo "$(date +%s)" > "${STATE_DIR}/${1}.last_rotate"
}

# Returns 0 if any entry in SCHEDULE_CSV is due based on LAST_EPOCH.
# SCHEDULE_CSV is comma-separated: integers = seconds interval, HH:MM = daily time.
# LABEL is used for log messages only.
schedule_due() {
	_SD_LABEL=$1
	_SD_CSV=$2
	_SD_LAST=$3

	[ -z "$_SD_CSV" ] && return 1

	_SD_NOW=$(date +%s)
	_SD_CURRENT_TIME=$(date +%H:%M)
	_SD_ELAPSED=$(( _SD_NOW - _SD_LAST ))
	_SD_DUE=1

	# Iterate CSV entries without a pipeline subshell so variables survive
	_SD_TRIGGERED=""
	_SD_OLDIFS=$IFS
	IFS=','
	for _SD_ENTRY in $_SD_CSV; do
		IFS=$_SD_OLDIFS
		_SD_ENTRY=$(printf '%s' "$_SD_ENTRY" | sed 's/^ *//;s/ *$//')
		[ -z "$_SD_ENTRY" ] && continue
		case "$_SD_ENTRY" in
			*:*)
				if [ "$_SD_CURRENT_TIME" = "$_SD_ENTRY" ] && [ "$_SD_ELAPSED" -gt 3600 ]; then
					log_verbose "Schedule '${_SD_LABEL}': due (time-of-day ${_SD_ENTRY} matched)"
					_SD_TRIGGERED="$_SD_ENTRY"
				fi
				;;
			*)
				if [ "$_SD_ELAPSED" -ge "$_SD_ENTRY" ] 2>/dev/null; then
					log_verbose "Schedule '${_SD_LABEL}': due (interval $(format_duration "$_SD_ENTRY") elapsed)"
					_SD_TRIGGERED="$_SD_ENTRY"
				fi
				;;
		esac
	done
	IFS=$_SD_OLDIFS
	[ -n "$_SD_TRIGGERED" ] && SCHEDULE_TRIGGERED_ENTRY="$_SD_TRIGGERED" && return 0
	SCHEDULE_TRIGGERED_ENTRY=""
	return 1
}

# Returns a human-readable next-due string for a schedule.
schedule_next_due() {
	_SND_CSV=$1
	_SND_LAST=$2
	_SND_NOW=$(date +%s)
	if [ "${_SND_LAST:-0}" = "0" ]; then
		_SND_ELAPSED=0
	else
		_SND_ELAPSED=$(( _SND_NOW - _SND_LAST ))
	fi
	_SND_MIN_SECS=9999999
	_SND_BEST_TEXT=""
	_SND_OVERDUE=0

	# Calculate midnight epoch once for time-of-day arithmetic
	_SND_MIDNIGHT=$(date -d "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)
	[ -z "$_SND_MIDNIGHT" ] && _SND_MIDNIGHT=0

	_OLDIFS=$IFS
	IFS=','
	for _SND_ENTRY in $_SND_CSV; do
		IFS=$_OLDIFS
		_SND_ENTRY=$(printf '%s' "$_SND_ENTRY" | sed 's/^ *//;s/ *$//')
		[ -z "$_SND_ENTRY" ] && continue

		case "$_SND_ENTRY" in
			*:*)
				# time-of-day (HH:MM)
				_SND_HOUR=${_SND_ENTRY%%:*}
				_SND_MIN=${_SND_ENTRY##*:}
				if [ "$_SND_MIDNIGHT" != "0" ] && \
				   [ -n "$_SND_HOUR" ] && [ -n "$_SND_MIN" ]; then
					_SND_TARGET_SEC=$(( _SND_HOUR * 3600 + _SND_MIN * 60 ))
					_SND_NOW_SEC=$(( _SND_NOW - _SND_MIDNIGHT ))
					if [ "$_SND_TARGET_SEC" -gt "$_SND_NOW_SEC" ]; then
						_SND_REMAINING=$(( _SND_TARGET_SEC - _SND_NOW_SEC ))
					else
						_SND_REMAINING=$(( 86400 - _SND_NOW_SEC + _SND_TARGET_SEC ))
					fi
					if [ "$_SND_REMAINING" -lt "$_SND_MIN_SECS" ]; then
						_SND_MIN_SECS=$_SND_REMAINING
						_SND_BEST_TEXT="$(format_duration $_SND_REMAINING) (at ${_SND_ENTRY})"
					fi
				fi
				;;
			*)
				# interval in seconds
				if [ "$_SND_ENTRY" -gt 0 ] 2>/dev/null; then
					_SND_REMAINING=$(( _SND_ENTRY - _SND_ELAPSED ))
					if [ "$_SND_REMAINING" -le 0 ]; then
						_SND_OVERDUE=1
					elif [ "$_SND_REMAINING" -lt "$_SND_MIN_SECS" ]; then
						_SND_MIN_SECS=$_SND_REMAINING
						_SND_TARGET_TS=$(( _SND_NOW + _SND_REMAINING ))
						_SND_TARGET_TIME=$(date -d "@$_SND_TARGET_TS" +%H:%M 2>/dev/null || echo "?")
						_SND_BEST_TEXT="$(format_duration $_SND_REMAINING) (at ${_SND_TARGET_TIME})"
					fi
				fi
				;;
		esac
	done
	IFS=$_OLDIFS

	[ "$_SND_OVERDUE" -eq 1 ] && { printf 'overdue'; return; }
	[ -n "$_SND_BEST_TEXT" ] && printf '%s' "$_SND_BEST_TEXT"
}

# Returns 0 if $1 is the last non-empty entry in CSV $2
schedule_is_last_entry() {
	_SIL_ENTRY=$1
	_SIL_CSV=$2
	_SIL_LAST=$(printf '%s\n' "$_SIL_CSV" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | tail -n1)
	[ "$_SIL_ENTRY" = "$_SIL_LAST" ]
}

# --- Peer order shuffle (random mode) -----------------------------------------
# Generates and persists a Fisher-Yates shuffled peer list for a tunnel.
# Invalidated when the pool fingerprint changes or the list is exhausted.
# State files:
#   ${IFACE}.peer_order       — space-separated shuffled peer keys
#   ${IFACE}.peer_order_hash  — fingerprint of the pool that generated it
#   ${IFACE}.peer_order_idx   — current position in the shuffled list

_peer_order_fingerprint() {
	# Stable fingerprint of an ordered peer list
	printf '%s' "$*" | awk '{for(i=1;i<=NF;i++) printf $i" "; print ""}' \
		| tr ' ' '\n' | sort | tr '\n' ',' | sed 's/,$//'
}

_shuffle_peers() {
	# Fisher-Yates shuffle via awk — no external shuf needed
	printf '%s\n' $@ | awk '
		BEGIN { srand() }
		{ lines[NR] = $0 }
		END {
			n = NR
			for (i = n; i > 1; i--) {
				j = int(rand() * i) + 1
				tmp = lines[i]; lines[i] = lines[j]; lines[j] = tmp
			}
			for (i = 1; i <= n; i++) print lines[i]
		}
	' | tr '\n' ' ' | sed 's/ $//'
}

# Returns the next peer from the persisted random shuffle for IFACE.
# Regenerates the shuffle if the pool changed or the list is exhausted.
# Falls through to empty string if no eligible peer is found.
get_next_random_peer() {
	_GRP_IFACE=$1
	_GRP_CURRENT=$2
	shift 2
	_GRP_POOL="$*"

	_GRP_ORDER_FILE="${STATE_DIR}/${_GRP_IFACE}.peer_order"
	_GRP_HASH_FILE="${STATE_DIR}/${_GRP_IFACE}.peer_order_hash"
	_GRP_IDX_FILE="${STATE_DIR}/${_GRP_IFACE}.peer_order_idx"

	_GRP_FINGERPRINT=$(_peer_order_fingerprint $_GRP_POOL)
	_GRP_SAVED_HASH=$(cat "$_GRP_HASH_FILE" 2>/dev/null || echo '')
	_GRP_SAVED_ORDER=$(cat "$_GRP_ORDER_FILE" 2>/dev/null || echo '')
	_GRP_IDX=$(cat "$_GRP_IDX_FILE" 2>/dev/null || echo 0)
	_GRP_POOL_SIZE=$(echo $_GRP_POOL | wc -w | tr -d ' ')
	_GRP_SAVED_SIZE=$(echo $_GRP_SAVED_ORDER | wc -w | tr -d ' ')

	# Force regeneration if index is out of bounds
	if [ "$_GRP_IDX" -ge "$_GRP_SAVED_SIZE" ] 2>/dev/null; then
		_GRP_REGEN=1
	else
		_GRP_REGEN=0
	fi

	# Regenerate if: pool changed, no saved order, or index forced out of bounds
	[ "$_GRP_FINGERPRINT" != "$_GRP_SAVED_HASH" ] && _GRP_REGEN=1
	[ -z "$_GRP_SAVED_ORDER" ] && _GRP_REGEN=1
	[ "$_GRP_IDX" -ge "$_GRP_SAVED_SIZE" ] 2>/dev/null && _GRP_REGEN=1

 	if [ "$_GRP_REGEN" = "1" ]; then
		if [ "$DRY_RUN" = "0" ]; then
			_GRP_SAVED_ORDER=$(_shuffle_peers $_GRP_POOL)
			_GRP_FIRST=$(echo $_GRP_SAVED_ORDER | awk '{print $1}')
			if [ "$_GRP_FIRST" = "$_GRP_CURRENT" ]; then
				_GRP_SAVED_ORDER=$(echo $_GRP_SAVED_ORDER | awk '{tmp=$1; $1=$2; $2=tmp; print}')
			fi
			printf '%s' "$_GRP_SAVED_ORDER" > "$_GRP_ORDER_FILE"
			printf '%s' "$_GRP_FINGERPRINT" > "$_GRP_HASH_FILE"
			printf '0' > "$_GRP_IDX_FILE"
			_GRP_IDX=0
			_GRP_SAVED_SIZE=$(echo $_GRP_SAVED_ORDER | wc -w | tr -d ' ')
			log_verbose "Random peer order: new shuffle for '${_GRP_IFACE}': ${_GRP_SAVED_ORDER}"
		else
			_GRP_SAVED_ORDER=$_GRP_POOL
			_GRP_IDX=0
			_GRP_SAVED_SIZE=$_GRP_POOL_SIZE
		fi

		# After a reshuffle, rebuild the walk order excluding the current peer
		# so it doesn't occupy a slot and push the saved index toward exhaustion.
		# The full order (including current peer) remains persisted on disk for
		# status display — this trimming is in-memory only for this walk.
		_GRP_WALK_ORDER=""
		for _GRP_P in $_GRP_SAVED_ORDER; do
			[ "$_GRP_P" != "$_GRP_CURRENT" ] && _GRP_WALK_ORDER="$_GRP_WALK_ORDER $_GRP_P"
		done
		_GRP_WALK_ORDER=$(printf '%s' "$_GRP_WALK_ORDER" | sed 's/^ //')
		_GRP_WALK_SIZE=$(echo $_GRP_WALK_ORDER | wc -w | tr -d ' ')
		_GRP_IDX=0
	else
		# No reshuffle — walk the full saved order from current index as normal
		_GRP_WALK_ORDER="$_GRP_SAVED_ORDER"
		_GRP_WALK_SIZE=$_GRP_SAVED_SIZE
	fi

	# Walk the list, skipping cooldown peers.
	# Current peer is already excluded from _GRP_WALK_ORDER after a reshuffle.
	# On a carried-over list (no reshuffle), it may still appear and is skipped in-memory.
	# The saved index tracks position in the full persisted list, so after a reshuffle
	# it simply counts peers selected (1 = first selected, 2 = second, etc.).
	while [ "$_GRP_IDX" -lt "$_GRP_WALK_SIZE" ]; do
		_GRP_PEER=$(echo $_GRP_WALK_ORDER | awk -v n=$((_GRP_IDX + 1)) '{print $n}')

		# Current peer guard for non-reshuffle carried-over lists
		if [ "$_GRP_PEER" = "$_GRP_CURRENT" ]; then
			_GRP_IDX=$((_GRP_IDX + 1))
			continue
		fi

		# Cooldown: skip in-memory only — temporary condition, don't burn the slot
		if peer_in_cooldown "$_GRP_IFACE" "$_GRP_PEER"; then
			_GRP_REM=$(get_cooldown_remaining "$_GRP_IFACE" "$_GRP_PEER")
			log_verbose "Random peer order: skipping '$(get_peer_name "$_GRP_PEER")' -- cooldown ${_GRP_REM}s remaining"
			_GRP_IDX=$((_GRP_IDX + 1))
			continue
		fi

		# Valid peer found: advance and persist index, then return the peer
		_GRP_IDX=$((_GRP_IDX + 1))
		[ "$DRY_RUN" = "0" ] && printf '%s' "$_GRP_IDX" > "$_GRP_IDX_FILE"
		echo "$_GRP_PEER"
		return 0
	done

	# Exhausted — mark so next call triggers a reshuffle
	[ "$DRY_RUN" = "0" ] && printf '%s' "$_GRP_SAVED_SIZE" > "$_GRP_IDX_FILE"
	echo ""
}

# Selects the next peer in sequential pool order for rotation.
# Skips peers in cooldown (unless --ignore-cooldown is active).
# Does not skip back to the current peer — if only it is left, returns empty.
get_next_rotation_peer() {
	IFACE=$1
	CURRENT=$2
	shift 2
	POOL="$*"

	eval "_GNR_ORDER=\$TUNNEL_${_TUNNEL_IDX}_PEER_ORDER"
	_GNR_ORDER="${_GNR_ORDER:-sequential}"

	if [ "$_GNR_ORDER" = "random" ]; then
		get_next_random_peer "$IFACE" "$CURRENT" $POOL
		return
	fi

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
			REMAINING=$(get_cooldown_remaining "$IFACE" "$PEER")
			log_verbose "Rotation: skipping '$(get_peer_name "$PEER")' — cooldown ${REMAINING}s remaining"
			continue
		fi
		echo "$PEER"
		return
	done

	echo ""
}


# --- Switch history -----------------------------------------------------------
# Appends one line per switch to `${IFACE}.history` for later auditing.
# Format: EPOCH|REASON|SOURCE|FROM|TO|RESULT

record_switch_history() {
	[ "$DRY_RUN" = "1" ] && return
	[ "$FLAG_EXERCISE" = "1" ] && return
	HIST_IFACE=$1
	HIST_FROM=$2
	HIST_TO=$3
	HIST_REASON=$4
	HIST_RESULT=$5
	HIST_TS=$(date +%s)
	HIST_FILE="${STATE_DIR}/${HIST_IFACE}.history"
	[ -n "$INTERACTIVE" ] && HIST_SRC="manual" || HIST_SRC="auto"
	printf '%s|%s|%s|%s|%s|%s\n' \
		"$HIST_TS" "$HIST_REASON" "$HIST_SRC" "$HIST_FROM" "$HIST_TO" "$HIST_RESULT" \
		>> "$HIST_FILE"
	# Trim history file to HISTORY_MAX_LINES if a cap is configured
	if [ "${HISTORY_MAX_LINES:-0}" -gt 0 ]; then
		_HIST_TMP=$(mktemp /tmp/wghist.XXXXXX)
		tail -n "$HISTORY_MAX_LINES" "$HIST_FILE" > "$_HIST_TMP" 2>/dev/null \
			&& mv "$_HIST_TMP" "$HIST_FILE" \
			|| rm -f "$_HIST_TMP"
	fi
}

# Records one benchmark result line for a tunnel.
# Format: EPOCH|LABEL|PEER|HOST|RESULT|MBPS|BYTES|SECS
record_benchmark_history() {
	[ "$DRY_RUN" = "1" ] && return
	_BH_IFACE=$1
	_BH_LABEL=$2
	_BH_PEER=$3
	_BH_URL=$4
	_BH_RESULT=$5
	_BH_Mbps=$6
	_BH_BYTES=$7
	_BH_SECONDS=$8
	_BH_FILE="${STATE_DIR}/benchmark_history"
	_BH_HOST=$(printf '%s' "$_BH_URL" | sed -n 's#^[a-zA-Z]*://\([^/]*\).*#\1#p')
	[ -z "$_BH_HOST" ] && _BH_HOST='unknown'
	_BH_TS=$(date +%s)
	printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
		"$_BH_TS" "$_BH_LABEL" "$_BH_PEER" "$_BH_HOST" "$_BH_RESULT" "$_BH_Mbps" "$_BH_BYTES" "$_BH_SECONDS" \
		>> "$_BH_FILE"
	# Per-peer line trimming — keeps BENCHMARK_HISTORY_MAX_LINES most recent
	# entries per peer rather than a global file cap
	if [ "${BENCHMARK_HISTORY_MAX_LINES:-0}" -gt 0 ]; then
		_BH_TMP=$(mktemp /tmp/wgbench.XXXXXX)
		awk -F'|' -v peer="$_BH_PEER" -v max="$BENCHMARK_HISTORY_MAX_LINES" '
			{ lines[NR] = $0; peers[NR] = $3 }
			END {
				# collect this peer line indices in order
				n = 0
				for (i = 1; i <= NR; i++) {
					if (peers[i] == peer) { pidx[++n] = i }
				}
				# mark oldest peer lines for removal if over limit
				del_before = (n > max) ? pidx[n - max + 1] : 0
				removed = 0
				for (i = 1; i <= NR; i++) {
					if (peers[i] == peer && removed < (n - max)) {
						removed++; continue
					}
					print lines[i]
				}
			}
		' "$_BH_FILE" > "$_BH_TMP" 2>/dev/null \
			&& mv "$_BH_TMP" "$_BH_FILE" \
			|| rm -f "$_BH_TMP"
	fi
}

# Merges legacy per-iface benchmark_history files into the single shared file.
# Runs once on startup if any legacy files are detected. Safe to call repeatedly.
migrate_benchmark_history() {
	_MBH_DONE="${STATE_DIR}/.benchmark_history_migrated"
	[ -f "$_MBH_DONE" ] && return
	_MBH_NEW="${STATE_DIR}/benchmark_history"
	_MBH_FOUND=0
	for _MBH_F in "${STATE_DIR}/"*.benchmark_history; do
		[ -f "$_MBH_F" ] || continue
		_MBH_FOUND=1
		log_info "Migrating legacy benchmark history: ${_MBH_F} -> ${_MBH_NEW}"
		cat "$_MBH_F" >> "$_MBH_NEW" 2>/dev/null
		rm -f "$_MBH_F"
	done
	if [ "$_MBH_FOUND" = "1" ]; then
		_MBH_TMP=$(mktemp /tmp/wgbenchmig.XXXXXX)
		sort -t'|' -k1,1n "$_MBH_NEW" > "$_MBH_TMP" 2>/dev/null \
			&& mv "$_MBH_TMP" "$_MBH_NEW" \
			|| rm -f "$_MBH_TMP"
		log_info "Benchmark history migration complete"
	fi
	touch "$_MBH_DONE"
}

# Returns benchmark URL for tunnel index, with per-tunnel override support.
get_benchmark_url_for_tunnel() {
	_GBU_i=$1
	eval "_GBU_OVERRIDE=\$TUNNEL_${_GBU_i}_BENCHMARK_URL"
	if [ -n "$_GBU_OVERRIDE" ]; then
		_GBU_URL=$_GBU_OVERRIDE
	else
		_GBU_URL=$BENCHMARK_URL
	fi
	_GBU_URL=$(printf '%s' "$_GBU_URL" | sed 's/^ *//;s/ *$//;s/^`//;s/`$//;s/^"//;s/"$//;s/^'\''//;s/'\''$//')
	echo "$_GBU_URL"
}

# Normalizes a benchmark speed field to a plain numeric Mbps value.
normalize_benchmark_mbps() {
	_NBM_RAW=$1
	_NBM_VAL=$(printf '%s' "$_NBM_RAW" | sed 's/^ *//;s/ *$//;s/ Mbps//g' | grep -Eo '[0-9]+(\.[0-9]+)?' | head -n1)
	[ -z "$_NBM_VAL" ] && _NBM_VAL='0.00'
	printf '%s' "$_NBM_VAL"
}

load_failover_summary_for_iface() {
	_LFS_IFACE=$1
	_LFS_NOW=$2
	_LFS_FILE="${STATE_DIR}/${_LFS_IFACE}.history"
	F_H_24=0
	F_H_30=0
	F_H_LAST_EPOCH=0
	F_H_LAST_AGO=''

	[ -f "$_LFS_FILE" ] || return 0

	_LFS_CUTOFF_24=$(( _LFS_NOW - 86400 ))
	_LFS_CUTOFF_30=$(( _LFS_NOW - 2592000 ))
	while IFS='|' read -r _LFS_EPOCH _LFS_REASON _LFS_SRC _LFS_FROM _LFS_TO _LFS_RESULT; do
		_LFS_REASON=$(printf '%s' "$_LFS_REASON" | sed 's/^ *//;s/ *$//')
		case "$_LFS_REASON" in
			*failover*) ;;
			*) continue ;;
		esac
		_LFS_EPOCH=$(printf '%s' "$_LFS_EPOCH" | sed 's/^ *//;s/ *$//')
		[ -z "$_LFS_EPOCH" ] && continue
		[ "$_LFS_EPOCH" -ge "$_LFS_CUTOFF_30" ] 2>/dev/null && F_H_30=$(( F_H_30 + 1 ))
		if [ "$_LFS_EPOCH" -ge "$_LFS_CUTOFF_24" ] 2>/dev/null; then
			F_H_24=$(( F_H_24 + 1 ))
			[ "$_LFS_EPOCH" -gt "$F_H_LAST_EPOCH" ] && F_H_LAST_EPOCH=$_LFS_EPOCH
		fi
	done < "$_LFS_FILE"
	[ "$F_H_LAST_EPOCH" -gt 0 ] 2>/dev/null && F_H_LAST_AGO=$(format_duration $(( _LFS_NOW - F_H_LAST_EPOCH )))
}

build_failover_peer_counts_for_iface() {
	_BFPC_IFACE=$1
	_BFPC_NOW=$2
	_BFPC_FILE="${STATE_DIR}/${_BFPC_IFACE}.history"
	[ -f "$_BFPC_FILE" ] || return 0
	awk -F'|' -v cutoff="$(( _BFPC_NOW - 2592000 ))" '
		$2 ~ /failover/ && ($1 + 0) >= cutoff {
			cnt[$5]++
		}
		END {
			for (peer in cnt) printf "%s|%d\n", peer, cnt[peer]
		}
	' "$_BFPC_FILE"
}

# Runs one throughput benchmark for the currently active peer on a tunnel.
run_tunnel_benchmark() {
	_RB_IFACE=$1
	_RB_WG_IF=$2
	_RB_LABEL=$3
	_RB_RT=$4
	_RB_URL=$5
	_RB_ACTIVE_PEER=$(get_active_peer "$_RB_IFACE")
	_RB_ACTIVE_NAME=$(get_peer_name "$_RB_ACTIVE_PEER")
	_RB_URL=$(printf '%s' "$_RB_URL" | sed 's/^ *//;s/ *$//;s/^`//;s/`$//;s/^"//;s/"$//;s/^'\''//;s/'\''$//')
	_RB_URL_NOCACHE="${_RB_URL}?ts=$(date +%s)"

	if [ -z "$_RB_URL" ]; then
		log_warn "Benchmark '${_RB_LABEL}': BENCHMARK_URL is empty -- skipping"
		return 1
	fi

	if ! is_tunnel_up "$_RB_IFACE"; then
		log_warn "Benchmark '${_RB_LABEL}': interface is down -- skipping"
		return 1
	fi

	_RB_CURL_OUT=$(mktemp /tmp/wgbenchcurl.XXXXXX)
	_RB_CURL_ERR=$(mktemp /tmp/wgbenchcurlerr.XXXXXX)
	_RB_RC=1
	_RB_METHOD=''

	log_info "Benchmark '${_RB_LABEL}': testing peer '${_RB_ACTIVE_NAME}'..."
	if [ -n "$_RB_RT" ]; then
		log_verbose "Benchmark '${_RB_LABEL}': attempting via route table ${_RB_RT}"
		ip route exec table "$_RB_RT" curl -L --max-time "${BENCHMARK_TIMEOUT:-30}" \
			-o /dev/null -sS -w '%{speed_download}|%{size_download}|%{time_total}' \
			"$_RB_URL_NOCACHE" > "$_RB_CURL_OUT" 2> "$_RB_CURL_ERR"
		_RB_RC=$?
		_RB_METHOD="route_table:${_RB_RT}"
		[ "$_RB_RC" -ne 0 ] && log_verbose "Benchmark '${_RB_LABEL}': using interface ${_RB_WG_IF} (route table ${_RB_RT} not used, rc=${_RB_RC})"
	fi

	if [ "$_RB_RC" -ne 0 ]; then
		log_verbose "Benchmark '${_RB_LABEL}': attempting via interface ${_RB_WG_IF}"
		curl -L --interface "$_RB_WG_IF" --max-time "${BENCHMARK_TIMEOUT:-30}" \
			-o /dev/null -sS -w '%{speed_download}|%{size_download}|%{time_total}' \
			"$_RB_URL_NOCACHE" > "$_RB_CURL_OUT" 2> "$_RB_CURL_ERR"
		_RB_RC=$?
		_RB_METHOD="iface:${_RB_WG_IF}"
	fi

	_RB_METRICS=$(cat "$_RB_CURL_OUT" 2>/dev/null || echo '')
	_RB_ERR=$(cat "$_RB_CURL_ERR" 2>/dev/null || echo '')
	rm -f "$_RB_CURL_OUT"
	rm -f "$_RB_CURL_ERR"

	if [ -z "$_RB_METRICS" ]; then
		log_fail "Benchmark '${_RB_LABEL}': peer '${_RB_ACTIVE_NAME}' failed (method ${_RB_METHOD:-unknown}, rc=${_RB_RC})"
		[ -n "$_RB_ERR" ] && log_verbose "Benchmark '${_RB_LABEL}': curl error: $_RB_ERR"
		record_benchmark_history "$_RB_IFACE" "$_RB_LABEL" "$_RB_ACTIVE_NAME" "$_RB_URL" "fail" "0.00" "0" "0.00"
		return 1
	fi

	if [ "$_RB_RC" -ne 0 ] && [ "$_RB_RC" -ne 28 ]; then
		log_fail "Benchmark '${_RB_LABEL}': peer '${_RB_ACTIVE_NAME}' failed (method ${_RB_METHOD:-unknown}, rc=${_RB_RC})"
		[ -n "$_RB_ERR" ] && log_verbose "Benchmark '${_RB_LABEL}': curl error: $_RB_ERR"
		record_benchmark_history "$_RB_IFACE" "$_RB_LABEL" "$_RB_ACTIVE_NAME" "$_RB_URL" "fail" "0.00" "0" "0.00"
		return 1
	fi

	_RB_SPEED=$(printf '%s' "$_RB_METRICS" | cut -d'|' -f1)
	_RB_BYTES=$(printf '%s' "$_RB_METRICS" | cut -d'|' -f2)
	_RB_SECS=$(printf '%s' "$_RB_METRICS" | cut -d'|' -f3)
	_RB_Mbps=$(awk -v s="${_RB_SPEED:-0}" 'BEGIN { printf "%.2f", (s*8)/1000000 }')

	_RB_BYTES_INT=$(printf '%s' "${_RB_BYTES:-0}" | cut -d'.' -f1 | tr -cd '0-9')
	_RB_BYTES_INT="${_RB_BYTES_INT:-0}"
	_RB_SECS_INT=$(printf '%s' "${_RB_SECS:-0}" | cut -d'.' -f1 | tr -cd '0-9')
	_RB_SECS_INT="${_RB_SECS_INT:-0}"

	# Minimum bytes = what 0.5 Mbps would deliver in the elapsed time, floored at 256KB.
	# This catches early disconnects (short time + tiny bytes) without penalising
	# genuinely slow peers that ran for the full timeout duration.
	_RB_MIN_BYTES=$(awk -v t="$_RB_SECS_INT" 'BEGIN { m = int(t * 62500); if (m < 262144) m = 262144; printf "%d", m }')

	log_verbose "Benchmark '${_RB_LABEL}': peer '${_RB_ACTIVE_NAME}' received ${_RB_BYTES_INT} bytes in ${_RB_SECS_INT}s (minimum: ${_RB_MIN_BYTES} bytes)"

	if [ "$_RB_BYTES_INT" -lt "$_RB_MIN_BYTES" ] 2>/dev/null; then
		log_fail "Benchmark '${_RB_LABEL}': peer '${_RB_ACTIVE_NAME}' download too small (${_RB_BYTES_INT} bytes in ${_RB_SECS_INT}s, minimum ${_RB_MIN_BYTES} bytes) -- treating as fail"
		record_benchmark_history "$_RB_IFACE" "$_RB_LABEL" "$_RB_ACTIVE_NAME" "$_RB_URL" "fail" "0.00" "$_RB_BYTES_INT" "${_RB_SECS:-0}"
		return 1
	fi

	if [ "$_RB_RC" -eq 28 ]; then
		log_verbose "Benchmark '${_RB_LABEL}': timeout reached but sufficient data received -- using available metrics"
	fi

	case "$_RB_METHOD" in
		route_table:*)
			_RB_METHOD_MSG="route table ${_RB_METHOD#route_table:}" ;;
		iface:*)
			_RB_METHOD_MSG="interface ${_RB_METHOD#iface:}" ;;
		*)
			_RB_METHOD_MSG="${_RB_METHOD:-unknown}" ;;
	esac
	log_verbose "Benchmark '${_RB_LABEL}': download complete via ${_RB_METHOD_MSG}"
	log_success "Benchmark '${_RB_LABEL}': ${_RB_Mbps} Mbps (peer '${_RB_ACTIVE_NAME}', ${_RB_BYTES:-0} bytes in ${_RB_SECS:-0}s, via ${_RB_METHOD_MSG})"
	record_benchmark_history "$_RB_IFACE" "$_RB_LABEL" "$_RB_ACTIVE_NAME" "$_RB_URL" "ok" "$_RB_Mbps" "${_RB_BYTES:-0}" "${_RB_SECS:-0}"
	[ -n "$BENCHMARK_RESULT_FILE" ] && printf '%s' "$_RB_Mbps" > "$BENCHMARK_RESULT_FILE"
	return 0
}

# Cycles through every peer in the pool for a tunnel, benchmarks each one,
# then returns to the original peer.
# Results are appended to _BS_RESULTS_FILE (one line per peer: PEER_NAME|result|mbps).
# Arguments: RESULTS_FILE IFACE WG_IF LABEL ROUTE_TABLE URL POOL...
run_full_benchmark_sweep() {
	_BS_RESULTS_FILE=$1
	_BS_IFACE=$2
	_BS_WG_IF=$3
	_BS_LABEL=$4
	_BS_RT=$5
	_BS_URL=$6
	shift 6
	_BS_POOL="$*"

	_BS_ORIGINAL_PEER=$(get_active_peer "$_BS_IFACE")
	_BS_ORIGINAL_NAME=$(get_peer_name "$_BS_ORIGINAL_PEER")

	log_info "Benchmark sweep '${_BS_LABEL}': starting -- ${_BS_ORIGINAL_NAME} is active, will visit all peers"

	# Helper: run benchmark and capture result line into results file
	_sweep_bench() {
		_SB_PEER_NAME=$1
		_SB_TMPRESULT=$(mktemp /tmp/wgbenchmbs.XXXXXX)
		BENCHMARK_RESULT_FILE="$_SB_TMPRESULT" \
			run_tunnel_benchmark "$_BS_IFACE" "$_BS_WG_IF" "$_BS_LABEL" "$_BS_RT" "$_BS_URL"
		_SB_RC=$?
		_SB_MBPS=$(cat "$_SB_TMPRESULT" 2>/dev/null || echo '')
		rm -f "$_SB_TMPRESULT"
		if [ "$_SB_RC" = "0" ] && [ -n "$_SB_MBPS" ]; then
			printf '%s|ok|%s\n' "$_SB_PEER_NAME" "$_SB_MBPS" >> "$_BS_RESULTS_FILE"
		else
			printf '%s|fail|—\n' "$_SB_PEER_NAME" >> "$_BS_RESULTS_FILE"
		fi
	}

	# Benchmark the current (original) peer first
	if [ "$DRY_RUN" = "1" ]; then
		log_dryrun "Would benchmark current peer '${_BS_ORIGINAL_NAME}' via ${_BS_URL}"
		printf '%s|dry-run|—\n' "$_BS_ORIGINAL_NAME" >> "$_BS_RESULTS_FILE"
	else
		_sweep_bench "$_BS_ORIGINAL_NAME"
	fi

	# Cycle through remaining peers
	_BS_OTHERS=''
	for _BS_PEER in $_BS_POOL; do
		[ "$_BS_PEER" = "$_BS_ORIGINAL_PEER" ] && continue
		_BS_OTHERS="$_BS_OTHERS $_BS_PEER"
	done

	for _BS_PEER in $_BS_OTHERS; do
		_BS_PEER_NAME=$(get_peer_name "$_BS_PEER")

		if [ "$DRY_RUN" = "1" ]; then
			log_dryrun "Would switch to '${_BS_PEER_NAME}' and benchmark via ${_BS_URL}"
			printf '%s|dry-run|—\n' "$_BS_PEER_NAME" >> "$_BS_RESULTS_FILE"
			continue
		fi

		log_info "Benchmark sweep '${_BS_LABEL}': switching to '${_BS_PEER_NAME}' (method: uci, ping verify: skipped)"
		if FLAG_SWITCH_METHOD='uci' switch_peer "$_BS_IFACE" "$_BS_WG_IF" "$_BS_PEER" "$_BS_ORIGINAL_NAME" "$_BS_RT" "benchmark-sweep"; then
			_sweep_bench "$_BS_PEER_NAME"
		else
			log_warn "Benchmark sweep '${_BS_LABEL}': '${_BS_PEER_NAME}' failed switch -- skipping"
			printf '%s|switch-fail|—\n' "$_BS_PEER_NAME" >> "$_BS_RESULTS_FILE"
		fi
	done

	# Restore original peer
	_BS_NOW_ACTIVE=$(get_active_peer "$_BS_IFACE")
	if [ "$DRY_RUN" = "0" ] && [ "$_BS_NOW_ACTIVE" != "$_BS_ORIGINAL_PEER" ]; then
		_BS_NOW_NAME=$(get_peer_name "$_BS_NOW_ACTIVE")
		log_info "Benchmark sweep '${_BS_LABEL}': restoring '${_BS_ORIGINAL_NAME}' (method: uci, ping verify: skipped)"
		if FLAG_SWITCH_METHOD='uci' switch_peer "$_BS_IFACE" "$_BS_WG_IF" "$_BS_ORIGINAL_PEER" "$_BS_NOW_NAME" "$_BS_RT" "benchmark-sweep-revert"; then
			log_info "Benchmark sweep '${_BS_LABEL}': restored to '${_BS_ORIGINAL_NAME}'"
		else
			log_error "Benchmark sweep '${_BS_LABEL}': failed to restore '${_BS_ORIGINAL_NAME}' -- left on '${_BS_NOW_NAME}'"
		fi
	fi
}

# Runs a benchmark sweep across all tunnel peers combined, using a single tunnel.
# Each peer is benchmarked using the URL configured for its own tunnel.
# Args: RESULTS_FILE URL
run_cross_tunnel_sweep() {
	_CTS_RESULTS=$1
	_CTS_URL=$2   # fallback only; per-peer URL resolved below

	if ! resolve_sweep_tunnel; then
		log_error "Cross-tunnel benchmark sweep: no usable tunnel found -- aborting"
		return 1
	fi

	_CTS_POOL=$(get_all_tunnel_peers)
	set -- $_CTS_POOL; _CTS_COUNT=$#

	if [ "$_CTS_COUNT" = "0" ]; then
		log_error "Cross-tunnel benchmark sweep: no peers found across any tunnel -- aborting"
		return 1
	fi

	log_info "Cross-tunnel benchmark sweep: ${_CTS_COUNT} peers across all tunnels, using tunnel '${SWEEP_LABEL}' (${SWEEP_IFACE})"

	_CTS_ORIGINAL_PEER=$(get_active_peer "$SWEEP_IFACE")
	_CTS_ORIGINAL_NAME=$(get_peer_name "$_CTS_ORIGINAL_PEER")

	# Helper: benchmark current peer on sweep tunnel, resolve URL from peer's home tunnel
	_cts_bench() {
		_CB_PEER=$1
		_CB_PEER_NAME=$(get_peer_name "$_CB_PEER")
		_CB_TIDX=$(get_tunnel_index_for_peer "$_CB_PEER")
		if [ -n "$_CB_TIDX" ]; then
			_CB_URL=$(get_benchmark_url_for_tunnel "$_CB_TIDX")
		else
			_CB_URL="$_CTS_URL"
		fi
		[ -z "$_CB_URL" ] && _CB_URL="$_CTS_URL"

		log_verbose "Cross-tunnel benchmark sweep: peer '${_CB_PEER_NAME}' using test URL: ${_CB_URL}"

		_CB_TMPRESULT=$(mktemp /tmp/wgbenchmbs.XXXXXX)
		BENCHMARK_RESULT_FILE="$_CB_TMPRESULT" \
			run_tunnel_benchmark "$SWEEP_IFACE" "$SWEEP_WG_IF" "$SWEEP_LABEL" "$SWEEP_RT" "$_CB_URL"
		_CB_RC=$?
		_CB_MBPS=$(cat "$_CB_TMPRESULT" 2>/dev/null || echo '')
		rm -f "$_CB_TMPRESULT"
		if [ "$_CB_RC" = "0" ] && [ -n "$_CB_MBPS" ]; then
			printf '%s|ok|%s\n' "$_CB_PEER_NAME" "$_CB_MBPS" >> "$_CTS_RESULTS"
		else
			printf '%s|fail|—\n' "$_CB_PEER_NAME" >> "$_CTS_RESULTS"
		fi
	}

	# Benchmark original peer first
	if [ "$DRY_RUN" = "1" ]; then
		_CTS_ORIG_TIDX=$(get_tunnel_index_for_peer "$_CTS_ORIGINAL_PEER")
		_CTS_ORIG_URL=$([ -n "$_CTS_ORIG_TIDX" ] && get_benchmark_url_for_tunnel "$_CTS_ORIG_TIDX" || echo "$_CTS_URL")
		log_dryrun "Would benchmark current peer '${_CTS_ORIGINAL_NAME}' via ${_CTS_ORIG_URL}"
		printf '%s|dry-run|—\n' "$_CTS_ORIGINAL_NAME" >> "$_CTS_RESULTS"
	else
		_cts_bench "$_CTS_ORIGINAL_PEER"
	fi

	# Cycle through remaining peers
	for _CTS_PEER in $_CTS_POOL; do
		[ "$_CTS_PEER" = "$_CTS_ORIGINAL_PEER" ] && continue
		_CTS_PEER_NAME=$(get_peer_name "$_CTS_PEER")

		if [ "$DRY_RUN" = "1" ]; then
			_CTS_TIDX=$(get_tunnel_index_for_peer "$_CTS_PEER")
			_CTS_PEER_URL=$([ -n "$_CTS_TIDX" ] && get_benchmark_url_for_tunnel "$_CTS_TIDX" || echo "$_CTS_URL")
			log_dryrun "Would switch to '${_CTS_PEER_NAME}' and benchmark via ${_CTS_PEER_URL}"
			printf '%s|dry-run|—\n' "$_CTS_PEER_NAME" >> "$_CTS_RESULTS"
			continue
		fi

		log_info "Cross-tunnel benchmark sweep: switching to '${_CTS_PEER_NAME}' (method: uci, ping verify: skipped)"
		if FLAG_SWITCH_METHOD='uci' switch_peer "$SWEEP_IFACE" "$SWEEP_WG_IF" "$_CTS_PEER" "$_CTS_ORIGINAL_NAME" "$SWEEP_RT" "benchmark-sweep"; then
			_cts_bench "$_CTS_PEER"
		else
			log_warn "Cross-tunnel benchmark sweep: '${_CTS_PEER_NAME}' failed switch -- skipping"
			printf '%s|switch-fail|—\n' "$_CTS_PEER_NAME" >> "$_CTS_RESULTS"
		fi
	done

	# Restore original peer
	_CTS_NOW_ACTIVE=$(get_active_peer "$SWEEP_IFACE")
	if [ "$DRY_RUN" = "0" ] && [ "$_CTS_NOW_ACTIVE" != "$_CTS_ORIGINAL_PEER" ]; then
		_CTS_NOW_NAME=$(get_peer_name "$_CTS_NOW_ACTIVE")
		log_info "Cross-tunnel benchmark sweep: restoring '${_CTS_ORIGINAL_NAME}' (method: uci, ping verify: skipped)"
		if FLAG_SWITCH_METHOD='uci' switch_peer "$SWEEP_IFACE" "$SWEEP_WG_IF" "$_CTS_ORIGINAL_PEER" "$_CTS_NOW_NAME" "$SWEEP_RT" "benchmark-sweep-revert"; then
			log_info "Cross-tunnel benchmark sweep: restored to '${_CTS_ORIGINAL_NAME}'"
		else
			log_error "Cross-tunnel benchmark sweep: failed to restore '${_CTS_ORIGINAL_NAME}' -- left on '${_CTS_NOW_NAME}'"
		fi
	fi
}

# Runs benchmark mode on matching tunnels without changing peers.
cmd_benchmark() {
	echo ""
	echo "==============================================="
	echo "  wg_failover.sh v${VER} -- Benchmark"
	echo "  $(date '+%Y-%m-%d %H:%M:%S')"
	if [ -n "$FLAG_BENCHMARK_IFACE" ]; then
		echo "  Scope         : tunnel with iface '${FLAG_BENCHMARK_IFACE}' only"
	elif [ -n "$FLAG_BENCHMARK_LABEL" ]; then
		echo "  Scope         : tunnel '${FLAG_BENCHMARK_LABEL}' only"
	else
		echo "  Scope         : all enabled tunnels"
	fi
	if [ "$FLAG_BENCHMARK_ALL_PEERS" = "1" ]; then
		echo "  Peers         : all peers per tunnel"
	else
		echo "  Peers         : active peer only"
	fi
	_BENCH_URL_DISPLAY=$(printf '%s' "${BENCHMARK_URL:-}" | sed 's/^ *//;s/ *$//;s/^`//;s/`$//;s/^"//;s/"$//;s/^'\''//;s/'\''$//')
	echo "  Test file URL : ${_BENCH_URL_DISPLAY:-<unset>}"
	[ "$FLAG_BENCHMARK_ALL_PEERS" = "1" ] && echo "  Mode          : ALL PEERS -- will cycle through each peer and return to original"
	[ "$DRY_RUN" = "1" ] && echo "  Mode          : DRY RUN -- no network test executed"
	echo "==============================================="
	echo ""

	# Tmpfile accumulates: TUNNEL_LABEL|PEER_NAME|result|mbps
	_CMD_B_RESULTS=$(mktemp /tmp/wgbenchresults.XXXXXX)

	TUNNELS_TESTED=0
	i=1

	# Cross-tunnel all-peer sweep: one tunnel, all peers combined
	if [ "$FLAG_BENCHMARK_ALL_PEERS" = "1" ] && \
	   [ -z "$FLAG_BENCHMARK_LABEL" ] && [ -z "$FLAG_BENCHMARK_IFACE" ] && \
	   [ -n "$BENCHMARK_SWEEP_TUNNEL" ]; then
		_B_CROSS_RESULTS=$(mktemp /tmp/wgbenchcross.XXXXXX)
		_B_CROSS_URL="${BENCHMARK_URL:-}"
		run_cross_tunnel_sweep "$_B_CROSS_RESULTS" "$_B_CROSS_URL"
		# Feed results into the main results file using sweep tunnel label
		while IFS= read -r _BCR_LINE; do
			[ -z "$_BCR_LINE" ] && continue
			printf '%s|%s\n' "$SWEEP_LABEL" "$_BCR_LINE" >> "$_CMD_B_RESULTS"
			TUNNELS_TESTED=$((TUNNELS_TESTED + 1))
		done < "$_B_CROSS_RESULTS"
		rm -f "$_B_CROSS_RESULTS"
	else
		while [ "$i" -le "$TUNNEL_COUNT" ]; do
			load_tunnel_vars "$i"

			tunnel_matches_target "$LABEL" "$IFACE" "$FLAG_BENCHMARK_LABEL" "$FLAG_BENCHMARK_IFACE"
			[ $? = "1" ] && { i=$((i + 1)); continue; }

			if [ "$ENABLED" != "1" ]; then
				log_verbose "Benchmark '${LABEL}': auto-failover disabled -- skipping"
				i=$((i + 1)); continue
			fi

			TUNNELS_TESTED=$((TUNNELS_TESTED + 1))
			_B_URL=$(get_benchmark_url_for_tunnel "$i")

			if [ "$FLAG_BENCHMARK_ALL_PEERS" = "1" ]; then
				build_tunnel_pool "$i"

				# Per-tunnel tmpfile for sweep results
				_B_SWEEP_RESULTS=$(mktemp /tmp/wgbenchsweep.XXXXXX)

				if [ "$POOL_COUNT" -lt 2 ]; then
					log_warn "Benchmark sweep '${LABEL}': only 1 peer in pool -- running single benchmark"
					_B_PEER_NAME=$(get_peer_name "$(get_active_peer "$IFACE")")
					if [ "$DRY_RUN" = "1" ]; then
						log_dryrun "Would benchmark '${_B_PEER_NAME}' via ${_B_URL}"
						printf '%s|dry-run|—\n' "$_B_PEER_NAME" >> "$_B_SWEEP_RESULTS"
					elif run_tunnel_benchmark "$IFACE" "$WG_IF" "$LABEL" "$ROUTE_TABLE" "$_B_URL"; then
						printf '%s|ok|?\n' "$_B_PEER_NAME" >> "$_B_SWEEP_RESULTS"
					else
						printf '%s|fail|—\n' "$_B_PEER_NAME" >> "$_B_SWEEP_RESULTS"
					fi
				else
					run_full_benchmark_sweep "$_B_SWEEP_RESULTS" \
						"$IFACE" "$WG_IF" "$LABEL" "$ROUTE_TABLE" "$_B_URL" $POOL
				fi

				# Merge sweep results into main results file with tunnel label prefix
				while IFS= read -r _BSR_LINE; do
					[ -z "$_BSR_LINE" ] && continue
					printf '%s|%s\n' "$LABEL" "$_BSR_LINE" >> "$_CMD_B_RESULTS"
				done < "$_B_SWEEP_RESULTS"
				rm -f "$_B_SWEEP_RESULTS"

			else
				# Single peer (active only)
				_B_PEER_NAME=$(get_peer_name "$(get_active_peer "$IFACE")")
				if [ "$DRY_RUN" = "1" ]; then
					log_dryrun "Would benchmark tunnel '${LABEL}' (peer: ${_B_PEER_NAME}) using ${_B_URL}"
					printf '%s|%s|dry-run|—\n' "$LABEL" "$_B_PEER_NAME" >> "$_CMD_B_RESULTS"
				else
					_B_SINGLE_TMPRESULT=$(mktemp /tmp/wgbenchmbs.XXXXXX)
					BENCHMARK_RESULT_FILE="$_B_SINGLE_TMPRESULT" \
						run_tunnel_benchmark "$IFACE" "$WG_IF" "$LABEL" "$ROUTE_TABLE" "$_B_URL"
					_B_SINGLE_RC=$?
					_B_SINGLE_MBPS=$(cat "$_B_SINGLE_TMPRESULT" 2>/dev/null || echo '')
					rm -f "$_B_SINGLE_TMPRESULT"
					if [ "$_B_SINGLE_RC" = "0" ] && [ -n "$_B_SINGLE_MBPS" ]; then
						printf '%s|%s|ok|%s\n' "$LABEL" "$_B_PEER_NAME" "$_B_SINGLE_MBPS" >> "$_CMD_B_RESULTS"
					else
						printf '%s|%s|fail|—\n' "$LABEL" "$_B_PEER_NAME" >> "$_CMD_B_RESULTS"
					fi
				fi
			fi

			i=$((i + 1))
		done
	fi

	# ── Summary ──────────────────────────────────────────────────────────────
	if [ "$TUNNELS_TESTED" = "0" ] && { [ -n "$FLAG_BENCHMARK_LABEL" ] || [ -n "$FLAG_BENCHMARK_IFACE" ]; }; then
		warn_no_tunnel_match "benchmark" "0" "$FLAG_BENCHMARK_LABEL" "$FLAG_BENCHMARK_IFACE"
		rm -f "$_CMD_B_RESULTS"
		return
	fi

	TOTAL_OK=0
	TOTAL_FAIL=0
	TOTAL_SKIP=0
	TOTAL_PEERS=0

	echo ""
	echo "─────────────────────────────────────────────────"
	echo "  Benchmark Summary"
	echo "─────────────────────────────────────────────────"

	_PREV_LABEL=''
	while IFS='|' read -r _S_LABEL _S_PEER _S_RESULT _S_MBPS; do
		[ -z "$_S_LABEL" ] && continue

		# Print tunnel header when label changes
		if [ "$_S_LABEL" != "$_PREV_LABEL" ]; then
			[ -n "$_PREV_LABEL" ] && echo ""
			printf "  Tunnel : %s\n" "$_S_LABEL"
			_PREV_LABEL="$_S_LABEL"
		fi

		TOTAL_PEERS=$((TOTAL_PEERS + 1))
		case "$_S_RESULT" in
			ok)
				TOTAL_OK=$((TOTAL_OK + 1))
				printf "    %-30s  %-10s  %s Mbps\n" "$_S_PEER" "[  OK  ]" "$_S_MBPS"
				;;
			fail)
				TOTAL_FAIL=$((TOTAL_FAIL + 1))
				printf "    %-30s  %-10s\n" "$_S_PEER" "[ FAIL ]"
				;;
			switch-fail)
				TOTAL_SKIP=$((TOTAL_SKIP + 1))
				printf "    %-30s  %-10s\n" "$_S_PEER" "[ SKIP - no connect ]"
				;;
			dry-run)
				printf "    %-30s  %-10s\n" "$_S_PEER" "[ DRY-RUN ]"
				;;
			*)
				printf "    %-30s  %-10s\n" "$_S_PEER" "[ ? ]"
				;;
		esac
	done < "$_CMD_B_RESULTS"

	echo ""
	echo "─────────────────────────────────────────────────"
	printf "  Tunnels : %d    Peers : %d    OK : %d    FAIL : %d" \
		"$TUNNELS_TESTED" "$TOTAL_PEERS" "$TOTAL_OK" "$TOTAL_FAIL"
	[ "$TOTAL_SKIP" -gt 0 ] && printf "    skipped : %d" "$TOTAL_SKIP"
	echo ""
	echo "─────────────────────────────────────────────────"

	rm -f "$_CMD_B_RESULTS"
}

# Builds a complete benchmark report for one tunnel.
# Output:
#   T|LAST_EPOCH|LAST_PEER|LAST_HOST|LAST_RESULT|LAST_MBPS|COUNT24|COUNT7|COUNT30|OK30|FAIL30|AVG24|AVG7|AVG30|BEST30|WORST30
#   P|STATE|PEER|LAST_EPOCH|HOST|LAST_RESULT|LAST_MBPS|COUNT24|COUNT7|COUNT30|OK30|FAIL30|AVG24|AVG7|AVG30|BEST30|WORST30|FAILOVERS30
build_benchmark_report_for_iface() {
	_BR_IFACE=$1
	_BR_NOW=$2
	_BR_PEER_FILTER="${3:-}"   # optional space-separated peer name list
	_BR_BFILE="${STATE_DIR}/benchmark_history"
	_BR_TMP=$(mktemp /tmp/wgbenchreport.XXXXXX)

	if [ -f "$_BR_BFILE" ]; then
		awk -F'|' -v now="$_BR_NOW" -v filter="$_BR_PEER_FILTER" '
			BEGIN {
				c24 = now - 86400
				c7  = now - 604800
				c30 = now - 2592000
				lastEpoch = 0
				best30 = 0
				worst30 = -1
				# Build filter lookup table; empty filter = accept all
				n = split(filter, fa, " ")
				for (i = 1; i <= n; i++) fset[fa[i]] = 1
				has_filter = (n > 0)
			}
			{
				epoch  = $1 + 0
				peer   = $3
				host   = $4
				result = $5
				mbps   = $6 + 0
				if (has_filter && !(peer in fset)) next
				if (epoch > lastEpoch) {
					lastEpoch  = epoch
					lastPeer   = peer
					lastHost   = host
					lastResult = result
					lastMbps   = sprintf("%.2f", mbps)
				}
				if (epoch < c30) next
				seen[peer] = 1
				count30++
				peerCount30[peer]++
				if (epoch > peerLastEpoch[peer]) {
					peerLastEpoch[peer]  = epoch
					peerLastHost[peer]   = host
					peerLastResult[peer] = result
					peerLastMbps[peer]   = sprintf("%.2f", mbps)
				}
				if (result == "ok") {
					ok30++
					sum30 += mbps
					if (mbps > best30) best30 = mbps
					if (worst30 < 0 || mbps < worst30) worst30 = mbps
					peerOk30[peer]++
					peerSum30[peer] += mbps
					if (mbps > peerBest30[peer]) peerBest30[peer] = mbps
					if (!(peer in peerWorst30) || mbps < peerWorst30[peer]) peerWorst30[peer] = mbps
					if (epoch >= c24) {
						count24++; sum24 += mbps
						peerCount24[peer]++; peerSum24[peer] += mbps
					}
					if (epoch >= c7) {
						count7++; sum7 += mbps
						peerCount7[peer]++; peerSum7[peer] += mbps
					}
				} else {
					fail30++
					peerFail30[peer]++
				}
			}
			END {
				avg24 = (count24 > 0 ? sum24 / count24 : 0)
				avg7  = (count7  > 0 ? sum7  / count7  : 0)
				avg30 = (ok30    > 0 ? sum30 / ok30    : 0)
				if (worst30 < 0) worst30 = 0
				printf "T|%d|%s|%s|%s|%.2f|%d|%d|%d|%d|%d|%.2f|%.2f|%.2f|%.2f|%.2f\n", \
					lastEpoch, lastPeer, lastHost, lastResult, \
					(lastEpoch > 0 ? lastMbps + 0 : 0), \
					count24+0, count7+0, count30+0, ok30+0, fail30+0, \
					avg24, avg7, avg30, best30+0, worst30+0
				for (peer in seen) {
					pavg24  = (peerCount24[peer] > 0 ? peerSum24[peer]  / peerCount24[peer] : 0)
					pavg7   = (peerCount7[peer]  > 0 ? peerSum7[peer]   / peerCount7[peer]  : 0)
					pavg30  = (peerOk30[peer]    > 0 ? peerSum30[peer]  / peerOk30[peer]    : 0)
					pbest30  = peerBest30[peer]  + 0
					pworst30 = ((peer in peerWorst30) ? peerWorst30[peer] + 0 : 0)
					printf "P|%s|%d|%s|%s|%.2f|%d|%d|%d|%d|%d|%.2f|%.2f|%.2f|%.2f|%.2f\n", \
						peer, peerLastEpoch[peer]+0, peerLastHost[peer], peerLastResult[peer], \
						peerLastMbps[peer]+0, peerCount24[peer]+0, peerCount7[peer]+0, \
						peerCount30[peer]+0, peerOk30[peer]+0, peerFail30[peer]+0, \
						pavg24, pavg7, pavg30, pbest30, pworst30
				}
			}
		' "$_BR_BFILE" > "$_BR_TMP"
	else
		printf 'T|0|||none|0.00|0|0|0|0|0|0.00|0.00|0.00|0.00|0.00\n' > "$_BR_TMP"
	fi

	_BR_TLINE=$(sed -n '1p' "$_BR_TMP")
	printf '%s\n' "$_BR_TLINE"

	_BR_FAIL_MAP=$(build_failover_peer_counts_for_iface "$_BR_IFACE" "$_BR_NOW")
	_BR_BEST_AVG=$(sed -n '2,$p' "$_BR_TMP" | sort -t'|' -k14,14nr -k9,9nr | awk -F'|' 'NR==1 { print $14; exit }')
	[ -z "$_BR_BEST_AVG" ] && _BR_BEST_AVG='0'

	sed -n '2,$p' "$_BR_TMP" | sort -t'|' -k14,14nr -k9,9nr | \
	while IFS='|' read -r _P_TAG _P_PEER _P_LAST_EPOCH _P_HOST _P_LAST_RESULT _P_LAST_MBPS \
		_P_COUNT24 _P_COUNT7 _P_COUNT30 _P_OK30 _P_FAIL30 _P_AVG24 _P_AVG7 _P_AVG30 _P_BEST30 _P_WORST30; do
		_P_FAILOVERS30=0
		if [ -n "$_BR_FAIL_MAP" ]; then
			_P_FAILOVERS30=$(printf '%s\n' "$_BR_FAIL_MAP" | awk -F'|' -v peer="$_P_PEER" '$1 == peer { print $2; exit }')
			[ -z "$_P_FAILOVERS30" ] && _P_FAILOVERS30=0
		fi
		_P_STATE=$(benchmark_peer_state "$_P_LAST_RESULT" "$_P_COUNT30" "$_P_OK30" "$_P_AVG30" "$_BR_BEST_AVG")
		printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
			"P" "$_P_STATE" "$_P_PEER" "$_P_LAST_EPOCH" "$_P_HOST" "$_P_LAST_RESULT" "$_P_LAST_MBPS" \
			"$_P_COUNT24" "$_P_COUNT7" "$_P_COUNT30" "$_P_OK30" "$_P_FAIL30" \
			"$_P_AVG24" "$_P_AVG7" "$_P_AVG30" "$_P_BEST30" "$_P_WORST30" "$_P_FAILOVERS30"
	done

	rm -f "$_BR_TMP"
}

parse_benchmark_tunnel_summary() {
	_PBTS_SUMMARY=$1
	_PBTS_NOW=${2:-0}
	IFS='|' read -r _PBTS_TAG B_T_LAST_EPOCH B_T_LAST_PEER B_T_LAST_HOST B_T_LAST_RESULT B_T_LAST_MBPS \
		B_T_COUNT24 B_T_COUNT7 B_T_COUNT30 B_T_OK30 B_T_FAIL30 B_T_AVG24 B_T_AVG7 B_T_AVG30 B_T_BEST30 B_T_WORST30 <<EOF
$_PBTS_SUMMARY
EOF
	B_T_LAST_MBPS=$(normalize_benchmark_mbps "$B_T_LAST_MBPS")
	B_T_AVG24=$(normalize_benchmark_mbps "$B_T_AVG24")
	B_T_AVG7=$(normalize_benchmark_mbps "$B_T_AVG7")
	B_T_AVG30=$(normalize_benchmark_mbps "$B_T_AVG30")
	B_T_BEST30=$(normalize_benchmark_mbps "$B_T_BEST30")
	B_T_WORST30=$(normalize_benchmark_mbps "$B_T_WORST30")
	B_T_LAST_TS=$(format_epoch_human "${B_T_LAST_EPOCH:-0}")
	B_T_LAST_AGO=''
	[ "${B_T_LAST_EPOCH:-0}" -gt 0 ] 2>/dev/null && [ "$_PBTS_NOW" -gt 0 ] 2>/dev/null && B_T_LAST_AGO=$(format_duration $(( _PBTS_NOW - B_T_LAST_EPOCH )))
}

# Args: tunnel_index now_epoch
load_benchmark_tunnel_stats() {
	parse_benchmark_tunnel_summary \
		"$(get_benchmark_report_for_tunnel_index "$1" "$2" | sed -n '1p')" "$2"
}

parse_benchmark_peer_row() {
	_PBPR_ROW=$1
	_PBPR_NOW=${2:-0}
	IFS='|' read -r _PBPR_TAG B_P_STATE B_P_PEER B_P_LAST_EPOCH B_P_HOST B_P_LAST_RESULT B_P_LAST_MBPS B_P_COUNT24 B_P_COUNT7 B_P_COUNT30 \
		B_P_OK30 B_P_FAIL30 B_P_AVG24 B_P_AVG7 B_P_AVG30 B_P_BEST30 B_P_WORST30 B_P_FAILOVERS30 <<EOF
$_PBPR_ROW
EOF
	B_P_LAST_MBPS=$(normalize_benchmark_mbps "$B_P_LAST_MBPS")
	B_P_AVG24=$(normalize_benchmark_mbps "$B_P_AVG24")
	B_P_AVG7=$(normalize_benchmark_mbps "$B_P_AVG7")
	B_P_AVG30=$(normalize_benchmark_mbps "$B_P_AVG30")
	B_P_BEST30=$(normalize_benchmark_mbps "$B_P_BEST30")
	B_P_WORST30=$(normalize_benchmark_mbps "$B_P_WORST30")
	B_P_LAST_TS=$(format_epoch_human "${B_P_LAST_EPOCH:-0}")
	B_P_LAST_AGO=''
	[ "${B_P_LAST_EPOCH:-0}" -gt 0 ] 2>/dev/null && [ "$_PBPR_NOW" -gt 0 ] 2>/dev/null && B_P_LAST_AGO=$(format_duration $(( _PBPR_NOW - B_P_LAST_EPOCH )))
}

# Returns the highest 30d peer average present in a peer-row list.
benchmark_peer_rows_best_avg() {
	_BPRB_ROWS=$1
	_BPRB_BEST='0'
	while IFS= read -r _BPRB_ROW; do
		[ -z "$_BPRB_ROW" ] && continue
		parse_benchmark_peer_row "$_BPRB_ROW"
		if awk -v a="${B_P_AVG30:-0}" -v b="${_BPRB_BEST:-0}" 'BEGIN { exit !(a>b) }'; then
			_BPRB_BEST=$B_P_AVG30
		fi
	done <<EOF
$_BPRB_ROWS
EOF
	printf '%s' "$_BPRB_BEST"
}

# Returns the terminal peer tag for a peer benchmark row.
benchmark_peer_tag() {
	_BPT_STATE=$1
	_BPT_AVG30=$2
	_BPT_BEST_AVG=$3
	if [ "$(awk -v a="${_BPT_AVG30:-0}" -v b="${_BPT_BEST_AVG:-0}" 'BEGIN { d=a-b; if(d<0)d=-d; if(d<0.01) print 1; else print 0 }')" = "1" ]; then
		printf 'BEST'
	elif [ "$_BPT_STATE" = "down" ]; then
		printf 'FAILING'
	elif [ "$_BPT_STATE" = "degraded" ]; then
		printf 'WEAK'
	fi
}

# Classifies one peer benchmark summary using the best 30d peer average in its tunnel.
benchmark_peer_state() {
	_BPS_LAST_RESULT=$1
	_BPS_COUNT_30D=$2
	_BPS_OK_30D=$3
	_BPS_AVG_30D=$4
	_BPS_BEST_REF=$5

	if [ "${_BPS_COUNT_30D:-0}" -eq 0 ] 2>/dev/null; then
		echo "unknown"
	elif [ "$_BPS_LAST_RESULT" != "ok" ]; then
		echo "down"
	elif [ "${_BPS_OK_30D:-0}" -eq 0 ] 2>/dev/null; then
		echo "degraded"
	elif [ "$(awk -v a="${_BPS_AVG_30D:-0}" -v b="${_BPS_BEST_REF:-0}" 'BEGIN { if (b>0 && a < (b*0.70)) print 1; else print 0 }')" = "1" ]; then
		echo "degraded"
	else
		echo "ok"
	fi
}

# Builds a benchmark report for tunnel index $1 at timestamp $2,
# automatically resolving the correct peer filter from the tunnel's keyword config.
get_benchmark_report_for_tunnel_index() {
	_GBRTI_IDX=$1
	_GBRTI_NOW=$2
	eval "_GBRTI_IFACE=\$TUNNEL_${_GBRTI_IDX}_IFACE"
	_GBRTI_PEERS=$(get_peers_for_tunnel_index "$_GBRTI_IDX")
	_GBRTI_PEER_NAMES=''
	for _GBRTI_P in $_GBRTI_PEERS; do
		_GBRTI_NAME=$(get_peer_name "$_GBRTI_P")
		_GBRTI_PEER_NAMES="$_GBRTI_PEER_NAMES $_GBRTI_NAME"
	done
	build_benchmark_report_for_iface "$_GBRTI_IFACE" "$_GBRTI_NOW" "$_GBRTI_PEER_NAMES"
}

# Builds benchmark summary lines for plain or rich output.
_build_benchmark_lines() {
	_BBL_NOW=$(date +%s)
	_BBL_i=1
	while [ "$_BBL_i" -le "$TUNNEL_COUNT" ]; do
		eval "_BBL_IFACE=\$TUNNEL_${_BBL_i}_IFACE"
		eval "_BBL_LABEL=\$TUNNEL_${_BBL_i}_LABEL"
		_BBL_ACTIVE_ID=$(get_active_peer "$_BBL_IFACE")
		_BBL_ACTIVE_NAME=$(get_peer_name "$_BBL_ACTIVE_ID")
		_BBL_REPORT=$(get_benchmark_report_for_tunnel_index "$_BBL_i" "$_BBL_NOW")
		parse_benchmark_tunnel_summary "$(printf '%s\n' "$_BBL_REPORT" | sed -n '1p')" "$_BBL_NOW"
		_BBL_AVG30_INT=$(awk -v x="${B_T_AVG30:-0}" 'BEGIN { printf "%.0f", x+0 }')
		printf '%s: ~%s Mbps\n' "$_BBL_LABEL" "$_BBL_AVG30_INT"
		if [ "$B_T_LAST_TS" = "none" ]; then
			printf '%s\n' '      No benchmark history'
		fi

		_PEER_ROWS=$(printf '%s\n' "$_BBL_REPORT" | sed -n '2,$p')

		while IFS= read -r _PEER_ROW; do
			[ -z "$_PEER_ROW" ] && continue
			parse_benchmark_peer_row "$_PEER_ROW" "$_BBL_NOW"
			_PLAST_MBPS_INT=$(awk -v x="${B_P_LAST_MBPS:-0}" 'BEGIN { printf "%.0f", x+0 }')
			_PAVG30_INT=$(awk -v x="${B_P_AVG30:-0}" 'BEGIN { printf "%.0f", x+0 }')
			_PTIME_LABEL=$B_P_LAST_AGO
			[ -z "$_PTIME_LABEL" ] && _PTIME_LABEL='Just Now'
			[ "$_PTIME_LABEL" = "0s" ] && _PTIME_LABEL='Just Now'
			_PSUFFIX=''
			[ "$B_P_PEER" = "$_BBL_ACTIVE_NAME" ] && _PSUFFIX=' ⬅️'
			printf '      %s%s\n' "$B_P_PEER" "$_PSUFFIX"
			printf '            30d Avg: %s Mbps\n' "$_PAVG30_INT"
			printf '            Last: %s Mbps (%s)\n' "$_PLAST_MBPS_INT" "$_PTIME_LABEL"
			[ "${B_P_FAILOVERS30:-0}" -gt 0 ] 2>/dev/null && printf '            30d Failovers: %s\n' "$B_P_FAILOVERS30"
			if [ "$B_P_LAST_RESULT" != "ok" ]; then
				printf '%s\n' '            Status: Most recent benchmark failed'
			elif [ "$B_P_STATE" = "degraded" ]; then
				printf '%s\n' '            Status: Slower than best peer'
			fi
		done <<EOF
$_PEER_ROWS
EOF
		_BBL_i=$(( _BBL_i + 1 ))
		[ "$_BBL_i" -le "$TUNNEL_COUNT" ] && printf '\n'
	done
}

send_benchmarks_webhook() {
	[ -z "$WEBHOOK_URL" ] && log_error "benchmarks --webhook: WEBHOOK_URL is not set" && return 1
	case "$WEBHOOK_PROCESSOR" in
		ntfy)   _webhook_ntfy   "benchmarks" "" "" "" ;;
		gotify) _webhook_gotify "benchmarks" "" "" "" ;;
		json)   _webhook_json   "benchmarks" "" "" "" ;;
		get)    _webhook_get    "benchmarks" "" "" "" ;;
		*)      _webhook_plain  "benchmarks" "" "" "" ;;
	esac
}

# Builds readable JSON for benchmark reports.
cmd_benchmarks_internal_json() {
	_CBJ_NOW=$(date +%s)
	printf '{\n'
	printf '  "type": "benchmarks",\n'
	printf '  "version": "%s",\n' "$VER"
	printf '  "timestamp": "%s",\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	printf '  "tunnels": [\n'
	_CBJ_FIRST=1
	_CBJ_i=1
	while [ "$_CBJ_i" -le "$TUNNEL_COUNT" ]; do
		eval "_CBJ_IFACE=\$TUNNEL_${_CBJ_i}_IFACE"
		eval "_CBJ_LABEL=\$TUNNEL_${_CBJ_i}_LABEL"
		_CBJ_REPORT=$(get_benchmark_report_for_tunnel_index "$_CBJ_i" "$_CBJ_NOW")
		parse_benchmark_tunnel_summary "$(printf '%s\n' "$_CBJ_REPORT" | sed -n '1p')" "$_CBJ_NOW"
		[ "$_CBJ_FIRST" = "0" ] && printf ',\n'
		_CBJ_FIRST=0
		printf '    {\n'
		printf '      "label": "%s",\n' "$_CBJ_LABEL"
		printf '      "iface": "%s",\n' "$_CBJ_IFACE"
		printf '      "last_ts": "%s",\n' "$B_T_LAST_TS"
		printf '      "last_peer": "%s",\n' "$B_T_LAST_PEER"
		printf '      "last_host": "%s",\n' "$B_T_LAST_HOST"
		printf '      "last_result": "%s",\n' "$B_T_LAST_RESULT"
		printf '      "last_mbps": %s,\n' "${B_T_LAST_MBPS:-0}"
		printf '      "last_ago": "%s",\n' "$B_T_LAST_AGO"
		printf '      "avg_24h": %s,\n' "${B_T_AVG24:-0}"
		printf '      "avg_7d": %s,\n' "${B_T_AVG7:-0}"
		printf '      "avg_30d": %s,\n' "${B_T_AVG30:-0}"
		printf '      "samples_30d": %s,\n' "${B_T_COUNT30:-0}"
		printf '      "ok_30d": %s,\n' "${B_T_OK30:-0}"
		printf '      "fail_30d": %s,\n' "${B_T_FAIL30:-0}"
		printf '      "best_30d": %s,\n' "${B_T_BEST30:-0}"
		printf '      "worst_30d": %s,\n' "${B_T_WORST30:-0}"
		printf '      "peers": [\n'
		_CBJ_PFIRST=1
		while IFS= read -r _PEER_ROW; do
			[ -z "$_PEER_ROW" ] && continue
			parse_benchmark_peer_row "$_PEER_ROW" "$_CBJ_NOW"
			[ "$_CBJ_PFIRST" = "0" ] && printf ',\n'
			_CBJ_PFIRST=0
			printf '        {\n'
			printf '          "peer": "%s",\n' "$B_P_PEER"
			printf '          "state": "%s",\n' "$B_P_STATE"
			printf '          "last_result": "%s",\n' "$B_P_LAST_RESULT"
			printf '          "last_mbps": %s,\n' "${B_P_LAST_MBPS:-0}"
			printf '          "last_ago": "%s",\n' "$B_P_LAST_AGO"
			printf '          "last_host": "%s",\n' "$B_P_HOST"
			printf '          "avg_24h": %s,\n' "${B_P_AVG24:-0}"
			printf '          "avg_7d": %s,\n' "${B_P_AVG7:-0}"
			printf '          "avg_30d": %s,\n' "${B_P_AVG30:-0}"
			printf '          "samples_30d": %s,\n' "${B_P_COUNT30:-0}"
			printf '          "ok_30d": %s,\n' "${B_P_OK30:-0}"
			printf '          "fail_30d": %s,\n' "${B_P_FAIL30:-0}"
			printf '          "best_30d": %s,\n' "${B_P_BEST30:-0}"
			printf '          "worst_30d": %s,\n' "${B_P_WORST30:-0}"
			printf '          "failovers_30d": %s\n' "${B_P_FAILOVERS30:-0}"
			printf '        }'
		done <<EOF
$(printf '%s\n' "$_CBJ_REPORT" | sed -n '2,$p')
EOF
		printf '\n      ]\n'
		printf '    }'
		_CBJ_i=$(( _CBJ_i + 1 ))
	done
	printf '\n  ]\n'
	printf '}\n'
}

# Prints benchmark history summaries.
cmd_benchmarks() {
	if [ "$BENCHMARKS_WEBHOOK" = "1" ]; then
		send_benchmarks_webhook
		return $?
	fi

	if [ "$BENCHMARKS_JSON" = "1" ]; then
		cmd_benchmarks_internal_json
		return 0
	fi

	_CB_NOW=$(date +%s)
	echo ""
	echo "==============================================="
	echo "  wg_failover.sh v${VER} -- Benchmarks"
	echo "  $(date '+%Y-%m-%d %H:%M:%S')"
	echo "==============================================="
	_CB_i=1
	while [ "$_CB_i" -le "$TUNNEL_COUNT" ]; do
		eval "_CB_IFACE=\$TUNNEL_${_CB_i}_IFACE"
		eval "_CB_LABEL=\$TUNNEL_${_CB_i}_LABEL"
		_CB_REPORT=$(get_benchmark_report_for_tunnel_index "$_CB_i" "$_CB_NOW")
		parse_benchmark_tunnel_summary "$(printf '%s\n' "$_CB_REPORT" | sed -n '1p')" "$_CB_NOW"
		echo ""
		printf "  [%s] ${_C_CYAN}${_C_BOLD}%s${_C_RESET} ${_C_DIM}(%s)${_C_RESET}\n" "$_CB_i" "$_CB_LABEL" "$_CB_IFACE"
		if [ "$B_T_LAST_TS" = "none" ]; then
			status_row "Benchmark" "$(badge_warn 'NO HISTORY')"
		else
			case "$B_T_LAST_RESULT" in
				ok)   _CB_LAST_FMT="$(badge_ok "${B_T_LAST_MBPS} Mbps")  ${_C_DIM}(${B_T_LAST_RESULT}, ${B_T_LAST_AGO} ago)${_C_RESET}" ;;
				fail) _CB_LAST_FMT="$(badge_err "${B_T_LAST_MBPS} Mbps")  ${_C_DIM}(${B_T_LAST_RESULT}, ${B_T_LAST_AGO} ago)${_C_RESET}" ;;
				*)    _CB_LAST_FMT="${B_T_LAST_MBPS} Mbps  ${_C_DIM}(${B_T_LAST_RESULT}, ${B_T_LAST_AGO} ago)${_C_RESET}" ;;
			esac
			status_row "Last" "$_CB_LAST_FMT"
			status_row "Peer" "${_C_CYAN}${_C_BOLD}${B_T_LAST_PEER}${_C_RESET}"
			status_row "Host" "${_C_DIM}${B_T_LAST_HOST}${_C_RESET}"
			status_row "24h Avg" "${B_T_AVG24} Mbps  ${_C_DIM}(${B_T_COUNT24} samples)${_C_RESET}"
			status_row "7d Avg" "${B_T_AVG7} Mbps  ${_C_DIM}(${B_T_COUNT7} samples)${_C_RESET}"
			status_row "30d Avg" "${B_T_AVG30} Mbps  ${_C_DIM}(${B_T_COUNT30} samples, ok=${B_T_OK30}, fail=${B_T_FAIL30})${_C_RESET}"
			status_row "30d Best" "$(badge_ok "${B_T_BEST30} Mbps")"
			status_row "30d Worst" "$(badge_warn "${B_T_WORST30} Mbps")"
			printf "  ${_C_DIM}%-14s${_C_RESET} %s\n" "Peers" ""
			_PEER_ROWS=$(printf '%s\n' "$_CB_REPORT" | sed -n '2,$p')
			_BEST_AVG30=$(benchmark_peer_rows_best_avg "$_PEER_ROWS")

			while IFS= read -r _PEER_ROW; do
				[ -z "$_PEER_ROW" ] && continue
				parse_benchmark_peer_row "$_PEER_ROW" "$_CB_NOW"
				_PTAG=$(benchmark_peer_tag "$B_P_STATE" "$B_P_AVG30" "$_BEST_AVG30")
				_TAG_COL=""
				[ -n "$_PTAG" ] && _TAG_COL="[$_PTAG]"
				case "$B_P_STATE" in
					ok)       _PPEER_FMT="${_C_GREEN}${B_P_PEER}${_C_RESET}" ;;
					degraded) _PPEER_FMT="${_C_AMBER}${B_P_PEER}${_C_RESET}" ;;
					down)     _PPEER_FMT="${_C_RED}${B_P_PEER}${_C_RESET}" ;;
					*)        _PPEER_FMT="${_C_DIM}${B_P_PEER}${_C_RESET}" ;;
				esac
				printf '      %-7s %-22s %s  30d avg %s Mbps  (ok=%s fail=%s, last=%s)\n' \
					"$_TAG_COL" "$_PPEER_FMT" "$(_state_badge "$B_P_STATE")" "$B_P_AVG30" "$B_P_OK30" "$B_P_FAIL30" "$B_P_LAST_RESULT"
			done <<EOF
$_PEER_ROWS
EOF
		fi
		_CB_i=$(( _CB_i + 1 ))
	done
	echo ""
}


# --- Stale state cleanup ------------------------------------------------------
# Removes cooldown files for peers no longer present in UCI.
# Called once during startup.

cleanup_stale_cooldowns() {
	[ "$DRY_RUN" = "1" ] && return
	KNOWN_PEERS=$(get_all_peers)
	for CFILE in "${STATE_DIR}/"*.cooldown.*; do
		[ -f "$CFILE" ] || continue
		# Extract peer ID from filename: <iface>.cooldown.<peer_id>
		CFILE_PEER=$(echo "$CFILE" | sed 's/.*\.cooldown\.//')
		FOUND=0
		for KP in $KNOWN_PEERS; do
			[ "$KP" = "$CFILE_PEER" ] && FOUND=1 && break
		done
		if [ "$FOUND" = "0" ]; then
			log_verbose "Removing stale cooldown file for unknown peer '${CFILE_PEER}': ${CFILE}"
			rm -f "$CFILE"
		fi
	done
}

# Removes stale tunnel-state files for interfaces no longer in config.
cleanup_stale_tunnel_states() {
	[ "$DRY_RUN" = "1" ] && return
	KNOWN_IFACES=''
	_CSTS_i=1
	while [ "$_CSTS_i" -le "$TUNNEL_COUNT" ]; do
		eval "_CSTS_IFACE=\$TUNNEL_${_CSTS_i}_IFACE"
		[ -n "$_CSTS_IFACE" ] && KNOWN_IFACES="${KNOWN_IFACES} ${_CSTS_IFACE}"
		_CSTS_i=$(( _CSTS_i + 1 ))
	done

	for SFILE in "${STATE_DIR}/"*.tunnel_state; do
		[ -f "$SFILE" ] || continue
		SFILE_IFACE=$(echo "$SFILE" | sed 's/.*\/\([^/]*\)\.tunnel_state$/\1/')
		FOUND=0
		for KIF in $KNOWN_IFACES; do
			[ "$KIF" = "$SFILE_IFACE" ] && FOUND=1 && break
		done
		if [ "$FOUND" = "0" ]; then
			log_verbose "Removing stale tunnel state file for unknown interface '${SFILE_IFACE}': ${SFILE}"
			rm -f "$SFILE"
		fi
	done
}


# --- Switch peer --------------------------------------------------------------
# Switches a tunnel to a new peer, waits for handshake, then verifies routing.
# Returns 0 on success, 1 on failure.
# SWITCH_REASON: 'failover', 'rotation', 'exercise', 'exercise-revert', 'revert', 'benchmark-sweep', 'benchmark-sweep-revert'
# Peer switch method is controlled by GLINET_SWITCH_METHOD (or --switch-method):
#   auto — try GL.iNet API first; fall back to uci/ubus on API failure
#   api  — GL.iNet API only; abort switch if API fails
#   uci  — direct uci/ubus only (original behaviour)

switch_peer() {
	IFACE=$1
	WG_IF=$2
	NEW_PEER=$3
	OLD_NAME=$4
	ROUTE_TABLE=$5
	SWITCH_REASON=${6:-failover}
	NEW_NAME=$(get_peer_name "$NEW_PEER")
	_SW_SWITCH_TS=$(date +%s)

	# Resolve effective switch method: CLI flag overrides config
	_SW_METHOD="${FLAG_SWITCH_METHOD:-$GLINET_SWITCH_METHOD}"
	# Default to uci if not set
	[ -z "$_SW_METHOD" ] && _SW_METHOD='uci'

	log_change "Tunnel '${IFACE}': [${SWITCH_REASON}] '${OLD_NAME}' -> '${NEW_NAME}' (method: ${_SW_METHOD})"

	if [ "$DRY_RUN" = "1" ]; then
		if [ "$_SW_METHOD" = "api" ] || [ "$_SW_METHOD" = "auto" ]; then
			log_dryrun "Would call GL.iNet API: set_tunnel for ${WG_IF} -> peer_id=$(echo "$NEW_PEER" | sed 's/^peer_//')"
			[ "$_SW_METHOD" = "auto" ] && log_dryrun "  (would fall back to uci/ubus if API fails)"
		fi
		if [ "$_SW_METHOD" = "uci" ] || [ "$_SW_METHOD" = "auto" ]; then
			log_dryrun "Would run: uci set network.${IFACE}.config=${NEW_PEER}"
			log_dryrun "Would run: uci commit network"
			log_dryrun "Would run: ubus call network.interface.${IFACE} down"
			log_dryrun "Would run: sleep 3"
			log_dryrun "Would run: ubus call network.interface.${IFACE} up"
		fi
		log_dryrun "Would poll handshake (max ${POST_SWITCH_HANDSHAKE_TIMEOUT}s) then ping ${PING_TARGETS}"
		return 0
	fi

	# ------------------------------------------------------------------
	# Attempt switch via GL.iNet dashboard API (if method is auto/api)
	# ------------------------------------------------------------------
	_SW_API_OK=0
	if [ "$_SW_METHOD" = "api" ] || [ "$_SW_METHOD" = "auto" ]; then
		if glinet_api_switch "$WG_IF" "$NEW_PEER"; then
			_SW_API_OK=1

			# First handshake wait (normal API path)
			if ! wait_for_api_switch "$WG_IF"; then
				log_warn "No handshake after API switch — forcing interface bounce"

				# --- Recovery step ---
				ubus call "network.interface.${IFACE}" down >/dev/null 2>&1
				sleep 3
				ubus call "network.interface.${IFACE}" up >/dev/null 2>&1

				# Wait again after forced restart
				if ! wait_for_handshake "$WG_IF" "$_SW_SWITCH_TS"; then
					log_warn "Handshake still missing after bounce"
					_SWITCH_FAILED=1
				fi
			fi
		else
			if [ "$_SW_METHOD" = "api" ]; then
				log_error "Tunnel '${IFACE}': GL.iNet API switch failed and method=api -- aborting switch"
				return 1
			fi
			log_warn "Tunnel '${IFACE}': GL.iNet API switch failed -- falling back to uci/ubus"
		fi
	fi

	# ------------------------------------------------------------------
	# UCI/ubus switch — runs when method=uci, or method=auto and API failed
	# ------------------------------------------------------------------
	if [ "$_SW_METHOD" = "uci" ] || { [ "$_SW_METHOD" = "auto" ] && [ "$_SW_API_OK" = "0" ]; }; then
		uci set "network.${IFACE}.config=${NEW_PEER}" || {
			log_error "Tunnel '${IFACE}': uci set failed — aborting switch"
			return 1
		}
		uci commit network || {
			log_error "Tunnel '${IFACE}': uci commit failed — config may be inconsistent"
			return 1
		}
		ubus call "network.interface.${IFACE}" down || {
			log_error "Tunnel '${IFACE}': ubus down failed"
			return 1
		}
		sleep 3
		ubus call "network.interface.${IFACE}" up || {
			log_error "Tunnel '${IFACE}': ubus up failed"
			return 1
		}
	fi

	if [ "$PING_VERIFY" = "1" ]; then
		log_info "Tunnel '${IFACE}': waiting for handshake with '${NEW_NAME}'..."
		HANDSHAKE_RESULT=$(wait_for_handshake "$WG_IF" "$_SW_SWITCH_TS")

		if [ "$HANDSHAKE_RESULT" = "timeout" ]; then
			log_warn "Tunnel '${IFACE}': handshake not seen within ${POST_SWITCH_HANDSHAKE_TIMEOUT}s — waiting ${POST_SWITCH_DELAY}s before pinging anyway"
			sleep "$POST_SWITCH_DELAY"
		else
			log_success "Tunnel '${IFACE}': handshake established in ${HANDSHAKE_RESULT}s"
		fi

		log_verbose "Tunnel '${IFACE}': running ping verification (${PING_COUNT} pings to ${PING_TARGETS})"

		if ping_through_tunnel "$WG_IF" "$ROUTE_TABLE"; then
			echo "$NEW_PEER" > "${STATE_DIR}/${IFACE}.active"
			log_success "Tunnel '${IFACE}': ping verification PASSED — '${NEW_NAME}' is working"
			record_switch_history "$IFACE" "$OLD_NAME" "$NEW_NAME" "$SWITCH_REASON" "ok"
			return 0
		else
			log_fail "Tunnel '${IFACE}': ping verification FAILED — '${NEW_NAME}' is not routing traffic"
			record_switch_history "$IFACE" "$OLD_NAME" "$NEW_NAME" "$SWITCH_REASON" "ping_failed"
			set_peer_cooldown "$IFACE" "$NEW_PEER"
			return 1
		fi
	else
		log_verbose "Tunnel '${IFACE}': ping verification disabled — waiting for handshake only"
		HANDSHAKE_RESULT=$(wait_for_handshake "$WG_IF" "$_SW_SWITCH_TS")
		if [ "$HANDSHAKE_RESULT" = "timeout" ]; then
			log_warn "Tunnel '${IFACE}': handshake not seen within ${POST_SWITCH_HANDSHAKE_TIMEOUT}s — continuing anyway"
		else
			log_verbose "Tunnel '${IFACE}': handshake established in ${HANDSHAKE_RESULT}s"
		fi
		echo "$NEW_PEER" > "${STATE_DIR}/${IFACE}.active"
		record_switch_history "$IFACE" "$OLD_NAME" "$NEW_NAME" "$SWITCH_REASON" "ok_no_ping"
		return 0
	fi
}


# --- Find next available peer (failover) --------------------------------------

get_next_available_peer() {
	IFACE=$1
	CURRENT=$2
	shift 2
	POOL="$*"

	eval "_GNA_ORDER=\$TUNNEL_${_TUNNEL_IDX}_PEER_ORDER"
	_GNA_ORDER="${_GNA_ORDER:-sequential}"

	if [ "$_GNA_ORDER" = "random" ]; then
		get_next_random_peer "$IFACE" "$CURRENT" $POOL
		return
	fi

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
		if peer_in_cooldown "$IFACE" "$PEER"; then
			REMAINING=$(get_cooldown_remaining "$IFACE" "$PEER")
			log_verbose "Skipping '$(get_peer_name "$PEER")' — cooldown ${REMAINING}s remaining"
			continue
		fi

		[ "$MAX_FAILOVER_ATTEMPTS" -gt 0 ] && [ "$ATTEMPTS" -ge "$MAX_FAILOVER_ATTEMPTS" ] && break
		ATTEMPTS=$((ATTEMPTS + 1))

		echo "$PEER"
		return
	done

	echo ""
}

# Returns ordered peer list and next-peer info for a tunnel.
# Usage: eval $(get_tunnel_order_info "$i")
# Sets: ORDER_TYPE, ORDERED_NAMES, ACTIVE_INDEX, NEXT_PEER_NAME, NEXT_IS_RESHUF
get_tunnel_order_info() {
	_TOI_IDX=$1
	load_tunnel_vars "$_TOI_IDX"
	eval "_TOI_TYPE=\$TUNNEL_${_TOI_IDX}_PEER_ORDER"
	_TOI_TYPE="${_TOI_TYPE:-sequential}"

	# Get raw peer IDs in natural pool order
	_TOI_POOL_IDS=$(get_peers_for_tunnel_index "$_TOI_IDX")
	# Convert to names preserving order
	_TOI_POOL_NAMES=""
	for _TOI_PID in $_TOI_POOL_IDS; do
		_TOI_PNAME=$(get_peer_name "$_TOI_PID")
		_TOI_POOL_NAMES="$_TOI_POOL_NAMES $_TOI_PNAME"
	done
	_TOI_POOL_NAMES=$(printf '%s' "$_TOI_POOL_NAMES" | sed 's/^ //')

	if [ "$_TOI_TYPE" = "random" ]; then
		# Try to read persisted shuffle order (peer IDs) and current index
		_TOI_ORDER_FILE="${STATE_DIR}/${IFACE}.peer_order"
		_TOI_IDX_FILE="${STATE_DIR}/${IFACE}.peer_order_idx"
		_TOI_SAVED_ORDER=$(cat "$_TOI_ORDER_FILE" 2>/dev/null || echo "")
		_TOI_CURR_IDX=$(cat "$_TOI_IDX_FILE" 2>/dev/null || echo 0)

		if [ -n "$_TOI_SAVED_ORDER" ]; then
			# Convert saved peer IDs to names
			_TOI_ORDERED_NAMES=""
			for _TOI_PID in $_TOI_SAVED_ORDER; do
				_TOI_PNAME=$(get_peer_name "$_TOI_PID")
				_TOI_ORDERED_NAMES="$_TOI_ORDERED_NAMES $_TOI_PNAME"
			done
			_TOI_ORDERED_NAMES=$(printf '%s' "$_TOI_ORDERED_NAMES" | sed 's/^ //')
		else
			# No persisted order – generate a temporary shuffled order (for display only)
			_TOI_ORDERED_NAMES=$(printf '%s\n' $_TOI_POOL_NAMES | awk '
				BEGIN { srand() }
				{ lines[NR] = $0 }
				END {
					n = NR
					for (i = n; i > 1; i--) {
						j = int(rand() * i) + 1
						tmp = lines[i]; lines[i] = lines[j]; lines[j] = tmp
					}
					for (i = 1; i <= n; i++) print lines[i]
				}
			' | tr '\n' ' ' | sed 's/ $//')
			_TOI_CURR_IDX=0
		fi

		_TOI_TOTAL=$(echo $_TOI_ORDERED_NAMES | wc -w)

		_TOI_ACTIVE_PEER=$(get_active_peer "$IFACE")
		_TOI_ACTIVE_NAME=$(get_peer_name "$_TOI_ACTIVE_PEER")

		# Locate active peer's index in the ordered list (for highlighting)
		_TOI_ACTIVE_INDEX=-1
		_TOI_IDX_COUNTER=0
		for _TOI_NAME in $_TOI_ORDERED_NAMES; do
			if [ "$_TOI_NAME" = "$_TOI_ACTIVE_NAME" ]; then
				_TOI_ACTIVE_INDEX=$_TOI_IDX_COUNTER
				break
			fi
			_TOI_IDX_COUNTER=$((_TOI_IDX_COUNTER + 1))
		done

		# Determine next peer for status display using the real persisted index,
		# not the active peer's position (which doesn't account for index drift)
		if [ "$_TOI_CURR_IDX" -ge "$_TOI_TOTAL" ] 2>/dev/null; then
			_TOI_NEXT_NAME=""
			_TOI_NEXT_IS_RESHUF=1
		else
			_TOI_NEXT_NAME=$(printf '%s\n' $_TOI_ORDERED_NAMES | sed -n "$((_TOI_CURR_IDX + 1))p")
			_TOI_NEXT_IS_RESHUF=$(( _TOI_CURR_IDX + 1 >= _TOI_TOTAL ? 1 : 0 ))
		fi
	else
		# Sequential mode: order is natural pool order, next wraps around
		_TOI_ORDERED_NAMES="$_TOI_POOL_NAMES"
		_TOI_TOTAL=$(echo $_TOI_ORDERED_NAMES | wc -w)

		_TOI_ACTIVE_PEER=$(get_active_peer "$IFACE")
		_TOI_ACTIVE_NAME=$(get_peer_name "$_TOI_ACTIVE_PEER")

		_TOI_ACTIVE_INDEX=-1
		_TOI_IDX_COUNTER=0
		for _TOI_NAME in $_TOI_ORDERED_NAMES; do
			if [ "$_TOI_NAME" = "$_TOI_ACTIVE_NAME" ]; then
				_TOI_ACTIVE_INDEX=$_TOI_IDX_COUNTER
				break
			fi
			_TOI_IDX_COUNTER=$((_TOI_IDX_COUNTER + 1))
		done

		# Next peer: wrap around (active_index+1 mod total)
		if [ "$_TOI_ACTIVE_INDEX" -ge 0 ]; then
			_TOI_NEXT_IDX=$(( (_TOI_ACTIVE_INDEX + 1) % _TOI_TOTAL ))
			_TOI_NEXT_NAME=$(printf '%s\n' $_TOI_ORDERED_NAMES | sed -n "$((_TOI_NEXT_IDX + 1))p")
			_TOI_NEXT_IS_RESHUF=0
		else
			_TOI_NEXT_NAME=""
			_TOI_NEXT_IS_RESHUF=0
		fi
	fi

	# Output variables for eval
	echo "ORDER_TYPE='$_TOI_TYPE'"
	echo "ORDERED_NAMES='$_TOI_ORDERED_NAMES'"
	echo "ACTIVE_INDEX=$_TOI_ACTIVE_INDEX"
	echo "NEXT_PEER_NAME='$_TOI_NEXT_NAME'"
	echo "NEXT_IS_RESHUF=$_TOI_NEXT_IS_RESHUF"
}

# =============================================================================
# STATUS subcommand
# =============================================================================

cmd_status() {
	NOW_EPOCH=$(date +%s)
	NOW_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')

	# --- WAN status ---
	get_wan_info

	# Run WAN checks once, reuse results for all output modes
	WAN_REACHABLE_JSON=null
	WAN_STABLE_JSON=null
	_STATUS_WAN_REACHABLE=false
	_STATUS_WAN_STABLE=false

	if [ -n "$_WAN_INFO_IFACE" ] || [ -n "$WAN_PING_TARGETS" ]; then
		if wan_is_reachable; then
			WAN_REACHABLE_JSON=true
			_STATUS_WAN_REACHABLE=true
		else
			WAN_REACHABLE_JSON=false
		fi
		if wan_is_stable; then
			WAN_STABLE_JSON=true
			_STATUS_WAN_STABLE=true
		else
			WAN_STABLE_JSON=false
		fi
	fi

	# Stable-since timestamp
	_STATUS_WAN_STABLE_SINCE=$(cat "${STATE_DIR}/wan_stable_since" 2>/dev/null || echo 0)
	_STATUS_WAN_STABLE_FOR=0
	[ "$_STATUS_WAN_STABLE_SINCE" != "0" ] && \
		_STATUS_WAN_STABLE_FOR=$(( NOW_EPOCH - _STATUS_WAN_STABLE_SINCE ))

	WAN_LAST_STATE=$(cat "${STATE_DIR}/wan_state" 2>/dev/null || echo "unknown")

	# --- GL.iNet API connectivity check (runs once, used by both outputs) ---
	_STATUS_METHOD="${FLAG_SWITCH_METHOD:-$GLINET_SWITCH_METHOD}"
	[ -z "$_STATUS_METHOD" ] && _STATUS_METHOD='uci'

	GLINET_API_ENABLED=false
	GLINET_API_REACHABLE=false
	GLINET_API_SALT=''
	GLINET_API_NONCE=''
	GLINET_API_RC=''
	GLINET_API_BODY=''
	GLINET_API_STATUS=''   # 'ok' | 'unreachable' | 'unexpected'

	if [ "$_STATUS_METHOD" = "auto" ] || [ "$_STATUS_METHOD" = "api" ]; then
		GLINET_API_ENABLED=true
		if glinet_api_challenge; then
			GLINET_API_REACHABLE=true
			GLINET_API_STATUS='ok'
			# Also attempt login so status can show whether credentials work
			if glinet_api_login; then
				GLINET_API_LOGIN_OK=true
				glinet_api_logout
			else
				GLINET_API_LOGIN_OK=false
			fi
		elif [ "$GLINET_API_RC" -ne 0 ]; then
			GLINET_API_STATUS='unreachable'
			GLINET_API_LOGIN_OK=false
		else
			GLINET_API_STATUS='unexpected'
			GLINET_API_LOGIN_OK=false
		fi
	fi

	# --- Cron health check ---
	CRON_FILE='/etc/crontabs/root'
	CRON_ENTRY=''
	CRON_SCHEDULE=''
	CRON_DAEMON_OK=false
	CRON_STATUS=''   # 'ok' | 'non_standard' | 'missing' | 'no_cron_file'

	if [ -f "$CRON_FILE" ]; then
		CRON_ENTRY=$(grep -m1 'wg_failover' "$CRON_FILE" 2>/dev/null || echo '')
		if [ -n "$CRON_ENTRY" ]; then
			CRON_SCHEDULE=$(echo "$CRON_ENTRY" | awk '{print $1,$2,$3,$4,$5}')
			if /etc/init.d/cron status >/dev/null 2>&1; then
				CRON_DAEMON_OK=true
			fi
			if [ "$CRON_SCHEDULE" = "* * * * *" ]; then
				CRON_STATUS='ok'
			else
				CRON_STATUS='non_standard'
			fi
		else
			CRON_STATUS='missing'
		fi
	else
		CRON_STATUS='no_cron_file'
	fi

	# human-readable output
	if [ "$STATUS_JSON" != "1" ] && [ "$STATUS_WEBHOOK" != "1" ]; then
		INTERACTIVE=1

		clear
		echo ""
		echo "============================================"
		echo "  wg_failover.sh v${VER} -- Status"
		echo "  $NOW_HUMAN"
		check_for_update >/dev/null 2>&1
		case "$UPDATE_CHECK_STATUS" in
			current) _UPDATE_LINE_COLOUR="${_C_GREEN}" ;;
			update)  _UPDATE_LINE_COLOUR="${_C_RED}" ;;
			*)       _UPDATE_LINE_COLOUR="${_C_AMBER}" ;;
		esac
		printf "  Update: %b%s%b\n" "$_UPDATE_LINE_COLOUR" "$UPDATE_CHECK_MESSAGE" "${_C_RESET}"
		echo "============================================"

		# ── TUNNELS ───────────────────────────────────────────────────────────
		status_section "TUNNELS"

		BLANK_KEYWORD_SEEN=0
		i=1
		while [ "$i" -le "$TUNNEL_COUNT" ]; do
			load_tunnel_vars "$i"
			eval "ROTATE=\$TUNNEL_${i}_ROTATE"

			printf "\n  ${_C_BOLD}[%s] %s${_C_RESET}  ${_C_DIM}(%s)${_C_RESET}\n" \
				"$i" "$LABEL" "$IFACE"

			if [ "$ENABLED" != "1" ]; then
				status_row "Auto-failover" "$(badge_warn 'DISABLED')"
				i=$((i + 1))
				continue
			fi

			if ! is_tunnel_up "$IFACE"; then
				status_row "Status" "$(badge_warn 'TUNNEL IS OFF')  (not monitoring)"
				i=$((i + 1))
				continue
			fi

			ACTIVE_PEER=$(get_active_peer "$IFACE")
			ACTIVE_NAME=$(get_peer_name "$ACTIVE_PEER")
			AGE=$(get_handshake_age "$WG_IF")

			ACTIVE_ENDPOINT=$(get_iface_endpoint "$WG_IF")
			[ -z "$ACTIVE_ENDPOINT" ] && ACTIVE_ENDPOINT="no session"

			if [ -z "$KEYWORD" ]; then
				KEYWORD_DESC="(blank — all unclaimed peers)"
			else
				KEYWORD_DESC="'$KEYWORD'"
			fi

			if ! build_tunnel_pool "$i"; then
				status_row "Keyword" "$(badge_err '(blank) — SKIPPED: only one blank-keyword tunnel allowed')"
				i=$((i + 1)); continue
			fi

			POOL_AVAIL=0
			ALT_AVAIL=0
			for PEER in $POOL; do
				if ! peer_in_cooldown "$IFACE" "$PEER"; then
					POOL_AVAIL=$(( POOL_AVAIL + 1 ))
					[ "$PEER" != "$ACTIVE_PEER" ] && ALT_AVAIL=$(( ALT_AVAIL + 1 ))
				fi
			done

			F24_COUNT=0
			LAST_FAILOVER_AGO=""
			load_failover_summary_for_iface "$IFACE" "$NOW_EPOCH"
			F24_COUNT=$F_H_24
			LAST_FAILOVER_AGO=$F_H_LAST_AGO

			# Handshake health
			if [ "$AGE" -eq 9999 ]; then
				HEALTH_STR="$(badge_err 'NO HANDSHAKE')"
			elif [ "$AGE" -gt "$HANDSHAKE_TIMEOUT" ]; then
				HEALTH_STR="$(badge_err "STALE — ${AGE}s")  ${_C_DIM}(threshold: ${HANDSHAKE_TIMEOUT}s)${_C_RESET}"
			else
				HEALTH_STR="$(badge_ok "OK — ${AGE}s ago")"
			fi
			if [ "$F24_COUNT" -gt 0 ] 2>/dev/null; then
				_F24_LABEL="failover"
				[ "$F24_COUNT" -ne 1 ] && _F24_LABEL="failovers"
				if [ -n "$LAST_FAILOVER_AGO" ]; then
					HEALTH_STR="${HEALTH_STR}  ${_C_DIM}(${F24_COUNT} ${_F24_LABEL} in 24h, last: ${LAST_FAILOVER_AGO} ago)${_C_RESET}"
				else
					HEALTH_STR="${HEALTH_STR}  ${_C_DIM}(${F24_COUNT} ${_F24_LABEL} in 24h)${_C_RESET}"
				fi
			fi

			# Drift warning
			STATE_PEER=$(cat "${STATE_DIR}/${IFACE}.active" 2>/dev/null || echo "")
			if [ -n "$STATE_PEER" ] && [ "$STATE_PEER" != "$ACTIVE_PEER" ]; then
				STATE_NAME=$(get_peer_name "$STATE_PEER")
				printf "  ${_C_AMBER}  ⚠  DRIFT DETECTED: state file shows '%s' but router reports '%s'${_C_RESET}\n" \
					"$STATE_NAME" "$ACTIVE_NAME"
				printf "  ${_C_AMBER}     Peer may have been changed externally — run 'reset' to clear.${_C_RESET}\n"
			fi

			status_row "Active peer" "${_C_CYAN}${_C_BOLD}${ACTIVE_NAME}${_C_RESET}  ${_C_DIM}(${ACTIVE_PEER})${_C_RESET}"
			status_row "Endpoint" "$ACTIVE_ENDPOINT"
			status_row "Handshake" "$HEALTH_STR"
			load_benchmark_tunnel_stats "$i" "$NOW_EPOCH"
			if [ "$B_T_LAST_TS" = "none" ]; then
				status_row "Benchmark" "${_C_DIM}no benchmark history${_C_RESET}"
			else
				status_row "Benchmark" "${B_T_LAST_MBPS} Mbps  ${_C_DIM}(${B_T_LAST_RESULT}, ${B_T_LAST_AGO} ago, 24h avg: ${B_T_AVG24} Mbps)${_C_RESET}"
			fi

			# Peer pool summary
			POOL_SUMMARY="${POOL_COUNT} peers  ${_C_DIM}(ready: ${POOL_AVAIL}, alternates: ${ALT_AVAIL})${_C_RESET}"
			if [ "$POOL_COUNT" -lt 1 ]; then
				POOL_SUMMARY="${POOL_SUMMARY}  $(badge_err 'NO PEERS')"
			elif [ "$POOL_COUNT" -lt 2 ]; then
				POOL_SUMMARY="${POOL_SUMMARY}  $(badge_warn 'NO FAILOVER')"
			elif [ "$ALT_AVAIL" -eq 0 ]; then
				POOL_SUMMARY="${POOL_SUMMARY}  $(badge_warn 'FAILOVER PAUSED')"
			fi
			printf "  ${_C_DIM}%-14s${_C_RESET} %b\n" "Peer pool" "$POOL_SUMMARY"

			# --- NEW: Peer order display (numbered, integrated) ---
			eval $(get_tunnel_order_info "$i")
			printf "  ${_C_DIM}%-14s${_C_RESET} %s\n" "Peer order" "$ORDER_TYPE"

						# Print numbered list according to ORDERED_NAMES
			_INDEX=1
			for _PNAME in $ORDERED_NAMES; do
				# Find peer ID for this name by scanning POOL
				_PEER=""
				for _P in $POOL; do
					if [ "$(get_peer_name "$_P")" = "$_PNAME" ]; then
						_PEER="$_P"
						break
					fi
				done
				[ -z "$_PEER" ] && _PEER="unknown"

				# Get failover count for this peer (by name)
				PEER_FO_30D=$(printf '%s\n' "$_FAILOVER_MAP" | awk -F'|' -v peer="$_PNAME" '$1 == peer { print $2; exit }')
				[ -z "$PEER_FO_30D" ] && PEER_FO_30D=0
				PEER_META="${_C_DIM}[30d failovers: ${PEER_FO_30D}]${_C_RESET}"

				# Check cooldown (by peer ID)
				if peer_in_cooldown "$IFACE" "$_PEER"; then
					REMAINING=$(get_cooldown_remaining "$IFACE" "$_PEER")
					COOLDOWN_STR="${_C_AMBER}  [cooldown: ${REMAINING}s]${_C_RESET}"
				else
					COOLDOWN_STR=""
				fi

				# Format the line
				if [ "$_PNAME" = "$ACTIVE_NAME" ]; then
					printf "    ${_C_BOLD}${_C_GREEN}%3d.  ► %s  ${_C_DIM}(%s)${_C_RESET}  %s %b\n" \
						"$_INDEX" "$_PNAME" "$_PEER" "$COOLDOWN_STR" "$PEER_META"
				else
					printf "    ${_C_DIM}%3d.  %s  (%s)${_C_RESET}  %s %b\n" \
						"$_INDEX" "$_PNAME" "$_PEER" "$COOLDOWN_STR" "$PEER_META"
				fi

				_INDEX=$((_INDEX + 1))
			done

			# Next peer line
			if [ -z "$NEXT_PEER_NAME" ]; then
				printf "  ${_C_DIM}%-14s${_C_RESET} ${_C_AMBER}New random order on next rotation/failover${_C_RESET}\n" "Next peer"
			else
				if [ "$NEXT_IS_RESHUF" = "1" ]; then
					printf "  ${_C_DIM}%-14s${_C_RESET} %s ${_C_AMBER}(will reshuffle after this)${_C_RESET}\n" "Next peer" "$NEXT_PEER_NAME"
				else
					printf "  ${_C_DIM}%-14s${_C_RESET} %s\n" "Next peer" "$NEXT_PEER_NAME"
				fi
			fi

			# Rotation
			if [ -n "$ROTATE" ]; then
				LAST_ROT=$(cat "${STATE_DIR}/${IFACE}.last_rotate" 2>/dev/null || echo 0)
				_ROT_NEXT=$(schedule_next_due "$ROTATE" "$LAST_ROT")
				if [ "$LAST_ROT" = "0" ]; then
					ROTATE_STATUS="next in ${_ROT_NEXT}"
				else
					LAST_ROT_FMT=$(date -d "@${LAST_ROT}" '+%Y-%m-%d %H:%M' 2>/dev/null \
						|| date -r "$LAST_ROT" '+%Y-%m-%d %H:%M' 2>/dev/null \
						|| echo "ts=${LAST_ROT}")
					ROTATE_STATUS="last: ${LAST_ROT_FMT}"
					if [ "$_ROT_NEXT" = "overdue" ]; then
						ROTATE_STATUS="${ROTATE_STATUS}  $(badge_warn '[OVERDUE]')"
					elif [ -n "$_ROT_NEXT" ]; then
						ROTATE_STATUS="${ROTATE_STATUS}  next in ${_ROT_NEXT}"
					fi
				fi
				status_row "Rotation" "${ROTATE}  ${_C_DIM}${ROTATE_STATUS}${_C_RESET}"
			else
				status_row "Rotation" "${_C_DIM}disabled${_C_RESET}"
			fi

			# Ping test
			if [ "$PING_VERIFY" = "1" ]; then
				_PTARGETS="$PING_TARGETS"
				printf "  ${_C_DIM}%-14s${_C_RESET} testing..." "Ping"
				PING_TMP=$(mktemp /tmp/wgping.XXXXXX)
				( ping_through_tunnel "$WG_IF" "$ROUTE_TABLE" \
					&& echo "PASS" || echo "FAIL" ) > "$PING_TMP" 2>/dev/null &
				PING_PID=$!
				wait "$PING_PID"
				PING_RESULT=$(cat "$PING_TMP" 2>/dev/null)
				rm -f "$PING_TMP"
				if [ "$PING_RESULT" = "PASS" ]; then
					_PING_STR="$(badge_ok 'PASS')"
				else
					_PING_STR="$(badge_err 'FAIL')"
				fi
				printf "\r  ${_C_DIM}%-14s${_C_RESET} %b  ${_C_DIM}%s${_C_RESET}\n" \
					"Ping" "$_PING_STR" "$_PTARGETS"
			fi

			i=$((i + 1))
		done

		# ── SYSTEM ────────────────────────────────────────────────────────────
		status_section "SYSTEM"

		# Cron
		case "$CRON_STATUS" in
			ok)
				if [ "$CRON_DAEMON_OK" = "true" ]; then
					status_row "Cron" "$(badge_ok "${CRON_SCHEDULE} — daemon running")"
				else
					status_row "Cron" "$(badge_err "${CRON_SCHEDULE} — daemon NOT running")"
				fi
				;;
			non_standard)
				if [ "$CRON_DAEMON_OK" = "true" ]; then
					status_row "Cron" "$(badge_warn "non-standard schedule (${CRON_SCHEDULE}) — daemon running")"
				else
					status_row "Cron" "$(badge_err "non-standard schedule (${CRON_SCHEDULE}) — daemon NOT running")"
				fi
				;;
			missing)
				status_row "Cron" "$(badge_err "NOT FOUND in ${CRON_FILE} — script will not run automatically")"
				;;
			no_cron_file)
				status_row "Cron" "$(badge_err "${CRON_FILE} does not exist — cron may not be configured")"
				;;
			*)
				status_row "Cron" "$(badge_warn 'unknown')"
				;;
		esac

		# Lock
		if [ -f "$LOCKFILE" ]; then
			LOCKED_PID=$(cat "$LOCKFILE" 2>/dev/null)
			if [ -n "$LOCKED_PID" ] && kill -0 "$LOCKED_PID" 2>/dev/null; then
				status_row "Lock" "$(badge_warn "active (PID ${LOCKED_PID} running)")"
			else
				status_row "Lock" "$(badge_warn "stale (PID ${LOCKED_PID} no longer exists)")"
			fi
		else
			status_row "Lock" "${_C_DIM}none${_C_RESET}"
		fi

		# WAN
		if [ -n "$_WAN_INFO_IFACE" ] || [ -n "$WAN_PING_TARGETS" ]; then
			_WAN_IFACE_DISPLAY="${_WAN_INFO_IFACE:-unknown}"
			if [ "$_STATUS_WAN_REACHABLE" = "true" ]; then
				_WAN_REACH_STR="$(badge_ok "reachable")"
			else
				_WAN_REACH_STR="$(badge_err "UNREACHABLE")"
			fi
			_WAN_CHECK_MODE="direct"
			privacy_route_enabled && _WAN_CHECK_MODE="via tunnel"
			_WAN_ROW="${_WAN_IFACE_DISPLAY} — ${_WAN_REACH_STR}  ${_C_DIM}(targets: ${WAN_PING_TARGETS:-none}, check: ${_WAN_CHECK_MODE})${_C_RESET}"
			if [ -n "$_WAN_INFO_UPTIME_SECS" ] && [ "$_WAN_INFO_UPTIME_SECS" -gt 0 ] 2>/dev/null; then
				_WAN_ROW="${_WAN_ROW}  ${_C_DIM}uptime: $(format_duration "$_WAN_INFO_UPTIME_SECS")${_C_RESET}"
			fi
			status_row "WAN" "$_WAN_ROW"
			if [ "${WAN_STABILITY_THRESHOLD:-0}" -gt 0 ]; then
				if [ "$_STATUS_WAN_STABLE" = "true" ]; then
					status_row "WAN Stability" "$(badge_ok "stable for $(format_duration "$_STATUS_WAN_STABLE_FOR")")  ${_C_DIM}(threshold: $(format_duration "$WAN_STABILITY_THRESHOLD"))${_C_RESET}"
				else
					_WAN_STAB_REMAINING=$(( WAN_STABILITY_THRESHOLD - _STATUS_WAN_STABLE_FOR ))
					[ "$_WAN_STAB_REMAINING" -lt 0 ] && _WAN_STAB_REMAINING=0
					status_row "WAN Stability" "$(badge_warn "not yet stable ($(format_duration "$_WAN_STAB_REMAINING") remaining)")  ${_C_DIM}failovers suppressed${_C_RESET}"
				fi
			fi
		else
			status_row "WAN" "${_C_DIM}disabled${_C_RESET}"
		fi

		# Switch method
		if [ "$_STATUS_METHOD" = "uci" ]; then
			status_row "Switch" "uci"
		else
			status_row "Switch" "${_STATUS_METHOD}  ${_C_DIM}(GL.iNet API: ${GLINET_ROUTER})${_C_RESET}"
		fi

		status_row "Webhook" "${WEBHOOK_URL:-${_C_DIM}disabled${_C_RESET}}"
		status_row "Log" "${LOG_FILE:-${_C_DIM}disabled${_C_RESET}}  ${_C_DIM}(level: ${LOG_LEVEL})${_C_RESET}"

		# ── GL.iNet API ───────────────────────────────────────────────────────
		if [ "$GLINET_API_ENABLED" = "true" ]; then
			status_section "GL.iNet API"
			case "$GLINET_API_STATUS" in
				ok)
					status_row "Reachable" "$(badge_ok 'YES')  ${_C_DIM}(${GLINET_ROUTER})${_C_RESET}"
					status_row "User" "$GLINET_USER"
					status_row "Challenge" "${GLINET_API_SALT} / ${GLINET_API_NONCE}"
					status_row "Login" "$([ "$GLINET_API_LOGIN_OK" = "true" ] \
						&& badge_ok 'OK — credentials valid' \
						|| badge_err 'FAILED — check GLINET_PASS')"
					;;
				unreachable)
					status_row "Reachable" "$(badge_err "NO — curl failed (rc=${GLINET_API_RC})")"
					status_row "Router" "$(badge_warn "${GLINET_ROUTER} — check GLINET_ROUTER")"
					;;
				unexpected)
					status_row "Reachable" "$(badge_warn 'YES — but unexpected response (no salt)')"
					status_row "Router" "$GLINET_ROUTER"
					status_row "Body" "$(echo "$GLINET_API_BODY" | head -c 200)"
					;;
			esac
		fi

		# ── RECENT SWITCHES ───────────────────────────────────────────────────
		HIST_LINES=""
		k=1
		while [ "$k" -le "$TUNNEL_COUNT" ]; do
			eval "H_IFACE=\$TUNNEL_${k}_IFACE"
			HFILE="${STATE_DIR}/${H_IFACE}.history"
			if [ -f "$HFILE" ]; then
				while IFS='|' read -r _HEPOCH _HREASON _HSRC _HFROM _HTO _HRESULT; do
					_HHUMAN=$(format_epoch_human "$_HEPOCH")
					HIST_LINES="${HIST_LINES}${_HEPOCH}|[${H_IFACE}] ${_HHUMAN} | ${_HREASON} | ${_HSRC} | ${_HFROM} -> ${_HTO} | ${_HRESULT}\n"
				done < "$HFILE"
			fi
			k=$((k + 1))
		done

		if [ -n "$HIST_LINES" ]; then
			status_section "RECENT SWITCHES"
			printf '%b' "$HIST_LINES" \
			| sort -t'|' -k1,1n | tail -n 10 | cut -d'|' -f2- \
			| while IFS= read -r LINE; do
				printf "  ${_C_DIM}%s${_C_RESET}\n" "$LINE"
			done
		fi

		printf "\n${_C_DIM}  ──────────────────────────────────────────────${_C_RESET}\n\n"
	fi

	# --json output (unchanged, already includes order_index in peers)
	if [ "$STATUS_JSON" = "1" ]; then
		_TS="$NOW_HUMAN"
		_EPOCH="$NOW_EPOCH"

		printf '{\n'
		printf '  "version": "%s",\n' "$VER"
		printf '  "timestamp": "%s",\n' "$_TS"

		# --- WAN ---
		printf '  "wan": {\n'
		printf '    "iface": "%s",\n' "${_WAN_INFO_IFACE:-}"
		printf '    "uptime_s": %s,\n' "${_WAN_INFO_UPTIME_SECS:-0}"
		printf '    "check_targets": "%s",\n' "$WAN_PING_TARGETS"
		printf '    "reachable": %s,\n'          "$WAN_REACHABLE_JSON"
		printf '    "stable": %s,\n'             "$WAN_STABLE_JSON"
		printf '    "stable_for_s": %s,\n'       "$_STATUS_WAN_STABLE_FOR"
		printf '    "stability_threshold_s": %s,\n' "${WAN_STABILITY_THRESHOLD:-0}"
		printf '    "check_via_tunnel": %s,\n'   "$([ "${PRIVACY_ROUTE_VIA_TUNNEL:-0}" = "1" ] && echo true || echo false)"
		printf '    "last_known_state": "%s"\n'  "$WAN_LAST_STATE"
		printf '  },\n'

		# --- Cron ---
		printf '  "cron": {\n'
		printf '    "status": "%s",\n'    "$CRON_STATUS"
		printf '    "entry": "%s",\n'     "${CRON_ENTRY:-}"
		printf '    "schedule": "%s",\n'  "${CRON_SCHEDULE:-}"
		printf '    "daemon_ok": %s\n'    "$CRON_DAEMON_OK"
		printf '  },\n'

		# --- GL.iNet API ---
		printf '  "glinet_api": {\n'
		printf '    "enabled": %s,\n'    "$GLINET_API_ENABLED"
		printf '    "method": "%s",\n'   "$_STATUS_METHOD"
		printf '    "router": "%s",\n'   "$GLINET_ROUTER"
		printf '    "user": "%s",\n'     "$GLINET_USER"
		printf '    "reachable": %s,\n'  "$GLINET_API_REACHABLE"
		printf '    "status": "%s",\n'   "${GLINET_API_STATUS:-disabled}"
		printf '    "curl_rc": %s,\n'    "${GLINET_API_RC:-null}"
		printf '    "salt": "%s",\n'     "${GLINET_API_SALT:-}"
		printf '    "nonce": "%s",\n'    "${GLINET_API_NONCE:-}"
		printf '    "hash": "%s",\n'     "${GLINET_API_HASH:-}"
		printf '    "login_ok": %s\n'     "${GLINET_API_LOGIN_OK:-false}"
		printf '  },\n'

		# --- Config snapshot ---
		printf '  "config": {\n'
		printf '    "check_interval_s": %s,\n'            "$CHECK_INTERVAL"
		printf '    "handshake_timeout_s": %s,\n'         "$HANDSHAKE_TIMEOUT"
		printf '    "peer_cooldown_s": %s,\n'             "$PEER_COOLDOWN"
		printf '    "ping_verify": %s,\n'                 "$([ "$PING_VERIFY" = "1" ] && echo true || echo false)"
		printf '    "ping_targets": "%s",\n'              "$PING_TARGETS"
		printf '    "ping_count": %s,\n'                  "$PING_COUNT"
		printf '    "ping_timeout_s": %s,\n'              "$PING_TIMEOUT"
		printf '    "post_switch_handshake_timeout_s": %s,\n' "$POST_SWITCH_HANDSHAKE_TIMEOUT"
		printf '    "wan_stability_threshold_s": %s,\n'   "${WAN_STABILITY_THRESHOLD:-0}"
		printf '    "privacy_route_via_tunnel": %s,\n'    "$([ "${PRIVACY_ROUTE_VIA_TUNNEL:-0}" = "1" ] && echo true || echo false)"
		printf '    "webhook_repeat_interval_s": %s,\n'   "${WEBHOOK_REPEAT_INTERVAL:-300}"
		printf '    "history_max_lines": %s,\n'           "${HISTORY_MAX_LINES:-0}"
		printf '    "log_level": %s\n'                    "$LOG_LEVEL"
		printf '  },\n'

		# --- Tunnels ---
		printf '  "tunnels": [\n'
		_TFIRST=1
		j=1
		while [ "$j" -le "$TUNNEL_COUNT" ]; do
			eval "_J_IFACE=\$TUNNEL_${j}_IFACE"
			eval "_J_WG_IF=\$TUNNEL_${j}_WG_IF"
			eval "_J_LABEL=\$TUNNEL_${j}_LABEL"
			eval "_J_ENABLED=\$TUNNEL_${j}_FAILOVER_ENABLED"
			eval "_J_KEYWORD=\$TUNNEL_${j}_KEYWORD"
			eval "_J_RT=\$TUNNEL_${j}_ROUTE_TABLE"
			eval "_J_ROTATE=\$TUNNEL_${j}_ROTATE"

			[ "$_TFIRST" = "0" ] && printf ',\n'
			_TFIRST=0

			_J_ACTIVE=$(uci get "network.${_J_IFACE}.config" 2>/dev/null || echo "")
			_J_ANAME=$(get_peer_name "$_J_ACTIVE")
			_J_HS_AGE=$(get_handshake_age "$_J_WG_IF")
			_J_UP=$(is_tunnel_up "$_J_IFACE" && echo true || echo false)

			_J_ENDPOINT=$(get_iface_endpoint "$_J_WG_IF")
			[ -z "$_J_ENDPOINT" ] && _J_ENDPOINT="no session"

			# Drift detection
			_J_STATE_PEER=$(cat "${STATE_DIR}/${_J_IFACE}.active" 2>/dev/null || echo "")
			_J_DRIFT=false
			[ -n "$_J_STATE_PEER" ] && [ "$_J_STATE_PEER" != "$_J_ACTIVE" ] && _J_DRIFT=true

			# Rotation
			_J_LAST_ROT=$(cat "${STATE_DIR}/${_J_IFACE}.last_rotate" 2>/dev/null || echo 0)
			_J_ROT_ELAPSED=$(( _EPOCH - _J_LAST_ROT ))
			_J_ROT_NEXT_S=null
			_J_ROT_NEXT_STR=""
			if [ -n "$_J_ROTATE" ]; then
				_J_ROT_NEXT_STR=$(schedule_next_due "$_J_ROTATE" "$_J_LAST_ROT")
			fi

			# Ping test
			_J_PING_RESULT=null
			if [ "$PING_VERIFY" = "1" ]; then
				_J_PT=$(mktemp /tmp/wgjsonping.XXXXXX)
				( ping_through_tunnel "$_J_WG_IF" "$_J_RT" \
					&& echo true || echo false ) > "$_J_PT" 2>/dev/null
				_J_PING_RESULT=$(cat "$_J_PT" 2>/dev/null || echo null)
				rm -f "$_J_PT"
			fi

			# --- Peer order info for JSON ---
			eval $(get_tunnel_order_info "$j")

			printf '    {\n'
			printf '      "label": "%s",\n'          "$_J_LABEL"
			printf '      "iface": "%s",\n'          "$_J_IFACE"
			printf '      "wg_if": "%s",\n'          "$_J_WG_IF"
			printf '      "keyword": "%s",\n'        "${_J_KEYWORD:-}"
			printf '      "route_table": "%s",\n'    "${_J_RT:-}"
			printf '      "enabled": %s,\n'          "$([ "$_J_ENABLED" = "1" ] && echo true || echo false)"
			printf '      "up": %s,\n'               "$_J_UP"
			printf '      "state_drift": %s,\n'      "$_J_DRIFT"
			printf '      "active_peer_id": "%s",\n' "$_J_ACTIVE"
			printf '      "active_peer_name": "%s",\n' "$_J_ANAME"
			printf '      "endpoint": "%s",\n' "$_J_ENDPOINT"
			printf '      "handshake_age_s": %s,\n'  \
				"$([ "$_J_HS_AGE" -eq 9999 ] && echo null || echo "$_J_HS_AGE")"
			printf '      "ping_ok": %s,\n'          "$_J_PING_RESULT"
			printf '      "last_rotated_epoch": %s,\n' \
				"$([ "$_J_LAST_ROT" -eq 0 ] && echo null || echo "$_J_LAST_ROT")"
			printf '      "rotation_schedule": "%s",\n' "${_J_ROTATE:-}"
			printf '      "rotation_next": "%s",\n'    "${_J_ROT_NEXT_STR:-}"
			printf '      "peer_order_type": "%s",\n'  "$ORDER_TYPE"
			printf '      "next_peer_in_order": "%s",\n' "$NEXT_PEER_NAME"
			printf '      "peers": [\n'

			# Build peer pool
			if [ -z "$_J_KEYWORD" ]; then
				_J_POOL=$(get_peers_excluding_other_keywords "$j")
			else
				_J_POOL=$(get_peers_for_keyword "$_J_KEYWORD")
			fi

			_PFIRST=1
			for _JP in $_J_POOL; do
				_JP_NAME=$(get_peer_name "$_JP")
				_JP_ACTIVE=false
				[ "$_JP" = "$_J_ACTIVE" ] && _JP_ACTIVE=true
				_JP_COOLDOWN=false
				_JP_COOLDOWN_REM=0
				if peer_in_cooldown "$_J_IFACE" "$_JP"; then
					_JP_COOLDOWN=true
					_JP_COOLDOWN_REM=$(get_cooldown_remaining "$_J_IFACE" "$_JP")
				fi
				[ "$_PFIRST" = "0" ] && printf ',\n'
				_PFIRST=0

				# Determine order index for this peer
				_ORD_IDX=-1
				_CNT=0
				for _OP in $ORDERED_NAMES; do
					if [ "$_OP" = "$_JP_NAME" ]; then
						_ORD_IDX=$_CNT
						break
					fi
					_CNT=$((_CNT + 1))
				done

				printf '        {\n'
				printf '          "id": "%s",\n'             "$_JP"
				printf '          "name": "%s",\n'           "$_JP_NAME"
				printf '          "active": %s,\n'           "$_JP_ACTIVE"
				printf '          "order_index": %s,\n'      "$_ORD_IDX"
				printf '          "in_cooldown": %s,\n'      "$_JP_COOLDOWN"
				printf '          "cooldown_remaining_s": %s\n' "$_JP_COOLDOWN_REM"
				printf '        }'
			done
			printf '\n      ]\n'
			printf '    }'
			j=$((j + 1))
		done
		printf '\n  ],\n'

		# --- Recent history ---
		printf '  "recent_history": [\n'
		_HALL=""
		k=1
		while [ "$k" -le "$TUNNEL_COUNT" ]; do
			eval "_H_IFACE=\$TUNNEL_${k}_IFACE"
			_HF="${STATE_DIR}/${_H_IFACE}.history"
			if [ -f "$_HF" ]; then
				_HALL="${_HALL}$(sed "s/^/${_H_IFACE}|/" "$_HF")\n"
			fi
			k=$((k + 1))
		done
		_HFIRST=1
		printf '%b' "$_HALL" \
		| awk -F'|' '{
			ts = $2 + 0;
			print ts "|" $0
		}' \
		| sort -t"|" -k1,1n \
		| tail -n 20 \
		| cut -d'|' -f2- \
		| while IFS='|' read -r _HIFACE _HEPOCH _HREASON _HSRC _HFROM _HTO _HRESULT; do
			_HTS=$(format_epoch_human "$_HEPOCH")
			_HREASON=$(echo "$_HREASON" | sed 's/^ *//;s/ *$//')
			_HSRC=$(echo "$_HSRC" | sed 's/^ *//;s/ *$//')
			_HRESULT=$(echo "$_HRESULT" | sed 's/^ *//;s/ *$//')
			_HFROM=$(echo "$_HFROM" | sed 's/^ *//;s/ *$//')
			_HTO=$(echo "$_HTO" | sed 's/^ *//;s/ *$//')
			[ "$_HFIRST" = "0" ] && printf ',\n'
			_HFIRST=0
			printf '    {"iface":"%s","timestamp":"%s","reason":"%s","source":"%s","from":"%s","to":"%s","result":"%s"}' \
				"$_HIFACE" "$_HTS" "$_HREASON" "$_HSRC" "$_HFROM" "$_HTO" "$_HRESULT"
		done
		printf '\n  ]\n'
		printf '}\n'
	fi

	if [ "$STATUS_WEBHOOK" = "1" ]; then
		send_status_webhook
		exit 0
	fi
}

# =============================================================================
# RESET subcommand
# =============================================================================

cmd_reset() {
	INTERACTIVE=1
	# Warn if a live run is holding the lock
	if [ -f "$LOCKFILE" ]; then
		LOCKED_PID=$(cat "$LOCKFILE" 2>/dev/null)
		if [ -n "$LOCKED_PID" ] && kill -0 "$LOCKED_PID" 2>/dev/null; then
			echo "Warning: a failover run (PID ${LOCKED_PID}) is currently active."
			echo "Resetting state while it runs may cause a double-switch on next cron tick."
			echo "Proceeding in 5 seconds — press Ctrl-C to abort..."
			sleep 5
		fi
	fi

	if [ "$RESET_KEEP_HISTORY" = "1" ]; then
		echo "Clearing wg_failover state (cooldowns, run timer, rotation timestamps, webhook state, lockfile)..."
		echo "Switch and benchmark history files will be preserved (--keep-history)."
		# Remove everything except .history and .benchmark_history files
		for _F in "${STATE_DIR}/"*; do
			[ -f "$_F" ] || continue
			case "$_F" in
				*.history|*/benchmark_history) continue ;;
			esac
			rm -f "$_F"
		done
	else
		echo "Clearing all wg_failover state (cooldowns, run timer, rotation timestamps, lockfile, history)..."
		echo "To preserve switch and benchmark history, use: reset --keep-history"
		rm -f "${STATE_DIR}/"* 2>/dev/null
	fi

	echo "Done. Peer selections are unchanged -- only monitoring state was reset."
	echo "The next cron run will perform a fresh check immediately."
}


# =============================================================================
# EXERCISE mode  (--exercise [label])
# =============================================================================
# Performs a verified forward and return switch on each tunnel.
# Always reverts; this mode is for testing.
# Respects --ignore-cooldown and --dry-run.
# Webhooks are suppressed and log file writes are skipped.

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

	set -- $POOL; POOL_COUNT=$#
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

	# Pick the first peer in the pool that is not current and not in cooldown.
	# --ignore-cooldown is handled inside peer_in_cooldown.
	NEXT_PEER=''
	for PEER in $POOL; do
		[ "$PEER" = "$ORIGINAL_PEER" ] && continue
		if peer_in_cooldown "$IFACE" "$PEER"; then
			REMAINING=$(get_cooldown_remaining "$IFACE" "$PEER")
			test_warn "Skipping '$(get_peer_name "$PEER")' -- cooldown ${REMAINING}s remaining"
			continue
		fi
		NEXT_PEER="$PEER"
		break
	done

	if [ -z "$NEXT_PEER" ]; then
		test_fail "Could not find an alternative peer to switch to (all in cooldown?)"
		[ "$FLAG_IGNORE_COOLDOWN" = "0" ] && test_info "Hint: use --ignore-cooldown to bypass"
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
	echo "==============================================="
	echo "  wg_failover.sh v${VER} -- Exercise Mode"
	echo "  $(date '+%Y-%m-%d %H:%M:%S')"
	if [ -n "$FLAG_EXERCISE_IFACE" ]; then
		echo "  Scope         : tunnel with iface '${FLAG_EXERCISE_IFACE}' only"
	elif [ -n "$FLAG_EXERCISE_LABEL" ]; then
		echo "  Scope         : tunnel '${FLAG_EXERCISE_LABEL}' only"
	else
		echo "  Scope         : all enabled tunnels"
	fi
	[ "$FLAG_IGNORE_COOLDOWN" = "1" ] && echo "  Cooldown      : BYPASSED (--ignore-cooldown)"
	[ "$DRY_RUN" = "1" ]             && echo "  Mode          : DRY RUN -- no real changes"
	echo "  Note          : webhooks suppressed, log not written"
	echo "==============================================="

	BLANK_KEYWORD_SEEN=0
	TUNNELS_TESTED=0

	i=1
	while [ "$i" -le "$TUNNEL_COUNT" ]; do
		load_tunnel_vars "$i"

		tunnel_matches_target "$LABEL" "$IFACE" "$FLAG_EXERCISE_LABEL" "$FLAG_EXERCISE_IFACE"
		[ $? = "1" ] && { i=$((i + 1)); continue; }

		build_tunnel_pool "$i" || { i=$((i + 1)); continue; }

		run_exercise_tunnel "$IFACE" "$WG_IF" "$LABEL" "$ROUTE_TABLE" "$POOL"
		TUNNELS_TESTED=$((TUNNELS_TESTED + 1))

		i=$((i + 1))
	done

	echo "==============================================="
	echo "  Exercise Summary"
	echo "  Tunnels tested : $TUNNELS_TESTED"
	echo "  Checks passed  : $TEST_PASS"
	echo "  Checks failed  : $TEST_FAIL"
	if [ "$TEST_FAIL" -eq 0 ] && [ "$TUNNELS_TESTED" -gt 0 ]; then
		echo "  Result         : ALL PASSED"
	elif [ "$TUNNELS_TESTED" -eq 0 ]; then
		echo "  Result         : NO TUNNELS TESTED"
		warn_no_tunnel_match "exercise" "0" "$FLAG_EXERCISE_LABEL" "$FLAG_EXERCISE_IFACE"
	else
		echo "  Result         : FAILED ($TEST_FAIL check(s) did not pass)"
	fi
	echo "==============================================="
	echo ""

	[ "$TEST_FAIL" -gt 0 ] && exit 1
	exit 0
}


# =============================================================================
# FORCE-ROTATE mode  (--force-rotate [label])
# =============================================================================
# Immediately rotates each tunnel to its next peer without faking a failure.
# Respects --ignore-cooldown and --dry-run. Webhooks fire normally.

cmd_force_rotate() {
	echo ""
	echo "==============================================="
	echo "  wg_failover.sh v${VER} -- Force Rotate"
	echo "  $(date '+%Y-%m-%d %H:%M:%S')"
	if [ -n "$FLAG_FORCE_ROTATE_IFACE" ]; then
		echo "  Scope         : tunnel with iface '${FLAG_FORCE_ROTATE_IFACE}' only"
	elif [ -n "$FLAG_FORCE_ROTATE_LABEL" ]; then
		echo "  Scope         : tunnel '${FLAG_FORCE_ROTATE_LABEL}' only"
	else
		echo "  Scope         : all enabled tunnels"
	fi
	[ "$FLAG_IGNORE_COOLDOWN" = "1" ] && echo "  Cooldown      : BYPASSED (--ignore-cooldown)"
	[ "$DRY_RUN" = "1" ]              && echo "  Mode          : DRY RUN -- no real changes"
	echo "==============================================="
	echo ""

	BLANK_KEYWORD_SEEN=0
	ROTATED=0

	i=1
	while [ "$i" -le "$TUNNEL_COUNT" ]; do
		load_tunnel_vars "$i"

		tunnel_matches_target "$LABEL" "$IFACE" "$FLAG_FORCE_ROTATE_LABEL" "$FLAG_FORCE_ROTATE_IFACE"
		[ $? = "1" ] && { i=$((i + 1)); continue; }

		if ! is_tunnel_up "$IFACE"; then
			log_warn "Tunnel '${LABEL}' (${IFACE}): interface is off -- skipping"
			i=$((i + 1)); continue
		fi

		build_tunnel_pool "$i" || { i=$((i + 1)); continue; }
		if [ "$POOL_COUNT" -lt 2 ]; then
			log_warn "Tunnel '${LABEL}' (${IFACE}): only 1 peer in pool -- cannot rotate"
			i=$((i + 1))
			continue
		fi

		ACTIVE_PEER=$(get_active_peer "$IFACE")
		ACTIVE_NAME=$(get_peer_name "$ACTIVE_PEER")

		_TUNNEL_IDX=$i
		NEXT_PEER=$(get_next_rotation_peer "$IFACE" "$ACTIVE_PEER" $POOL)

		if [ -z "$NEXT_PEER" ]; then
			log_warn "Tunnel '${LABEL}': all peers in cooldown -- cannot force-rotate (try --ignore-cooldown)"
		else
			NEXT_NAME=$(get_peer_name "$NEXT_PEER")
			log_change "Tunnel '${LABEL}': force-rotate -- '${ACTIVE_NAME}' -> '${NEXT_NAME}'"
			if switch_peer "$IFACE" "$WG_IF" "$NEXT_PEER" "$ACTIVE_NAME" "$ROUTE_TABLE" "force-rotate"; then
				set_last_rotate "$IFACE"
				send_webhook "$LABEL" "$ACTIVE_NAME" "$NEXT_NAME" "rotated_manual"
				log_success "Tunnel '${LABEL}': force-rotate complete -- now on '${NEXT_NAME}'"
				ROTATED=$((ROTATED + 1))
			else
				log_fail "Tunnel '${LABEL}': force-rotate to '${NEXT_NAME}' failed ping verification"
				send_webhook "$LABEL" "$ACTIVE_NAME" "$NEXT_NAME" "ping_failed"
			fi
		fi

		i=$((i + 1))
	done

	# Warn if a target was given but matched nothing
	warn_no_tunnel_match "force-rotate" "$ROTATED" "$FLAG_FORCE_ROTATE_LABEL" "$FLAG_FORCE_ROTATE_IFACE"
}


# =============================================================================
# MAIN -- normal operation (cron, --fail, --revert)
# =============================================================================

parse_args "$@"

mkdir -p "$STATE_DIR"
migrate_benchmark_history
check_dependencies
validate_config

if [ "$FLAG_CHECK_UPDATE" = "1" ] && [ -z "$SUBCOMMAND" ]; then
	cmd_check_update
	exit $?
fi

# Pure subcommands — no lock needed
case "$SUBCOMMAND" in
	status)     cmd_status;     exit 0 ;;
	benchmarks) cmd_benchmarks; exit 0 ;;
	reset)      cmd_reset;      exit 0 ;;
esac

# Exercise mode acquires lock and exits here
if [ "$FLAG_EXERCISE" = "1" ]; then
	acquire_lock
	cmd_exercise
	exit $?
fi

# Force-rotate mode acquires lock and exits here
if [ "$FLAG_FORCE_ROTATE" = "1" ]; then
	acquire_lock
	cmd_force_rotate
	exit 0
fi

# Benchmark mode acquires lock and exits here
if [ "$FLAG_BENCHMARK" = "1" ]; then
	acquire_lock
	cmd_benchmark
	exit 0
fi

# Interactive banner for normal operation
if [ "$INTERACTIVE" = "1" ]; then
	echo ""
	echo "==============================================="
	echo "  wg_failover.sh v${VER}"
	[ "$DRY_RUN" = "1" ] && echo "  Mode          : DRY RUN -- no changes will be made"
	if [ "$FLAG_FAIL" = "1" ]; then
		if [ -n "$FLAG_FAIL_IFACE" ]; then
			echo "  Simulated fail   : iface '${FLAG_FAIL_IFACE}'"
		else
			echo "  Simulated fail   : label '${FLAG_FAIL_LABEL}'"
		fi
	fi
	[ "$FLAG_FAIL_WAN" = "1" ]        && echo "  WAN fail sim     : SIMULATED OUTAGE"
	[ "$FLAG_REVERT" = "1" ]          && echo "  Revert on switch : YES -- will switch back after success"
	[ "$FLAG_IGNORE_COOLDOWN" = "1" ] && echo "  Cooldown         : BYPASSED"
	[ -n "$FLAG_SWITCH_METHOD" ]      && echo "  Switch method    : ${FLAG_SWITCH_METHOD}"
	echo "  $(date '+%Y-%m-%d %H:%M:%S')"
	echo "==============================================="
	echo ""
fi

acquire_lock

# Throttle check. Skipped in interactive mode.
if [ "$INTERACTIVE" = "0" ]; then
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

# Remove stale runtime state for peers or interfaces no longer in config.
cleanup_stale_cooldowns
cleanup_stale_tunnel_states

# WAN pre-flight check.
# If --fail and --fail-wan are combined, simulate the WAN drop during the
# tunnel handshake check, not here.
if wan_is_stable || ( [ "$FLAG_FAIL" = "1" ] && [ "$FLAG_FAIL_WAN" = "1" ] ); then
	log_success "WAN pre-flight: OK -- stable via ${_WAN_INFO_IFACE:-unknown}"
	[ "$FLAG_FAIL_WAN" = "0" ] && send_wan_webhook "up"
else
	# Distinguish actual outage from stability window not yet met
	if wan_is_reachable; then
		_WIS_STABLE_FOR=$(wan_stable_for_seconds)
		_WIS_REMAINING=$(( WAN_STABILITY_THRESHOLD - _WIS_STABLE_FOR ))
		[ "$_WIS_REMAINING" -lt 0 ] && _WIS_REMAINING=0
		log_warn "WAN pre-flight: reachable but not yet stable ($(format_duration "${_WIS_REMAINING:-0}") remaining) -- skipping tunnel checks"
	else
		log_fail "WAN pre-flight: FAILED -- no connectivity via ${_WAN_INFO_IFACE:-unknown}, skipping all tunnel checks"
		send_wan_webhook "down"
	fi
	exit 0
fi

DRYFLAG=""
[ "$DRY_RUN" = "1" ]             && DRYFLAG="$DRYFLAG [DRY RUN]"
if [ "$FLAG_FAIL" = "1" ]; then
	if [ -n "$FLAG_FAIL_IFACE" ]; then
		DRYFLAG="$DRYFLAG [SIMULATED FAIL: iface=${FLAG_FAIL_IFACE}]"
	else
		DRYFLAG="$DRYFLAG [SIMULATED FAIL: label=${FLAG_FAIL_LABEL}]"
	fi
fi
[ "$FLAG_FAIL_WAN" = "1" ]        && DRYFLAG="$DRYFLAG [SIMULATED WAN OUTAGE]"
[ "$FLAG_IGNORE_COOLDOWN" = "1" ] && DRYFLAG="$DRYFLAG [IGNORE COOLDOWN]"
[ "$FLAG_REVERT" = "1" ]          && DRYFLAG="$DRYFLAG [REVERT ON SWITCH]"
log_verbose "=== Check started (PID $$)${DRYFLAG} ==="
log_verbose "Version        : ${VER}"
log_verbose "Config         : CHECK_INTERVAL=${CHECK_INTERVAL} HANDSHAKE_TIMEOUT=${HANDSHAKE_TIMEOUT} PEER_COOLDOWN=${PEER_COOLDOWN}"
log_verbose "Ping           : PING_VERIFY=${PING_VERIFY} TARGETS='${PING_TARGETS}' COUNT=${PING_COUNT} TIMEOUT=${PING_TIMEOUT}"
log_verbose "WAN check      : IFACE=${_WAN_INFO_IFACE:-auto} TARGETS='${WAN_PING_TARGETS:-disabled}' STABILITY_THRESHOLD=${WAN_STABILITY_THRESHOLD:-0}s"
log_verbose "Post-switch    : HANDSHAKE_TIMEOUT=${POST_SWITCH_HANDSHAKE_TIMEOUT} DELAY=${POST_SWITCH_DELAY}"
_EFFECTIVE_SW_METHOD="${FLAG_SWITCH_METHOD:-$GLINET_SWITCH_METHOD}"
[ -z "$_EFFECTIVE_SW_METHOD" ] && _EFFECTIVE_SW_METHOD='uci'
log_verbose "Switch method  : ${_EFFECTIVE_SW_METHOD}$([ "$_EFFECTIVE_SW_METHOD" != "uci" ] && echo " (router: ${GLINET_ROUTER})" || true)"
log_verbose "Tunnels        : TUNNEL_COUNT=${TUNNEL_COUNT}"

BLANK_KEYWORD_SEEN=0
FAIL_LABEL_MATCHED=0

i=1
while [ "$i" -le "$TUNNEL_COUNT" ]; do
	_TUNNEL_IDX=$i
	load_tunnel_vars "$i"
	eval "ROTATE=\$TUNNEL_${i}_ROTATE"

	SIMULATE_THIS=0
	if [ "$FLAG_FAIL" = "1" ]; then
		tunnel_matches_target "$LABEL" "$IFACE" "$FLAG_FAIL_LABEL" "$FLAG_FAIL_IFACE"
		_FAIL_MATCH=$?
		if [ "$_FAIL_MATCH" = "0" ]; then
			SIMULATE_THIS=1
			FAIL_LABEL_MATCHED=1
		fi
	fi

	if [ "$ENABLED" != "1" ]; then
		log_verbose "Tunnel '${LABEL}': auto-failover disabled -- skipping"
		[ "$SIMULATE_THIS" = "1" ] && log_warn "Tunnel '${LABEL}': --fail ignored -- auto-failover is disabled"
		i=$((i + 1))
		continue
	fi

	if ! is_tunnel_up "$IFACE"; then
		log_verbose "Tunnel '${LABEL}' (${IFACE}): interface is off -- skipping"
		[ "$SIMULATE_THIS" = "1" ] && log_warn "Tunnel '${LABEL}': --fail ignored -- interface is off"
		send_tunnel_state_webhook "$IFACE" "$LABEL" "down"
		i=$((i + 1))
		continue
	fi

	send_tunnel_state_webhook "$IFACE" "$LABEL" "up"

	[ -z "$KEYWORD" ] && log_verbose "Tunnel '${LABEL}': blank keyword -- using all unclaimed peers as pool"
	build_tunnel_pool "$i" || { i=$((i + 1)); continue; }

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
		log_error "Tunnel '${LABEL}' (${IFACE}): failover enabled but only 1 peer in pool -- skipping tunnel"
		send_webhook "$LABEL" "" "" "single_peer"

		i=$((i + 1))
		continue
	fi

	ACTIVE_PEER=$(get_active_peer "$IFACE")
	ACTIVE_NAME=$(get_peer_name "$ACTIVE_PEER")

	# -------------------------------------------------------------------------
	# Scheduled rotation check
	# Runs before handshake/failure logic. Skipped during --fail runs.
	# -------------------------------------------------------------------------
	_ROT_LAST=$(cat "${STATE_DIR}/${IFACE}.last_rotate" 2>/dev/null || echo 0)
	if [ "$FLAG_FAIL" = "0" ] && schedule_due "$LABEL" "$ROTATE" "$_ROT_LAST"; then
		log_change "Tunnel '${LABEL}' (${IFACE}): scheduled rotation -- current peer: '${ACTIVE_NAME}'"

		NEXT_ROT_PEER=$(get_next_rotation_peer "$IFACE" "$ACTIVE_PEER" $POOL)

		if [ -z "$NEXT_ROT_PEER" ]; then
			log_warn "Tunnel '${LABEL}': all peers in cooldown -- skipping scheduled rotation"
			send_webhook "$LABEL" "" "" "rotation_all_cooldown"
			
			set_last_rotate "$IFACE"
		else
			NEXT_ROT_NAME=$(get_peer_name "$NEXT_ROT_PEER")
			if switch_peer "$IFACE" "$WG_IF" "$NEXT_ROT_PEER" "$ACTIVE_NAME" "$ROUTE_TABLE" "rotation"; then
				set_last_rotate "$IFACE"
				send_webhook "$LABEL" "$ACTIVE_NAME" "$NEXT_ROT_NAME" "rotated_scheduled"
				log_success "Tunnel '${LABEL}': rotation complete -- now on '${NEXT_ROT_NAME}'"
			else
				log_fail "Tunnel '${LABEL}': rotation peer '${NEXT_ROT_NAME}' failed ping verification -- staying on '${ACTIVE_NAME}'"
				send_webhook "$LABEL" "$ACTIVE_NAME" "$NEXT_ROT_NAME" "rotation_ping_failed"
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
	if [ "$SIMULATE_THIS" = "1" ]; then
		AGE=9999
		log_change "Tunnel '${LABEL}': SIMULATED FAILURE -- treating as stale"
	else
		AGE=$(get_handshake_age "$WG_IF")
		log_verbose "Tunnel '${LABEL}': peer='${ACTIVE_NAME}' handshake_age=${AGE}s"
	fi

	if [ "$AGE" -le "$HANDSHAKE_TIMEOUT" ]; then
		rm -f "${STATE_DIR}/${IFACE}.cooldown.${ACTIVE_PEER}" 2>/dev/null
		log_success "Tunnel '${LABEL}': OK -- '${ACTIVE_NAME}' (${AGE}s)"
		i=$((i + 1))
		continue
	fi

	# -------------------------------------------------------------------------
	# WAN check
	# Stale handshake detected — before failing over, confirm the internet
	# itself is reachable via WAN (bypassing all tunnels). If not, skip.
	# -------------------------------------------------------------------------
	# If both --fail and --fail-wan are combined, simulate a WAN drop DURING the tunnel handshake check, not here.
	if ! ( [ "$FLAG_FAIL" = "1" ] && [ "$FLAG_FAIL_WAN" = "1" ] ); then
		if ! wan_is_stable; then
			if wan_is_reachable; then
				log_warn "Tunnel '${LABEL}': handshake stale (${AGE}s) but WAN not yet stable -- skipping failover"
			else
				log_warn "Tunnel '${LABEL}': handshake stale (${AGE}s) but WAN has no connectivity -- skipping failover (internet outage?)"
				[ "$SIMULATE_THIS" != "1" ] && send_wan_webhook "down"
			fi
			i=$((i + 1))
			continue
		elif [ "$SIMULATE_THIS" != "1" ]; then
			send_wan_webhook "up"
		fi
	fi

	# -------------------------------------------------------------------------
	# Pre-failover ping check
	# WAN is up but handshake is stale — before switching, confirm the current
	# peer is actually not routing traffic. A successful ping here means the
	# peer is still working despite the stale handshake (e.g. a late re-handshake)
	# and failover would be premature. Skip this cycle.
	# -------------------------------------------------------------------------
	if [ "$SIMULATE_THIS" = "0" ] && [ "$PRE_FAILOVER_PING" = "1" ]; then
		if ping_through_tunnel "$WG_IF" "$ROUTE_TABLE"; then
			log_info "Tunnel '${LABEL}': handshake stale (${AGE}s) but peer is still routing traffic -- skipping failover"
			i=$((i + 1))
			continue
		fi
		log_verbose "Tunnel '${LABEL}': pre-failover ping failed -- peer confirmed down, proceeding"
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

		# Re-check WAN before each attempt — if connectivity dropped mid-failover,
		# stop cycling peers rather than burning through the entire pool uselessly.
		if ! wan_is_stable; then
			if wan_is_reachable; then
				log_warn "Tunnel '${LABEL}': WAN not yet stable mid-failover -- aborting peer cycle"
			else
				log_warn "Tunnel '${LABEL}': WAN connectivity lost mid-failover -- aborting peer cycle"
				[ "$SIMULATE_THIS" = "1" ] || { send_wan_webhook "down"; }
			fi
			send_webhook "$LABEL" "$CURRENT_NAME" "" "all_failed_wan_lost"
			break
		fi

		NEXT_NAME=$(get_peer_name "$NEXT_PEER")

		if switch_peer "$IFACE" "$WG_IF" "$NEXT_PEER" "$CURRENT_NAME" "$ROUTE_TABLE" "failover"; then
			SWITCHED_TO_PEER="$NEXT_PEER"
			SWITCHED_TO_NAME="$NEXT_NAME"
			send_webhook "$LABEL" "$ACTIVE_NAME" "$NEXT_NAME" "switched_failover"
			log_success "Tunnel '${LABEL}': failover complete -- now on '${NEXT_NAME}'"
			break
		else
			log_fail "Tunnel '${LABEL}': '${NEXT_NAME}' failed ping verification -- trying next peer"
			send_webhook "$LABEL" "$CURRENT_NAME" "$NEXT_NAME" "failover_ping_failed"
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
			send_webhook "$LABEL" "$SWITCHED_TO_NAME" "$ACTIVE_NAME" "switched_revert"
			log_success "Tunnel '${LABEL}': reverted to '${ACTIVE_NAME}'"
		else
			log_fail "Tunnel '${LABEL}': revert to '${ACTIVE_NAME}' failed ping verification -- remaining on '${SWITCHED_TO_NAME}'"
		fi
	elif [ "$FLAG_REVERT" = "1" ] && [ -z "$SWITCHED_TO_PEER" ]; then
		log_warn "Tunnel '${LABEL}': --revert requested but no switch occurred -- nothing to revert"
	fi

	i=$((i + 1))
done

# Warn if --fail was used but the target didn't match any tunnel
if [ "$FLAG_FAIL" = "1" ] && [ "$FAIL_LABEL_MATCHED" = "0" ]; then
	[ -n "$FLAG_FAIL_IFACE" ] && log_warn "No tunnel matched --fail --iface '${FLAG_FAIL_IFACE}'" \
		|| log_warn "No tunnel matched --fail label '${FLAG_FAIL_LABEL}'"
	warn_no_tunnel_match "fail" "$FAIL_LABEL_MATCHED" "$FLAG_FAIL_LABEL" "$FLAG_FAIL_IFACE"
fi

# Periodic status webhook
if [ -n "$STATUS_WEBHOOK_INTERVAL" ] && [ -n "$WEBHOOK_URL" ]; then
	_PSW_TS_FILE="${STATE_DIR}/status_webhook_last_ts"
	_PSW_LAST=$(cat "$_PSW_TS_FILE" 2>/dev/null || echo 0)
	if schedule_due "status_webhook" "$STATUS_WEBHOOK_INTERVAL" "$_PSW_LAST"; then
		log_verbose "Sending periodic status webhook"
		send_status_webhook
		echo "$(date +%s)" > "$_PSW_TS_FILE"
	fi
fi

# Periodic benchmark
if [ -n "$BENCHMARK_INTERVAL" ] && [ -n "$BENCHMARK_URL" ] && \
   [ "$DRY_RUN" = "0" ] && [ "$FLAG_FAIL" = "0" ] && [ "$FLAG_REVERT" = "0" ]; then
	_PBW_TS_FILE="${STATE_DIR}/benchmark_last_ts"
	_PBW_LAST=$(cat "$_PBW_TS_FILE" 2>/dev/null || echo 0)
	if schedule_due "benchmark" "$BENCHMARK_INTERVAL" "$_PBW_LAST"; then
		log_verbose "Running periodic benchmark"
		if [ "${BENCHMARK_INTERVAL_ALL_PEERS:-0}" = "1" ] && [ -n "$BENCHMARK_SWEEP_TUNNEL" ]; then
			_PBK_CROSS_RESULTS=$(mktemp /tmp/wgbenchcross.XXXXXX)
			run_cross_tunnel_sweep "$_PBK_CROSS_RESULTS" "${BENCHMARK_URL:-}"
			rm -f "$_PBK_CROSS_RESULTS"
		else
			_BK_i=1
			while [ "$_BK_i" -le "$TUNNEL_COUNT" ]; do
				load_tunnel_vars "$_BK_i"
				if [ "$ENABLED" = "1" ]; then
					_BK_URL=$(get_benchmark_url_for_tunnel "$_BK_i")
					[ -n "$_BK_URL" ] && run_tunnel_benchmark "$IFACE" "$WG_IF" "$LABEL" "$ROUTE_TABLE" "$_BK_URL"
				fi
				_BK_i=$(( _BK_i + 1 ))
			done
		fi

		echo "$(date +%s)" > "$_PBW_TS_FILE"

		_BIW="${BENCHMARK_INTERVAL_WEBHOOK:-0}"
		_BIW_SEND=0
		if [ "$_BIW" = "1" ]; then
			_BIW_SEND=1
		elif [ "$_BIW" = "-1" ]; then
			if schedule_is_last_entry "$SCHEDULE_TRIGGERED_ENTRY" "$BENCHMARK_INTERVAL"; then
				_BIW_SEND=1
				log_verbose "Periodic benchmark: BENCHMARK_INTERVAL_WEBHOOK=-1 and last entry matched -- sending webhook"
			else
				log_verbose "Periodic benchmark: BENCHMARK_INTERVAL_WEBHOOK=-1 but '${SCHEDULE_TRIGGERED_ENTRY}' is not last entry -- skipping webhook"
			fi
		fi
		if [ "$_BIW_SEND" = "1" ]; then
			if [ -n "$WEBHOOK_URL" ]; then
				send_benchmarks_webhook
			else
				log_verbose "Periodic benchmark: webhook enabled but WEBHOOK_URL is not set -- skipping"
			fi
		fi
	fi
fi

log_verbose "=== Check complete (PID $$) ==="
exit 0
