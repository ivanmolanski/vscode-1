#!/bin/bash
# code-server (linuxserver) entrypoint for Railway
#
# Runs code-server DIRECTLY (bypassing the linuxserver s6 overlay) so we can
# control auth and telemetry completely:
#   - --auth password    : login required before the editor loads
#   - --disable-telemetry: no data leaves the box
# The password is persisted to /config/.code-server-password (mode 600, on the
# volume) so it survives restarts. It is NEVER printed to the log — retrieve it
# from that file if needed.

set -e

# Strip any stale `source .../.cargo/env` (or `. "$CARGO_HOME/env"`) lines that
# rustup may have injected into shell profiles. These lines error on every
# terminal open ("bash: /config/.cargo/env: No such file or directory") when the
# env file is missing or lives on the mounted volume. cargo/rustc are on PATH
# via /usr/local/bin symlinks, so the sourcing is never needed.
# The user's home is /config (the Railway volume), so clean profiles there too.
for f in /config/.bashrc /config/.profile /config/.bash_profile /home/abc/.bashrc /home/abc/.profile /home/abc/.bash_profile /root/.bashrc /root/.profile; do
	if [ -f "$f" ]; then
		sed -i '/\.cargo\/env/d; /cargo\/env"/d; /CARGO_HOME\/env/d' "$f" 2>/dev/null || true
	fi
done

# Resolve the login password:
#   1. $PASSWORD env var if set (recommended: set it on the Railway service)
#   2. else generate a random one and persist it to /config so it is stable
CS_PASSWORD="${PASSWORD:-}"
if [ -z "$CS_PASSWORD" ] && [ -f /config/.code-server-password ]; then
	CS_PASSWORD="$(cat /config/.code-server-password)"
fi
if [ -z "$CS_PASSWORD" ]; then
	CS_PASSWORD="$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)"
	echo "$CS_PASSWORD" > /config/.code-server-password
	chmod 600 /config/.code-server-password
	echo "Generated new code-server login password (stored in /config/.code-server-password)"
fi

# Write the config with auth=password. Update checks stay ENABLED (no
# disable-update-check) so you are always prompted for newer versions.
mkdir -p /config/.config/code-server
cat > /config/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:8443
auth: password
password: ${CS_PASSWORD}
disable-telemetry: true
EOF

chown -R abc:abc /config 2>/dev/null || true

# Ensure the npm global bin is on PATH for terminal sessions (redundant with
# /usr/local already on PATH, but explicit never hurts)
export PATH="/usr/local/bin:$PATH"

# ---------------------------------------------------------------------------
# AirVPN tunnel — SSH dynamic SOCKS proxy through Oracle VPS (port 443).
# Railway blocks outbound TCP 22, so we connect to sshd on port 443 (sshd
# listens on 22+443 via ssh.socket.d override on the VPS). Proven working:
# egress 152.55.180.107 authed through the tunnel.
# NOTE: adding a raw TCP probe to :443 first makes sshd log 'banner exchange:
# invalid format' and stales the following SSH handshake — do not add one.
# ---------------------------------------------------------------------------
TUNNEL_HOST="140.238.139.20"
TUNNEL_USER="ubuntu"
TUNNEL_KEY="/tmp/tunnel_key"
TUNNEL_PORT=1080
TUNNEL_SSH_PORT=443

# Write SSH key from env var to file (never baked into image)
if [ -z "${VPS_SSH_KEY:-}" ]; then
	# Clean up any stale key from a previous container start
	rm -f "$TUNNEL_KEY" 2>/dev/null || true
	echo "WARNING: VPS_SSH_KEY not set — AirVPN tunnel will NOT start"
else
	echo "$VPS_SSH_KEY" > "$TUNNEL_KEY"
	chmod 600 "$TUNNEL_KEY"
fi

# Kill any stale tunnel from a previous container restart
# Use a root-owned pidfile under /run (not writable /tmp) and validate
# the PID's /proc command line before signaling.
cleanup_stale_tunnel() {
	local pidfile="/run/airvpn-tunnel.pid"
	local host_pattern="${TUNNEL_HOST//./\\.}"  # escape dots for regex

	# First, try to clean up using the pidfile if it exists and is valid
	if [ -f "$pidfile" ]; then
		local pid
		pid=$(cat "$pidfile" 2>/dev/null || true)
		if [[ "$pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$pid" ]; then
			# Verify the process command line matches our tunnel
			local cmdline
			cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || true)
			if [[ "$cmdline" == *"$TUNNEL_HOST"* ]] && { [[ "$cmdline" == *"autossh"* ]] || [[ "$cmdline" == *"ssh"*"-D"* ]]; }; then
				echo "Stopping stale tunnel (PID $pid) from pidfile"
				kill "$pid" 2>/dev/null || true
				# Wait for process to exit
				for i in $(seq 1 10); do
					if ! kill -0 "$pid" 2>/dev/null; then
						break
					fi
					sleep 0.5
				done
				# Force kill if still alive
				if kill -0 "$pid" 2>/dev/null; then
					kill -9 "$pid" 2>/dev/null || true
				fi
			fi
		fi
	fi

	# Fallback: pkill by escaped TUNNEL_HOST match (preserves existing behavior)
	pkill -f "ssh -D.*${host_pattern}" 2>/dev/null || true
	pkill -f "autossh.*${host_pattern}" 2>/dev/null || true

	# Wait for port 1080 to be released (bounded timeout with escalation)
	for i in $(seq 1 20); do
		if ! ss -tlnp | grep -q ":${TUNNEL_PORT} "; then
			break
		fi
		sleep 0.5
	done

	# Final check - if port still occupied, force kill only the process with an
	# exact dynamic-forwarding argument for our host and port. Parse
	# /proc/$pid/cmdline as NUL-delimited arguments so substring matches from
	# other arguments cannot trigger a kill; unrelated listeners stay up (the
	# abort check below then fails startup rather than racing them).
	if ss -tlnp | grep -q ":${TUNNEL_PORT} "; then
		echo "WARNING: Port ${TUNNEL_PORT} still occupied, forcing cleanup"
		local pids
		pids=$(ss -tlnp | grep ":${TUNNEL_PORT} " | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
		for pid in $pids; do
			# cmdline is NUL-delimited; mapfile -d '' splits on NUL.
			local -a args
			mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null || continue
			local has_forward=false i arg next target
			for (( i = 0; i < ${#args[@]}; i++ )); do
				arg="${args[$i]}"
				next="${args[$((i + 1))]:-}"
				if { [ "$arg" = "-D" ] && [ "$next" = "${TUNNEL_PORT}" ]; } || [ "$arg" = "-D${TUNNEL_PORT}" ]; then
					for target in "${args[@]}"; do
						if [[ "$target" == *"@${TUNNEL_HOST}" ]]; then
							has_forward=true
							break
						fi
					done
					break
				fi
			done
			if [ "$has_forward" = true ]; then
				kill -9 "$pid" 2>/dev/null || true
			fi
		done
		sleep 1
	fi

	# After escalation, verify the port was actually released. If the previous
	# tunnel still owns it, abort startup rather than racing the new autossh.
	if ss -tlnp | grep -q ":${TUNNEL_PORT} "; then
		echo "CRITICAL: Port ${TUNNEL_PORT} still owned after forced cleanup — aborting startup" >&2
		exit 1
	fi

	# Clean up pidfile
	rm -f "$pidfile" 2>/dev/null || true
}

cleanup_stale_tunnel

# Start the tunnel if VPS_SSH_KEY was provided and key file exists
tunnel_ok=false
if [ -n "${VPS_SSH_KEY:-}" ] && [ -f "$TUNNEL_KEY" ]; then
	# autossh for auto-reconnect
	# -M 0 : let ssh detect dead connections via ServerAliveInterval
	# -f    : fork to background after auth
	# -N    : no remote command
	# -D    : dynamic SOCKS5 forwarding
	export AUTOSSH_PIDFILE=/run/airvpn-tunnel.pid
	export AUTOSSH_LOGFILE=/tmp/airvpn-tunnel.log
	export AUTOSSH_PORT=0
	nohup autossh -M 0 -f -N \
		-o StrictHostKeyChecking=yes \
		-o UserKnownHostsFile=/root/.ssh/known_hosts \
		-o ServerAliveInterval=30 \
		-o ServerAliveCountMax=3 \
		-o ExitOnForwardFailure=yes \
		-o ConnectTimeout=10 \
		-p "${TUNNEL_SSH_PORT}" \
		-i "$TUNNEL_KEY" \
		-D "${TUNNEL_PORT}" \
		"${TUNNEL_USER}@${TUNNEL_HOST}" \
		2>>/tmp/airvpn-tunnel.log &

	# Wait for the tunnel to come up (max 12s)
	for i in $(seq 1 24); do
		if NO_PROXY= no_proxy= curl -sS --proxy socks5h://127.0.0.1:${TUNNEL_PORT} --connect-timeout 2 https://api.ipify.org >/dev/null 2>&1; then
			echo "AirVPN tunnel UP via SSH to ${TUNNEL_HOST}"
			tunnel_ok=true
			break
		fi
		sleep 0.5
	done
fi

if [ "$tunnel_ok" = true ]; then
	# Start privoxy as HTTP→SOCKS5 bridge for Node.js/Copilot
	# curl/git honor SOCKS5 directly via ALL_PROXY, but Node.js fetch needs HTTP proxy
	mkdir -p /run/privoxy
	cat > /tmp/privoxy.conf << PROXYEOF
listen-address 127.0.0.1:8118
listen-address [::1]:8118
forward-socks5 / 127.0.0.1:${TUNNEL_PORT} .
toggle 0
PROXYEOF
	/usr/sbin/privoxy --no-daemon /tmp/privoxy.conf &
	PRIVOXY_PID=$!
	# Poll for privoxy readiness instead of blind sleep
	for i in $(seq 1 10); do
		if kill -0 $PRIVOXY_PID 2>/dev/null && NO_PROXY= no_proxy= curl -sS --proxy http://127.0.0.1:8118 --connect-timeout 1 --max-time 5 https://api.ipify.org >/dev/null 2>&1; then
			break
		fi
		sleep 0.5
	done
	if ! kill -0 $PRIVOXY_PID 2>/dev/null; then
		echo "CRITICAL: Privoxy failed to start — exiting" >&2
		exit 1
	fi
	if ! NO_PROXY= no_proxy= curl -sS --proxy http://127.0.0.1:8118 --connect-timeout 2 --max-time 5 https://api.ipify.org >/dev/null 2>&1; then
		echo "CRITICAL: Privoxy not reachable on :8118 — exiting" >&2
		kill $PRIVOXY_PID 2>/dev/null
		exit 1
	fi
	echo "Privoxy 4.2.0 ready on :8118"

	# Set SOCKS5 proxy for curl/git (direct support)
	export ALL_PROXY="socks5h://127.0.0.1:${TUNNEL_PORT}"
	# Set HTTP proxy for Node.js/Copilot (privoxy bridges to SOCKS5)
	export HTTP_PROXY="http://127.0.0.1:8118"
	export HTTPS_PROXY="http://127.0.0.1:8118"
	export http_proxy="$HTTP_PROXY"
	export https_proxy="$HTTPS_PROXY"
	# Preserve any inherited NO_PROXY/no_proxy exclusions (either casing) while
	# appending the documented Railway-internal/localhost defaults.
	NO_PROXY="${NO_PROXY:-$no_proxy}"
	NO_PROXY="${NO_PROXY:+$NO_PROXY,}localhost,127.0.0.1,::1,.railway.internal,10.0.0.0/8,.svc,.cluster.local,.internal"
	export NO_PROXY
	export no_proxy="$NO_PROXY"
else
	if [ -n "${VPS_SSH_KEY:-}" ]; then
		echo "WARNING: AirVPN tunnel failed to establish — running WITHOUT proxy"
	fi
	echo "WARNING: No tunnel — running code-server unprotected"
fi

# Direct bind, password required
exec /app/code-server/bin/code-server \
	--bind-addr "[::]:8443" \
	--config /config/.config/code-server/config.yaml \
	--user-data-dir /config/data \
	--extensions-dir /config/extensions \
	--disable-telemetry \
	"${DEFAULT_WORKSPACE:-/config/workspace}"
