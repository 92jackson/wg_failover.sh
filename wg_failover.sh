#!/bin/sh
# =================================================================================
VER='1.2.0'
# WireGuard VPN Tunnel Failover and Auto-Rotate for OpenWrt
#
# GitHub : https://github.com/92jackson/wg_failover.sh
# License: MIT
# =================================================================================
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
# • Optional webhook notifications (ntfy.sh, Gotify, custom)
# • Optional GL.iNet dashboard API sync (keeps router UI in sync after peer switch)
# • Built for GL.iNet firmware 4.x and OpenWrt
#
# INSTALL
# ---------------------------------------------------------------------------------
#   1. Copy script     :  scp wg_failover.sh root@192.168.8.1:/usr/bin/
#   2. Make executable :  chmod +x /usr/bin/wg_failover.sh
#   3. Configure       :  vi /usr/bin/wg_failover.sh
#   4. Add to cron     :  echo "* * * * * /usr/bin/wg_failover.sh" >> /etc/crontabs/root
#   5. Restart cron    :  /etc/init.d/cron restart
#
# SUBCOMMANDS
# ---------------------------------------------------------------------------------
#   status                    — print tunnel status and live ping test
#   status --json             — print status as JSON for scripting
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
#   --revert                  — after a successful switch, revert to the original peer
#   --ignore-cooldown         — skip cooldown checks when selecting the next peer
#   --switch-method <method>  — override GLINET_SWITCH_METHOD for this run
#                               values: auto | api | uci
#   --version                 — print version and exit
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
# OPTIONAL BUT STRONGLY RECOMMENDED:
#   • WAN SAFETY GUARD → prevents exhausting peers during ISP outages
#
# OPTIONAL:
#   • GL.iNet API integration
#   • Failover timer tuning
#   • Logging, webhooks, rotation, etc.
# =============================================================================


# =============================================================================
# TUNNEL DEFINITIONS (REQUIRED)
# At least one tunnel must be defined for the script to function.
#
# Use these commands to discover values before editing:
#   (1) List WG interfaces:   uci show network | grep 'wgclient.*\.config='
#   (2) List servers (peers): uci show wireguard | grep '\.name='
#   (3) Routing tables:       uci show network | grep ip4table
# For more detail on setting up tunnels, see: https://github.com/92jackson/wg_failover.sh/tree/main#configuration
# =============================================================================

TUNNEL_COUNT=2                     # Number of tunnels on router AND defined below

# TUNNEL 1 EXAMPLE
TUNNEL_1_IFACE='wgclient1'         # (1) OpenWrt interface name
TUNNEL_1_WG_IF='wgclient1'         # WireGuard kernel interface (usually same as _IFACE)
TUNNEL_1_LABEL='Primary (UK)'      # Friendly name for logs/webhooks (text)
TUNNEL_1_KEYWORD='UK'              # (2) Substring matching this tunnel's peers
TUNNEL_1_ROUTE_TABLE='1001'        # (3) Routing table
TUNNEL_1_ENABLED=1                 # 1=script monitors tunnel, 0=ignore
TUNNEL_1_ROTATE_INTERVAL=0         # Hours between forced rotations (0=disabled)
TUNNEL_1_ROTATE_AT=''              # Daily rotation time HH:MM (optional)

# TUNNEL 2 EXAMPLE
TUNNEL_2_IFACE='wgclient2'
TUNNEL_2_WG_IF='wgclient2'
TUNNEL_2_LABEL='Streaming (Albania)'
TUNNEL_2_KEYWORD='AL'
TUNNEL_2_ROUTE_TABLE='1002'
TUNNEL_2_ENABLED=1
TUNNEL_2_ROTATE_INTERVAL=6          # Rotate every 6 hours
TUNNEL_2_ROTATE_AT='03:00'          # Daily at 03:00 (whichever triggers first)


# =============================================================================
# WAN SAFETY GUARD (RECOMMENDED)
# Prevents cooling down all peers when your ISP/WAN is down.
#
# Find interface via: ip route show default | awk '{print $5}'
# =============================================================================

WAN_IFACE='eth1'                     # Set to '' to disable WAN checking
WAN_CHECK_TARGETS='1.1.1.1 8.8.8.8'  # Reliable IPs to confirm internet access


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
POST_SWITCH_GRACE=60                # Pause monitoring after successful switch
PEER_COOLDOWN=600                   # Time before retrying a failed peer


# =============================================================================
# NORMAL OPERATION (SAFE DEFAULTS)
# Most users can leave these unchanged.
# =============================================================================

CHECK_INTERVAL=60                   # Script run frequency (cron still every min)
PING_VERIFY=1                       # Verify internet after switching
PING_TARGET='1.1.1.1'               # Primary connectivity check
PING_TARGET_FALLBACK='8.8.8.8'      # Secondary check if primary fails
PING_COUNT=3                        # Packets per test
PING_TIMEOUT=5                      # Seconds per ping
MAX_FAILOVER_ATTEMPTS=0             # 0 = try all peers before giving up
HANDSHAKE_POLL_INTERVAL=3           # How often to poll for new handshake


# =============================================================================
# LOGGING
# =============================================================================

LOG_FILE='/var/log/wg_failover.log' # Log location, '' to disable
LOG_MAX_SIZE=102400                 # Rotate log when exceeding size (bytes)
LOG_MAX_LINES=500                   # Lines kept after rotation
LOG_LEVEL=2                         # 0 silent | 1 errors | 2 normal | 3 verbose
HISTORY_MAX_LINES=500               # Switch history retention
STATE_DIR='/tmp/wg_failover'        # Runtime state


# =============================================================================
# WEBHOOK NOTIFICATIONS (OPTIONAL)
# See: https://github.com/92jackson/wg_failover.sh/tree/main#webhook-notifications
# =============================================================================

WEBHOOK_URL=''                      # Set endpoint to enable notifications, '' to disable
WEBHOOK_METHOD='GET'                # GET appends query | POST sends JSON
WAN_WEBHOOK_INTERVAL=300            # Rate-limit WAN outage alerts


# =================================================================================
# =================================================================================
# END OF USER CONFIGURATION — do not edit below unless you know what you're doing!
# =================================================================================
# =================================================================================


# --- Globals ------------------------------------------------------------------

DRY_RUN=0
SUBCOMMAND=''
STATUS_JSON=0
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
FLAG_SWITCH_METHOD=''
INTERACTIVE=''
TEST_PASS=0
TEST_FAIL=0
STATUS_LIVE=0
STATUS_LIVE_INTERVAL=5


# --- Argument parsing ---------------------------------------------------------
# Subcommands: status, reset
# Flags (all combinable): --dry-run, --fail [--iface] <target>, --fail-wan,
#                         --exercise [--iface] [target], --force-rotate [--iface] [target]
#                         --revert, --ignore-cooldown
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
			status)
				SUBCOMMAND="$1"
				shift
				# Optional --json qualifier
				if [ "$1" = "--json" ]; then
					STATUS_JSON=1
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
				echo "Usage: $0 [status [--json]|reset [--keep-history]] [--dry-run] [--version]"
				echo "          [--fail [--iface] <target>] [--fail-wan]"
				echo "          [--exercise [--iface] [target]] [--force-rotate [--iface] [target]]"
				echo "          [--revert] [--ignore-cooldown] [--switch-method auto|api|uci]"
				exit 1
				;;
		esac
	done

	# Warn when --fail-wan and --fail are combined — behaviour is unintuitive:
	# the targeted tunnel's SIMULATE_THIS bypasses the WAN pre-flight so its
	# failover proceeds, while all other tunnels are suppressed by the WAN check.
	if [ "$FLAG_FAIL_WAN" = "1" ] && [ "$FLAG_FAIL" = "1" ]; then
		echo "Warning: --fail-wan and --fail are combined."
		if [ -n "$FLAG_FAIL_IFACE" ]; then
			echo "  The tunnel on iface '${FLAG_FAIL_IFACE}' will failover (pre-flight bypassed)."
		else
			echo "  The tunnel labelled '${FLAG_FAIL_LABEL}' will failover (pre-flight bypassed)."
		fi
		echo "  All other tunnels will have failover suppressed by the simulated WAN outage."
		echo "  Press Ctrl-C to abort, or wait 3 seconds to continue..."
		sleep 3
	fi
}


# --- Dependency check ---------------------------------------------------------
# Verifies all required external commands are available before doing any work.
# Catches missing binaries early (e.g. after firmware updates) rather than
# letting them fail silently mid-failover.

check_dependencies() {
	_MISSING=''
	for _CMD in uci ubus wg ip ping grep sed date wget; do
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


# --- Validation ---------------------------------------------------------------

validate_config() {
	if [ -z "$TUNNEL_COUNT" ] || [ "$TUNNEL_COUNT" -lt 1 ] 2>/dev/null; then
		echo "Error: TUNNEL_COUNT must be a positive integer (got: '${TUNNEL_COUNT:-<empty>}')"
		exit 1
	fi
}


# --- Target matching ----------------------------------------------------------
# Centralised helper used by --fail, --exercise, and --force-rotate.
# Returns 0 (match) if the current tunnel matches the user-supplied target,
# which can be expressed as either a label or an interface name (--iface).
#
# Usage: tunnel_matches_target "$LABEL" "$IFACE" "$TARGET_LABEL" "$TARGET_IFACE"
# Returns 0 = match, 1 = no match, 2 = no filter set (caller should treat as
# "match all").

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

# Convenience: print available tunnel labels + ifaces for "no match" errors.
print_available_tunnels() {
	j=1
	while [ "$j" -le "$TUNNEL_COUNT" ]; do
		eval "_L=\$TUNNEL_${j}_LABEL"
		eval "_IF=\$TUNNEL_${j}_IFACE"
		printf "    %-30s  (iface: %s)\n" "$_L" "$_IF"
		j=$((j + 1))
	done
}
# All commands that change router state go through do_exec.
# In --dry-run mode the command is logged but not run.

do_exec() {
	if [ "$DRY_RUN" = "1" ]; then
		log_dryrun "Would run: $*"
	else
		"$@"
	fi
}


# --- GL.iNet dashboard API helpers --------------------------------------------
#
# Split into three layers so logic is not duplicated between glinet_api_switch()
# and the status command:
#
#   glinet_api_challenge()  — Steps 1 & 2: get salt/nonce, generate hash
#                             Populates: GLINET_API_SALT, GLINET_API_NONCE,
#                                        GLINET_API_HASH, GLINET_API_RC,
#                                        GLINET_API_BODY
#   glinet_api_login()      — Step 3: exchange hash for session token
#                             Populates: GLINET_API_SESSION
#   glinet_api_switch()     — Steps 4 & 5: get_tunnel, set_tunnel
#                             Calls both helpers, then switches the peer
#
#   glinet_api_logout()     — Step 6: logout
#
# All helpers return 0 on success, 1 on failure.
# Uses curl throughout — GL.iNet's bundled wget does not support --header.
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

	# STEP 3 — Login; curl -i puts headers inline in the response body.
	# CRITICAL: strip \r\n from extracted token (hidden newline from HTTP headers).
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


# --- Logging ------------------------------------------------------------------

# Colour helpers
if [ -t 1 ]; then
	_C_RESET=$(printf '\033[0m')
	_C_BOLD=$(printf '\033[1m')
	_C_DIM=$(printf '\033[2m')
	_C_GREEN=$(printf '\033[32m')
	_C_YELLOW=$(printf '\033[33m')
	_C_RED=$(printf '\033[31m')
	_C_CYAN=$(printf '\033[36m')
	_C_WHITE=$(printf '\033[97m')
else
	_C_RESET=''
	_C_BOLD=''
	_C_DIM=''
	_C_GREEN=''
	_C_YELLOW=''
	_C_RED=''
	_C_CYAN=''
	_C_WHITE=''
fi

# Print a section header
# Usage: status_section "TUNNELS"
status_section() {
	printf "\n${_C_BOLD}${_C_WHITE}  ── %s %s${_C_RESET}\n" "$1" \
		"$(printf '%.0s─' $(seq 1 $((42 - ${#1}))))"
}

# Print a labelled status row, with optional colour applied to the value
# Usage: status_row "Label" "value" [colour]
status_row() {
	_SR_LABEL=$1
	_SR_VALUE=$2
	_SR_COLOUR=${3:-}
	printf "  ${_C_DIM}%-14s${_C_RESET} ${_SR_COLOUR}%s${_C_RESET}\n" "$_SR_LABEL" "$_SR_VALUE"
}

# Coloured ok/warn/err badges for inline use
badge_ok()   { printf "${_C_GREEN}%s${_C_RESET}" "$1"; }
badge_warn() { printf "${_C_YELLOW}%s${_C_RESET}" "$1"; }
badge_err()  { printf "${_C_RED}%s${_C_RESET}" "$1"; }

log() {
	LEVEL=$1
	MSG=$2
	[ "$LOG_LEVEL" -lt "$LEVEL" ] && return
	[ -z "$LOG_FILE" ] && return

	TIME_ONLY=$(date '+%H:%M:%S')
	FULL_TS=$(date '+%Y-%m-%d %H:%M:%S')

	# Don't write to log file in dry-run or exercise mode — stdout only
	if [ "$DRY_RUN" = "0" ] && [ "$FLAG_EXERCISE" = "0" ]; then
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
log_verbose() { log 3 "[DEBUG]  $1"; }
log_dryrun()  {
	TIME_ONLY=$(date '+%H:%M:%S')
	printf "  [%s] ${_C_YELLOW}%-8s${_C_RESET} %s\n" "$TIME_ONLY" "DRY-RUN" "$1"
}

# Exercise-mode step logger — always prints to stdout with clear pass/fail markers
test_step() {
	_TS_STATUS=$1
	_TS_MSG=$2
	_TS_TIMESTAMP=$(date '+%H:%M:%S')

	case "$_TS_STATUS" in
		PASS|INFO)   _TS_COLOUR="$_C_GREEN"  ;;
		WARN|DRY-RUN) _TS_COLOUR="$_C_YELLOW" ;;
		ERROR|FAIL)  _TS_COLOUR="$_C_RED"    ;;
		CHANGE)      _TS_COLOUR="$_C_CYAN"   ;;
		*)           _TS_COLOUR="$_C_DIM"    ;;
	esac

	printf "  [%s] ${_TS_COLOUR}%-8s${_C_RESET} %s\n" \
		"$_TS_TIMESTAMP" "$_TS_STATUS" "$_TS_MSG"
}

test_pass() { TEST_PASS=$((TEST_PASS + 1)); test_step "PASS" "$1"; }
test_fail() { TEST_FAIL=$((TEST_FAIL + 1)); test_step "FAIL" "$1"; }
test_info() { test_step "INFO" "$1"; }
test_warn() { test_step "WARN" "$1"; }


# --- Webhook ------------------------------------------------------------------

# URL-encode a string for safe use in GET query parameters.
# Uses od to hex-encode every byte, then replaces known-safe characters back
# with their literals. This correctly handles spaces, slashes, quotes, unicode,
# and any other character that would break a raw URL.
# Compatible with BusyBox od (OpenWrt standard).
urlencode() {
	printf '%s' "$1" \
		| od -An -tx1 \
		| tr -d ' \n' \
		| sed 's/\(..\)/%\1/g; s/%20/ /g' \
		| sed 's/ /%20/g' \
		| tr '[:lower:]' '[:upper:]' \
		| sed \
			's/%2D/-/g; s/%2E/./g; s/%5F/_/g; s/%7E/~/g; \
			 s/%30/0/g; s/%31/1/g; s/%32/2/g; s/%33/3/g; \
			 s/%34/4/g; s/%35/5/g; s/%36/6/g; s/%37/7/g; \
			 s/%38/8/g; s/%39/9/g; \
			 s/%41/A/g; s/%42/B/g; s/%43/C/g; s/%44/D/g; \
			 s/%45/E/g; s/%46/F/g; s/%47/G/g; s/%48/H/g; \
			 s/%49/I/g; s/%4A/J/g; s/%4B/K/g; s/%4C/L/g; \
			 s/%4D/M/g; s/%4E/N/g; s/%4F/O/g; s/%50/P/g; \
			 s/%51/Q/g; s/%52/R/g; s/%53/S/g; s/%54/T/g; \
			 s/%55/U/g; s/%56/V/g; s/%57/W/g; s/%58/X/g; \
			 s/%59/Y/g; s/%5A/Z/g; \
			 s/%61/a/g; s/%62/b/g; s/%63/c/g; s/%64/d/g; \
			 s/%65/e/g; s/%66/f/g; s/%67/g/g; s/%68/h/g; \
			 s/%69/i/g; s/%6A/j/g; s/%6B/k/g; s/%6C/l/g; \
			 s/%6D/m/g; s/%6E/n/g; s/%6F/o/g; s/%70/p/g; \
			 s/%71/q/g; s/%72/r/g; s/%73/s/g; s/%74/t/g; \
			 s/%75/u/g; s/%76/v/g; s/%77/w/g; s/%78/x/g; \
			 s/%79/y/g; s/%7A/z/g'
}

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
		ENC_TUNNEL=$(urlencode "$TUNNEL_LABEL")
		ENC_FROM=$(urlencode "$FROM_PEER")
		ENC_TO=$(urlencode "$TO_PEER")
		ENC_STATUS=$(urlencode "$STATUS")
		wget -q -O /dev/null --timeout=10 \
			"${WEBHOOK_URL}?tunnel=${ENC_TUNNEL}&from=${ENC_FROM}&to=${ENC_TO}&status=${ENC_STATUS}" \
			2>/dev/null &
	fi

	log_verbose "Webhook sent: status=${STATUS} tunnel='${TUNNEL_LABEL}' from='${FROM_PEER}' to='${TO_PEER}'"
}

# WAN state webhook — fires on WAN down/up transitions with rate-limiting.
# State is persisted to STATE_DIR so transitions survive across cron ticks.
#
# WAN_STATE_FILE holds either 'up' or 'down'.
# WAN_WEBHOOK_TS_FILE holds the timestamp of the last wan_down webhook sent.
#
# Behaviour:
#   wan_down — fires once when WAN transitions from up→down, then at most once
#              per WAN_WEBHOOK_INTERVAL seconds while WAN remains down.
#   wan_up   — fires once when WAN transitions from down→up.

send_wan_webhook() {
	_WAN_EVENT=$1   # 'down' or 'up'
	[ -z "$WEBHOOK_URL" ] && return
	[ "$DRY_RUN" = "1" ] && log_dryrun "Would send WAN webhook: status=wan_${_WAN_EVENT}" && return

	WAN_STATE_FILE="${STATE_DIR}/wan_state"
	WAN_WEBHOOK_TS_FILE="${STATE_DIR}/wan_webhook_ts"
	_PREV_STATE=$(cat "$WAN_STATE_FILE" 2>/dev/null || echo "up")
	_NOW=$(date +%s)

	if [ "$_WAN_EVENT" = "down" ]; then
		# Rate-limit: only fire if enough time has passed since last wan_down webhook
		_LAST_TS=$(cat "$WAN_WEBHOOK_TS_FILE" 2>/dev/null || echo 0)
		_ELAPSED=$(( _NOW - _LAST_TS ))
		if [ "$_PREV_STATE" = "up" ] || [ "$_ELAPSED" -ge "$WAN_WEBHOOK_INTERVAL" ]; then
			echo "down" > "$WAN_STATE_FILE"
			echo "$_NOW" > "$WAN_WEBHOOK_TS_FILE"
			_send_wan_event "wan_down"
			log_warn "WAN webhook sent: wan_down"
		else
			log_verbose "WAN webhook suppressed (rate-limited, next in $(( WAN_WEBHOOK_INTERVAL - _ELAPSED ))s)"
		fi
	elif [ "$_WAN_EVENT" = "up" ]; then
		# Only fire wan_up if we previously recorded a down state
		if [ "$_PREV_STATE" = "down" ]; then
			echo "up" > "$WAN_STATE_FILE"
			rm -f "$WAN_WEBHOOK_TS_FILE"
			_send_wan_event "wan_up"
			log_change "WAN webhook sent: wan_up"
		fi
	fi
}

_send_wan_event() {
	_STATUS=$1
	if [ "$WEBHOOK_METHOD" = "POST" ]; then
		BODY="{\"tunnel\":\"wan\",\"from\":\"\",\"to\":\"\",\"status\":\"${_STATUS}\"}"
		wget -q -O /dev/null --timeout=10 \
			--post-data="$BODY" \
			--header="Content-Type: application/json" \
			"$WEBHOOK_URL" 2>/dev/null &
	else
		wget -q -O /dev/null --timeout=10 \
			"${WEBHOOK_URL}?tunnel=wan&from=&to=&status=${_STATUS}" \
			2>/dev/null &
	fi
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

get_iface_endpoint() {
	wg show "$1" endpoints 2>/dev/null | awk '{print $2}'
}

# Returns 0 (true) if tunnel interface is administratively up and active.
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
# Polls every HANDSHAKE_POLL_INTERVAL seconds until fresh or timeout.
# Outputs seconds taken, or the string 'timeout'.

wait_for_handshake() {
	WG_IF=$1
	START=$(date +%s)
	DEADLINE=$((START + POST_SWITCH_HANDSHAKE_TIMEOUT))

	# Brief pause to let the interface fully come up before polling begins
	sleep 2

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


# --- WAN pre-flight check -----------------------------------------------------
# Pings WAN_CHECK_TARGETS directly through the WAN interface (bypassing all
# tunnels). Returns 0 if any target replies, 1 only if ALL targets fail.
# A failure means the internet itself is down — failover would be pointless.

wan_is_reachable() {
	# --fail-wan simulates a complete WAN outage for testing pre-flight suppression
	if [ "$FLAG_FAIL_WAN" = "1" ]; then
		log_verbose "WAN pre-flight: SIMULATED OUTAGE (--fail-wan)"
		return 1
	fi

	[ -z "$WAN_IFACE" ] && return 0   # check disabled — assume reachable

	for _TARGET in $WAN_CHECK_TARGETS; do
		if ping -c 2 -W 3 -I "$WAN_IFACE" "$_TARGET" > /dev/null 2>&1; then
			log_verbose "WAN pre-flight: ${_TARGET} reachable via ${WAN_IFACE}"
			return 0
		fi
		log_verbose "WAN pre-flight: ${_TARGET} unreachable via ${WAN_IFACE}"
	done

	return 1
}


# --- Ping verification --------------------------------------------------------
# Tries PING_TARGET then PING_TARGET_FALLBACK through the tunnel.
# Returns 0 as soon as any target replies. Both must fail to return 1.
# Each target is tried via routing table first, then interface-bound fallback.

ping_through_tunnel() {
	WG_IF=$1
	ROUTE_TABLE=$2

	if [ "$DRY_RUN" = "1" ]; then
		_TARGETS="${PING_TARGET}${PING_TARGET_FALLBACK:+ / ${PING_TARGET_FALLBACK}}"
		log_dryrun "Would ping ${_TARGETS} through tunnel '${WG_IF}' (table: ${ROUTE_TABLE:-none})"
		return 0
	fi

	for _TARGET in "$PING_TARGET" "$PING_TARGET_FALLBACK"; do
		[ -z "$_TARGET" ] && continue

		if [ -n "$ROUTE_TABLE" ]; then
			log_verbose "Pinging ${_TARGET} via routing table ${ROUTE_TABLE}"
			ip route exec table "$ROUTE_TABLE" \
				ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$_TARGET" \
				> /dev/null 2>&1 && return 0
			log_verbose "Table-based ping failed for ${_TARGET}, trying interface-bound"
		fi

		log_verbose "Pinging ${_TARGET} bound to interface ${WG_IF}"
		ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -I "$WG_IF" "$_TARGET" \
			> /dev/null 2>&1 && return 0
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

# Returns the seconds remaining on a peer's cooldown (reads file directly;
# call only after peer_in_cooldown has confirmed cooldown is active).
get_cooldown_remaining() {
	echo $(( PEER_COOLDOWN - ( $(date +%s) - $(cat "${STATE_DIR}/${1}.cooldown.${2}" 2>/dev/null || echo 0) ) ))
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
	if [ "$DRY_RUN" = "1" ]; then
		log_dryrun "Would record rotation timestamp for '${1}'"
		return
	fi
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
# Appends one line per switch to ${IFACE}.history for later auditing.
# Format: TIMESTAMP | REASON | FROM -> TO | RESULT

record_switch_history() {
	[ "$DRY_RUN" = "1" ] && return
	[ "$FLAG_EXERCISE" = "1" ] && return
	HIST_IFACE=$1
	HIST_FROM=$2
	HIST_TO=$3
	HIST_REASON=$4
	HIST_RESULT=$5
	HIST_TS=$(date '+%Y-%m-%d %H:%M:%S')
	HIST_FILE="${STATE_DIR}/${HIST_IFACE}.history"
	printf '%s | %-15s | %-30s -> %-30s | %s\n' \
		"$HIST_TS" "$HIST_REASON" "$HIST_FROM" "$HIST_TO" "$HIST_RESULT" \
		>> "$HIST_FILE"
	# Trim history file to HISTORY_MAX_LINES if a cap is configured
	if [ "${HISTORY_MAX_LINES:-0}" -gt 0 ]; then
		_HIST_TMP=$(mktemp /tmp/wghist.XXXXXX)
		tail -n "$HISTORY_MAX_LINES" "$HIST_FILE" > "$_HIST_TMP" 2>/dev/null \
			&& mv "$_HIST_TMP" "$HIST_FILE" \
			|| rm -f "$_HIST_TMP"
	fi
}


# --- Stale state cleanup ------------------------------------------------------
# Removes cooldown files for peers that no longer exist in uci wireguard config.
# Called once at startup during normal operation.

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


# --- Switch peer --------------------------------------------------------------
# Switches a tunnel to a new peer, polls for handshake, then pings.
# Returns 0 on success, 1 if ping verification fails.
# SWITCH_REASON: 'failover', 'rotation', 'exercise', 'exercise-revert', 'revert'
#
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
		log_dryrun "Would poll handshake (max ${POST_SWITCH_HANDSHAKE_TIMEOUT}s) then ping ${PING_TARGET}"
		set_grace_period "$IFACE"
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
				if ! wait_for_handshake "$WG_IF"; then
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

	echo "$NEW_PEER" > "${STATE_DIR}/${IFACE}.active"

	if [ "$PING_VERIFY" = "1" ]; then
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
			record_switch_history "$IFACE" "$OLD_NAME" "$NEW_NAME" "$SWITCH_REASON" "ok"
			set_grace_period "$IFACE"
			return 0
		else
			log_error "Tunnel '${IFACE}': ping verification FAILED — '${NEW_NAME}' is not routing traffic"
			record_switch_history "$IFACE" "$OLD_NAME" "$NEW_NAME" "$SWITCH_REASON" "ping_failed"
			set_peer_cooldown "$IFACE" "$NEW_PEER"
			return 1
		fi
	else
		log_verbose "Tunnel '${IFACE}': ping verification disabled — assuming '${NEW_NAME}' is OK"
		record_switch_history "$IFACE" "$OLD_NAME" "$NEW_NAME" "$SWITCH_REASON" "ok_no_ping"
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

# =============================================================================
# STATUS subcommand
# =============================================================================

cmd_status() {
	NOW_EPOCH=$(date +%s)
	NOW_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')

	# --- WAN status ---
	WAN_STATUS_STR="disabled"
	WAN_REACHABLE_JSON=null

	if [ -n "$WAN_IFACE" ]; then
		if wan_is_reachable; then
			WAN_STATUS_STR="REACHABLE"
			WAN_REACHABLE_JSON=true
		else
			WAN_STATUS_STR="UNREACHABLE"
			WAN_REACHABLE_JSON=false
		fi
	fi

	# Persisted WAN state (used by JSON)
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
	if [ "$STATUS_JSON" != "1" ]; then
		INTERACTIVE=1

		clear
		echo ""
		echo "============================================"
		echo "  wg_failover.sh v${VER} -- Status"
		echo "  $NOW_HUMAN"
		echo "============================================"

		# ── TUNNELS ───────────────────────────────────────────────────────────
		status_section "TUNNELS"

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

			printf "\n  ${_C_BOLD}[%s] %s${_C_RESET}  ${_C_DIM}(%s)${_C_RESET}\n" \
				"$i" "$LABEL" "$IFACE"

			if [ "$ENABLED" != "1" ]; then
				status_row "Monitoring" "$(badge_warn 'DISABLED')"
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
				if [ "$BLANK_KEYWORD_SEEN" = "1" ]; then
					status_row "Keyword" "$(badge_err '(blank) — SKIPPED: only one blank-keyword tunnel allowed')"
					i=$((i + 1))
					continue
				fi
				POOL=$(get_peers_excluding_other_keywords "$i")
				KEYWORD_DESC="(blank — all unclaimed peers)"
				BLANK_KEYWORD_SEEN=1
			else
				POOL=$(get_peers_for_keyword "$KEYWORD")
				KEYWORD_DESC="'$KEYWORD'"
			fi

			set -- $POOL; POOL_COUNT=$#

			# Handshake health
			if [ "$AGE" -eq 9999 ]; then
				HEALTH_STR="$(badge_err 'NO HANDSHAKE')"
			elif [ "$AGE" -gt "$HANDSHAKE_TIMEOUT" ]; then
				HEALTH_STR="$(badge_err "STALE — ${AGE}s")  ${_C_DIM}(threshold: ${HANDSHAKE_TIMEOUT}s)${_C_RESET}"
			else
				HEALTH_STR="$(badge_ok "OK — ${AGE}s ago")"
			fi
			in_grace_period "$IFACE" && \
				HEALTH_STR="${HEALTH_STR}  $(badge_warn '[post-switch grace period active]')"

			# Drift warning — printed as its own prominent block
			STATE_PEER=$(cat "${STATE_DIR}/${IFACE}.active" 2>/dev/null || echo "")
			if [ -n "$STATE_PEER" ] && [ "$STATE_PEER" != "$ACTIVE_PEER" ]; then
				STATE_NAME=$(get_peer_name "$STATE_PEER")
				printf "  ${_C_YELLOW}  ⚠  DRIFT DETECTED: state file shows '%s' but router reports '%s'${_C_RESET}\n" \
					"$STATE_NAME" "$ACTIVE_NAME"
				printf "  ${_C_YELLOW}     Peer may have been changed externally — run 'reset' to clear.${_C_RESET}\n"
			fi

			status_row "Active peer" "${_C_CYAN}${_C_BOLD}${ACTIVE_NAME}${_C_RESET}  ${_C_DIM}(${ACTIVE_PEER})${_C_RESET}"
			status_row "Endpoint" "$ACTIVE_ENDPOINT"
			status_row "Handshake" "$HEALTH_STR"

			# Peer pool
			printf "  ${_C_DIM}%-14s${_C_RESET} %s peers\n" "Peer pool" "$POOL_COUNT"
			for PEER in $POOL; do
				PNAME=$(get_peer_name "$PEER")
				if [ "$PEER" = "$ACTIVE_PEER" ]; then
					printf "    ${_C_CYAN}${_C_BOLD}►  %s  ${_C_DIM}(%s)${_C_RESET}\n" "$PNAME" "$PEER"
				elif peer_in_cooldown "$IFACE" "$PEER"; then
					REMAINING=$(get_cooldown_remaining "$IFACE" "$PEER")
					printf "    ${_C_YELLOW}   %s  ${_C_DIM}(%s)${_C_RESET}${_C_YELLOW}  [cooldown: %ss]${_C_RESET}\n" \
						"$PNAME" "$PEER" "$REMAINING"
				else
					printf "    ${_C_DIM}   %s  (%s)${_C_RESET}\n" "$PNAME" "$PEER"
				fi
			done

			# Rotation
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
					ELAPSED_ROT=$(( NOW_EPOCH - LAST_ROT ))
					LAST_ROT_FMT=$(date -d "@${LAST_ROT}" '+%Y-%m-%d %H:%M' 2>/dev/null \
						|| date -r "$LAST_ROT" '+%Y-%m-%d %H:%M' 2>/dev/null \
						|| echo "ts=${LAST_ROT}")
					ROTATE_STATUS="last: ${LAST_ROT_FMT}"
					if [ -n "$ROTATE_INTERVAL" ] && [ "$ROTATE_INTERVAL" -gt 0 ]; then
						INTERVAL_SECS=$((ROTATE_INTERVAL * 3600))
						NEXT_IN=$((INTERVAL_SECS - ELAPSED_ROT))
						if [ "$NEXT_IN" -le 0 ]; then
							ROTATE_STATUS="${ROTATE_STATUS}  $(badge_warn '[OVERDUE]')"
						else
							NEXT_M=$((NEXT_IN / 60))
							NEXT_S=$((NEXT_IN % 60))
							ROTATE_STATUS="${ROTATE_STATUS}  next in ${NEXT_M}m ${NEXT_S}s"
						fi
					fi
				fi
				status_row "Rotation" "${ROTATE_DESC}  ${_C_DIM}${ROTATE_STATUS}${_C_RESET}"
			else
				status_row "Rotation" "${_C_DIM}disabled${_C_RESET}"
			fi

			# Ping test
			if [ "$PING_VERIFY" = "1" ]; then
				_PTARGETS="${PING_TARGET}${PING_TARGET_FALLBACK:+ / ${PING_TARGET_FALLBACK}}"
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
		if [ -n "$WAN_IFACE" ]; then
			if [ "$WAN_STATUS_STR" = "UNREACHABLE" ]; then
				status_row "WAN" "$(badge_err "${WAN_IFACE} — UNREACHABLE")  ${_C_DIM}(targets: ${WAN_CHECK_TARGETS})${_C_RESET}"
			else
				status_row "WAN" "$(badge_ok "${WAN_IFACE} — reachable")  ${_C_DIM}(targets: ${WAN_CHECK_TARGETS})${_C_RESET}"
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
					status_row "Login" "$([ "$GLINET_API_LOGIN_OK" = "true" ] \
						&& badge_ok 'OK — credentials valid' \
						|| badge_err 'FAILED — check GLINET_PASS')"
					status_row "User" "$GLINET_USER"
					status_row "Salt / nonce" "${GLINET_API_SALT} / ${GLINET_API_NONCE}"
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
			[ -f "$HFILE" ] && \
				HIST_LINES="${HIST_LINES}$(sed "s/^/[${H_IFACE}] /" "$HFILE")\n"
			k=$((k + 1))
		done

		if [ -n "$HIST_LINES" ]; then
			status_section "RECENT SWITCHES"
			printf '%b' "$HIST_LINES" \
			| awk '{ts=$2" "$3; print ts "|" $0}' \
			| sort | tail -n 10 | cut -d'|' -f2- \
			| while IFS= read -r LINE; do
				printf "  ${_C_DIM}%s${_C_RESET}\n" "$LINE"
			done
		fi

		printf "\n${_C_DIM}  ──────────────────────────────────────────────${_C_RESET}\n\n"
	fi

	# --json output
	if [ "$STATUS_JSON" = "1" ]; then
		_TS="$NOW_HUMAN"
		_EPOCH="$NOW_EPOCH"

		printf '{\n'
		printf '  "version": "%s",\n' "$VER"
		printf '  "timestamp": "%s",\n' "$_TS"

		# --- WAN ---
		printf '  "wan": {\n'
		printf '    "iface": "%s",\n' "${WAN_IFACE:-}"
		printf '    "check_targets": "%s",\n' "$WAN_CHECK_TARGETS"
		printf '    "reachable": %s,\n' "$WAN_REACHABLE_JSON"
		printf '    "last_known_state": "%s"\n' "$WAN_LAST_STATE"
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
		printf '    "nonce": "%s"\n'     "${GLINET_API_NONCE:-}"
		printf '    "hash": "%s",\n'      "${GLINET_API_HASH:-}"
		printf '    "login_ok": %s\n'     "${GLINET_API_LOGIN_OK:-false}"
		printf '  },\n'

		# --- Config snapshot ---
		printf '  "config": {\n'
		printf '    "check_interval_s": %s,\n'            "$CHECK_INTERVAL"
		printf '    "handshake_timeout_s": %s,\n'         "$HANDSHAKE_TIMEOUT"
		printf '    "peer_cooldown_s": %s,\n'             "$PEER_COOLDOWN"
		printf '    "ping_verify": %s,\n'                 "$([ "$PING_VERIFY" = "1" ] && echo true || echo false)"
		printf '    "ping_target": "%s",\n'               "$PING_TARGET"
		printf '    "ping_target_fallback": "%s",\n'      "${PING_TARGET_FALLBACK:-}"
		printf '    "ping_count": %s,\n'                  "$PING_COUNT"
		printf '    "ping_timeout_s": %s,\n'              "$PING_TIMEOUT"
		printf '    "post_switch_grace_s": %s,\n'         "$POST_SWITCH_GRACE"
		printf '    "post_switch_handshake_timeout_s": %s,\n' "$POST_SWITCH_HANDSHAKE_TIMEOUT"
		printf '    "wan_webhook_interval_s": %s,\n'      "$WAN_WEBHOOK_INTERVAL"
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
			eval "_J_ENABLED=\$TUNNEL_${j}_ENABLED"
			eval "_J_KEYWORD=\$TUNNEL_${j}_KEYWORD"
			eval "_J_RT=\$TUNNEL_${j}_ROUTE_TABLE"
			eval "_J_ROT_INT=\$TUNNEL_${j}_ROTATE_INTERVAL"
			eval "_J_ROT_AT=\$TUNNEL_${j}_ROTATE_AT"

			[ "$_TFIRST" = "0" ] && printf ',\n'
			_TFIRST=0

			_J_ACTIVE=$(uci get "network.${_J_IFACE}.config" 2>/dev/null || echo "")
			_J_ANAME=$(get_peer_name "$_J_ACTIVE")
			_J_HS_AGE=$(get_handshake_age "$_J_WG_IF")
			_J_UP=$(is_tunnel_up "$_J_IFACE" && echo true || echo false)

			_J_ENDPOINT=$(get_iface_endpoint "$_J_WG_IF")
			[ -z "$_J_ENDPOINT" ] && _J_ENDPOINT="no session"

			# Grace period
			_J_IN_GRACE=false
			_J_GRACE_REM=0
			if in_grace_period "$_J_IFACE"; then
				_J_IN_GRACE=true
				_J_GRACE_FILE="${STATE_DIR}/${_J_IFACE}.grace"
				_J_GRACE_TS=$(cat "$_J_GRACE_FILE" 2>/dev/null || echo 0)
				_J_GRACE_REM=$(( POST_SWITCH_GRACE - ( _EPOCH - _J_GRACE_TS ) ))
				[ "$_J_GRACE_REM" -lt 0 ] && _J_GRACE_REM=0
			fi

			# Drift detection
			_J_STATE_PEER=$(cat "${STATE_DIR}/${_J_IFACE}.active" 2>/dev/null || echo "")
			_J_DRIFT=false
			[ -n "$_J_STATE_PEER" ] && [ "$_J_STATE_PEER" != "$_J_ACTIVE" ] && _J_DRIFT=true

			# Rotation
			_J_LAST_ROT=$(cat "${STATE_DIR}/${_J_IFACE}.last_rotate" 2>/dev/null || echo 0)
			_J_ROT_ELAPSED=$(( _EPOCH - _J_LAST_ROT ))
			_J_ROT_NEXT_S=null
			if [ -n "$_J_ROT_INT" ] && [ "$_J_ROT_INT" -gt 0 ] 2>/dev/null; then
				_J_ROT_NEXT_S=$(( _J_ROT_INT * 3600 - _J_ROT_ELAPSED ))
			fi

			# Ping test through this tunnel (reuse background result if available,
			# otherwise test inline — status already ran these above)
			_J_PING_RESULT=null
			if [ "$PING_VERIFY" = "1" ]; then
				_J_PT=$(mktemp /tmp/wgjsonping.XXXXXX)
				( ping_through_tunnel "$_J_WG_IF" "$_J_RT" \
					&& echo true || echo false ) > "$_J_PT" 2>/dev/null
				_J_PING_RESULT=$(cat "$_J_PT" 2>/dev/null || echo null)
				rm -f "$_J_PT"
			fi

			printf '    {\n'
			printf '      "label": "%s",\n'          "$_J_LABEL"
			printf '      "iface": "%s",\n'          "$_J_IFACE"
			printf '      "wg_if": "%s",\n'          "$_J_WG_IF"
			printf '      "keyword": "%s",\n'        "${_J_KEYWORD:-}"
			printf '      "route_table": "%s",\n'    "${_J_RT:-}"
			printf '      "enabled": %s,\n'          "$([ "$_J_ENABLED" = "1" ] && echo true || echo false)"
			printf '      "up": %s,\n'               "$_J_UP"
			printf '      "in_grace_period": %s,\n'  "$_J_IN_GRACE"
			printf '      "grace_remaining_s": %s,\n' "$_J_GRACE_REM"
			printf '      "state_drift": %s,\n'      "$_J_DRIFT"
			printf '      "active_peer_id": "%s",\n' "$_J_ACTIVE"
			printf '      "active_peer_name": "%s",\n' "$_J_ANAME"
			printf '      "endpoint": "%s",\n' "$_J_ENDPOINT"
			printf '      "handshake_age_s": %s,\n'  \
				"$([ "$_J_HS_AGE" -eq 9999 ] && echo null || echo "$_J_HS_AGE")"
			printf '      "ping_ok": %s,\n'          "$_J_PING_RESULT"
			printf '      "last_rotated_epoch": %s,\n' \
				"$([ "$_J_LAST_ROT" -eq 0 ] && echo null || echo "$_J_LAST_ROT")"
			printf '      "rotation_next_s": %s,\n'  "$_J_ROT_NEXT_S"
			printf '      "peers": [\n'

			# Build peer pool same way status does
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
				printf '        {\n'
				printf '          "id": "%s",\n'             "$_JP"
				printf '          "name": "%s",\n'           "$_JP_NAME"
				printf '          "active": %s,\n'           "$_JP_ACTIVE"
				printf '          "in_cooldown": %s,\n'      "$_JP_COOLDOWN"
				printf '          "cooldown_remaining_s": %s\n' "$_JP_COOLDOWN_REM"
				printf '        }'
			done
			printf '\n      ]\n'
			printf '    }'
			j=$((j + 1))
		done
		printf '\n  ],\n'

		# --- Recent history (last 20 entries across all tunnels, chronological) ---
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
			ts = $2;
			print ts "|" $0
		}' \
		| sort \
		| tail -n 20 \
		| cut -d'|' -f2- \
		| while IFS='|' read -r _HIFACE _HTS _HREASON _HPEERS _HRESULT; do
			# Format: TIMESTAMP | REASON | FROM -> TO | RESULT
			_HTS=$(echo "$_HTS" | sed 's/^ *//;s/ *$//')
			_HREASON=$(echo "$_HREASON" | sed 's/^ *//;s/ *$//')
			_HRESULT=$(echo "$_HRESULT" | sed 's/^ *//;s/ *$//')
			_HFROM=$(echo "$_HPEERS" | sed 's/ *->.*//;s/^ *//;s/ *$//')
			_HTO=$(echo "$_HPEERS" | sed 's/.*-> *//;s/^ *//;s/ *$//')
			[ "$_HFIRST" = "0" ] && printf ',\n'
			_HFIRST=0
			printf '    {"iface":"%s","timestamp":"%s","reason":"%s","from":"%s","to":"%s","result":"%s"}' \
				"$_HIFACE" "$_HTS" "$_HREASON" "$_HFROM" "$_HTO" "$_HRESULT"
		done
		printf '\n  ]\n'
		printf '}\n'
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
		echo "Clearing wg_failover state (cooldowns, grace periods, run timer, rotation timestamps, lockfile)..."
		echo "Switch history files will be preserved (--keep-history)."
		# Remove everything except .history files
		for _F in "${STATE_DIR}/"*; do
			[ -f "$_F" ] || continue
			case "$_F" in
				*.history) continue ;;
			esac
			rm -f "$_F"
		done
	else
		echo "Clearing all wg_failover state (cooldowns, grace periods, run timer, rotation timestamps, lockfile, history)..."
		echo "To preserve switch history, use: reset --keep-history"
		rm -f "${STATE_DIR}/"* 2>/dev/null
	fi

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

	# Pick the first peer in the pool that isn't the current one and isn't in cooldown.
	# Respects --ignore-cooldown flag (handled inside peer_in_cooldown).
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
	echo "============================================"
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

		tunnel_matches_target "$LABEL" "$IFACE" "$FLAG_EXERCISE_LABEL" "$FLAG_EXERCISE_IFACE"
		_MATCH=$?
		if [ "$_MATCH" = "1" ]; then
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
		if [ -n "$FLAG_EXERCISE_IFACE" ]; then
			echo "  (No enabled tunnel found with iface '${FLAG_EXERCISE_IFACE}')"
			echo "  Available tunnels:"
			print_available_tunnels
		elif [ -n "$FLAG_EXERCISE_LABEL" ]; then
			echo "  (Label '${FLAG_EXERCISE_LABEL}' not found or not enabled)"
			echo "  Available tunnels:"
			print_available_tunnels
		fi
	else
		echo "  Result         : FAILED ($TEST_FAIL check(s) did not pass)"
	fi
	echo "============================================"
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
	echo "========================================"
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
	[ "$DRY_RUN" = "1" ]             && echo "  Mode          : DRY RUN -- no real changes"
	echo "========================================"
	echo ""

	BLANK_KEYWORD_SEEN=0
	ROTATED=0

	i=1
	while [ "$i" -le "$TUNNEL_COUNT" ]; do
		eval "IFACE=\$TUNNEL_${i}_IFACE"
		eval "WG_IF=\$TUNNEL_${i}_WG_IF"
		eval "LABEL=\$TUNNEL_${i}_LABEL"
		eval "KEYWORD=\$TUNNEL_${i}_KEYWORD"
		eval "ROUTE_TABLE=\$TUNNEL_${i}_ROUTE_TABLE"
		eval "ENABLED=\$TUNNEL_${i}_ENABLED"

		tunnel_matches_target "$LABEL" "$IFACE" "$FLAG_FORCE_ROTATE_LABEL" "$FLAG_FORCE_ROTATE_IFACE"
		_MATCH=$?
		if [ "$_MATCH" = "1" ]; then
			i=$((i + 1))
			continue
		fi

		if [ "$ENABLED" != "1" ]; then
			log_verbose "Tunnel '${LABEL}': monitoring disabled -- skipping"
			i=$((i + 1))
			continue
		fi

		if ! is_tunnel_up "$IFACE"; then
			log_warn "Tunnel '${LABEL}' (${IFACE}): interface is off -- skipping"
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
			BLANK_KEYWORD_SEEN=1
		else
			POOL=$(get_peers_for_keyword "$KEYWORD")
		fi

		set -- $POOL; POOL_COUNT=$#
		if [ "$POOL_COUNT" -lt 2 ]; then
			log_warn "Tunnel '${LABEL}' (${IFACE}): only 1 peer in pool -- cannot rotate"
			i=$((i + 1))
			continue
		fi

		ACTIVE_PEER=$(get_active_peer "$IFACE")
		ACTIVE_NAME=$(get_peer_name "$ACTIVE_PEER")

		NEXT_PEER=$(get_next_rotation_peer "$IFACE" "$ACTIVE_PEER" $POOL)

		if [ -z "$NEXT_PEER" ]; then
			log_warn "Tunnel '${LABEL}': all peers in cooldown -- cannot force-rotate (try --ignore-cooldown)"
		else
			NEXT_NAME=$(get_peer_name "$NEXT_PEER")
			log_change "Tunnel '${LABEL}': force-rotate -- '${ACTIVE_NAME}' -> '${NEXT_NAME}'"
			if switch_peer "$IFACE" "$WG_IF" "$NEXT_PEER" "$ACTIVE_NAME" "$ROUTE_TABLE" "force-rotate"; then
				set_last_rotate "$IFACE"
				send_webhook "$LABEL" "$ACTIVE_NAME" "$NEXT_NAME" "rotated"
				log_info "Tunnel '${LABEL}': force-rotate complete -- now on '${NEXT_NAME}'"
				ROTATED=$((ROTATED + 1))
			else
				log_error "Tunnel '${LABEL}': force-rotate to '${NEXT_NAME}' failed ping verification"
				send_webhook "$LABEL" "$ACTIVE_NAME" "$NEXT_NAME" "ping_failed"
			fi
		fi

		i=$((i + 1))
	done

	# Warn if a target was given but matched nothing
	if [ "$ROTATED" = "0" ] && \
	   { [ -n "$FLAG_FORCE_ROTATE_LABEL" ] || [ -n "$FLAG_FORCE_ROTATE_IFACE" ]; }; then
		echo ""
		if [ -n "$FLAG_FORCE_ROTATE_IFACE" ]; then
			echo "Warning: --force-rotate --iface '${FLAG_FORCE_ROTATE_IFACE}' did not match any enabled tunnel."
		else
			echo "Warning: --force-rotate label '${FLAG_FORCE_ROTATE_LABEL}' did not match any enabled tunnel."
		fi
		echo "Available tunnels:"
		print_available_tunnels
	fi
}


# =============================================================================
# MAIN -- normal operation (cron, --fail, --revert)
# =============================================================================

parse_args "$@"

mkdir -p "$STATE_DIR"
check_dependencies
validate_config

# Pure subcommands — no lock needed
case "$SUBCOMMAND" in
	status) cmd_status; exit 0 ;;
	reset)  cmd_reset;  exit 0 ;;
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

# Dry-run / modifier banner for normal operation
if [ "$DRY_RUN" = "1" ] || [ "$FLAG_FAIL" = "1" ] || [ "$FLAG_FAIL_WAN" = "1" ] || \
   [ "$FLAG_REVERT" = "1" ] || [ "$FLAG_IGNORE_COOLDOWN" = "1" ]; then
	echo ""
	echo "========================================"
	echo "  wg_failover.sh v${VER}"
	[ "$DRY_RUN" = "1" ] && echo "  Mode          : DRY RUN -- no changes will be made"
	if [ "$FLAG_FAIL" = "1" ]; then
		if [ -n "$FLAG_FAIL_IFACE" ]; then
			echo "  Simulated fail: iface '${FLAG_FAIL_IFACE}'"
		else
			echo "  Simulated fail: label '${FLAG_FAIL_LABEL}'"
		fi
	fi
	[ "$FLAG_FAIL_WAN" = "1" ]        && echo "  WAN sim       : SIMULATED OUTAGE (--fail-wan)"
	[ "$FLAG_REVERT" = "1" ]          && echo "  Revert        : YES -- will switch back after success"
	[ "$FLAG_IGNORE_COOLDOWN" = "1" ] && echo "  Cooldown      : BYPASSED"
	[ -n "$FLAG_SWITCH_METHOD" ]      && echo "  Switch meth   : ${FLAG_SWITCH_METHOD} (--switch-method override)"
	echo "  $(date '+%Y-%m-%d %H:%M:%S')"
	echo "========================================"
	echo ""
fi

acquire_lock

# Throttle check — skipped when --fail/--fail-wan/--dry-run/--exercise active
if [ "$DRY_RUN" = "0" ] && [ "$FLAG_FAIL" = "0" ] && [ "$FLAG_FAIL_WAN" = "0" ] && [ "$FLAG_EXERCISE" = "0" ]; then
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

# Remove cooldown files for peers that no longer exist in uci config
cleanup_stale_cooldowns

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
log_verbose "Ping           : PING_VERIFY=${PING_VERIFY} TARGET=${PING_TARGET} FALLBACK=${PING_TARGET_FALLBACK:-none} COUNT=${PING_COUNT} TIMEOUT=${PING_TIMEOUT}"
log_verbose "WAN check      : WAN_IFACE=${WAN_IFACE:-disabled} TARGETS='${WAN_CHECK_TARGETS}'"
log_verbose "Post-switch    : HANDSHAKE_TIMEOUT=${POST_SWITCH_HANDSHAKE_TIMEOUT} DELAY=${POST_SWITCH_DELAY} GRACE=${POST_SWITCH_GRACE}"
_EFFECTIVE_SW_METHOD="${FLAG_SWITCH_METHOD:-$GLINET_SWITCH_METHOD}"
[ -z "$_EFFECTIVE_SW_METHOD" ] && _EFFECTIVE_SW_METHOD='uci'
log_verbose "Switch method  : ${_EFFECTIVE_SW_METHOD}$([ "$_EFFECTIVE_SW_METHOD" != "uci" ] && echo " (router: ${GLINET_ROUTER})" || true)"
log_verbose "Tunnels        : TUNNEL_COUNT=${TUNNEL_COUNT}"

BLANK_KEYWORD_SEEN=0
FAIL_LABEL_MATCHED=0

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

	set -- $POOL; POOL_COUNT=$#

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
	if [ "$FLAG_FAIL" = "1" ]; then
		tunnel_matches_target "$LABEL" "$IFACE" "$FLAG_FAIL_LABEL" "$FLAG_FAIL_IFACE"
		_FAIL_MATCH=$?
		if [ "$_FAIL_MATCH" = "0" ]; then
			SIMULATE_THIS=1
			FAIL_LABEL_MATCHED=1
		fi
	fi

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

	# -------------------------------------------------------------------------
	# WAN pre-flight check
	# Stale handshake detected — before failing over, confirm the internet
	# itself is reachable via WAN (bypassing all tunnels). If WAN has no
	# connectivity the stale handshake is almost certainly an internet outage,
	# not a dead VPN peer. Failover would exhaust and cooldown-lock all peers
	# for no benefit. Skip this cycle and let the next cron run retry.
	# Simulated failures (--fail) bypass this check so tests always run.
	# -------------------------------------------------------------------------
	if [ "$SIMULATE_THIS" = "0" ]; then
		if wan_is_reachable; then
			send_wan_webhook "up"
		else
			log_warn "Tunnel '${LABEL}': handshake stale (${AGE}s) but WAN has no connectivity -- skipping failover (internet outage?)"
			send_wan_webhook "down"
			i=$((i + 1))
			continue
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
		if [ "$SIMULATE_THIS" = "0" ] && ! wan_is_reachable; then
			log_warn "Tunnel '${LABEL}': WAN connectivity lost mid-failover -- aborting peer cycle"
			send_wan_webhook "down"
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
	elif [ "$FLAG_REVERT" = "1" ] && [ -z "$SWITCHED_TO_PEER" ]; then
		log_warn "Tunnel '${LABEL}': --revert requested but no switch occurred -- nothing to revert"
	fi

	i=$((i + 1))
done

# Warn if --fail was used but the target didn't match any tunnel
if [ "$FLAG_FAIL" = "1" ] && [ "$FAIL_LABEL_MATCHED" = "0" ]; then
	echo ""
	if [ -n "$FLAG_FAIL_IFACE" ]; then
		log_warn "No tunnel matched --fail --iface '${FLAG_FAIL_IFACE}'"
		echo "Warning: --fail --iface '${FLAG_FAIL_IFACE}' did not match any tunnel."
	else
		log_warn "No tunnel matched --fail label '${FLAG_FAIL_LABEL}'"
		echo "Warning: --fail label '${FLAG_FAIL_LABEL}' did not match any tunnel."
	fi
	echo "Available tunnels:"
	print_available_tunnels
fi

log_verbose "=== Check complete (PID $$) ==="
exit 0
