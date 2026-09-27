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

# ---------------------------------------------------------------------------
# APT STATE RESTORATION — restore apt lists from /config volume so
# apt-get upgrade/update works at runtime without rebuilding the image.
# ---------------------------------------------------------------------------
if [ -d /config/apt-state/lib/apt/lists ] && [ "$(ls -A /config/apt-state/lib/apt/lists 2>/dev/null)" ]; then
	mkdir -p /var/lib/apt/lists/partial
	cp -a /config/apt-state/lib/apt/* /var/lib/apt/ 2>/dev/null || true
	echo "[entrypoint] Restored apt lists from /config/apt-state"
fi
if [ -d /config/apt-state/cache ] && [ "$(ls -A /config/apt-state/cache 2>/dev/null)" ]; then
	cp -a /config/apt-state/cache/* /var/cache/apt/ 2>/dev/null || true
fi
# Keep apt state in sync: after any apt operation, save to /config
save_apt_state() {
	cp -a /var/lib/apt/* /config/apt-state/lib/ 2>/dev/null || true
	cp -a /var/cache/apt/* /config/apt-state/cache/ 2>/dev/null || true
}
trap save_apt_state EXIT

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
# PERSISTED TOOLS — symlink tools from /config volume into PATH so they
# survive container restarts. Users who install apt packages at runtime
# can add them here, or place binaries in /config/.local/bin.
# ---------------------------------------------------------------------------
mkdir -p /config/.local/bin
export PATH="/config/.local/bin:$PATH"

# Railway CLI — self-healing: the image ships a working binary; if it is
# missing or broken (e.g. a broken npm shim shadowed it), reinstall the
# latest via the official installer. Install directly into /config/.local/bin
# (first on PATH) so the active executable is replaced; -y skips the prompt.
mkdir -p /config/.local/bin
if ! railway --version >/dev/null 2>&1; then
	echo "[entrypoint] Railway CLI missing or broken — reinstalling latest..."
	curl -fsSL https://railway.com/install.sh | bash -s -- -y -b /config/.local/bin >/dev/null 2>&1 || true
fi
if [ -x /usr/local/bin/railway ] && [ ! -x /config/.local/bin/railway ]; then
	ln -sf /usr/local/bin/railway /config/.local/bin/railway 2>/dev/null || true
fi
railway --version >/dev/null 2>&1 && echo "[entrypoint] Railway CLI: $(railway --version 2>&1 | tail -1)" || echo "[entrypoint] WARNING: Railway CLI unavailable"

# Persist any apt-installed binaries that users add at runtime
# (users can also symlink their own binaries into /config/.local/bin)

# ---------------------------------------------------------------------------
# AirVPN tunnel — SSH dynamic SOCKS proxy through Oracle VPS (port 443).
# Railway blocks outbound TCP 22, so we connect to sshd on port 443 (sshd
# listens on 22+443 via ssh.socket.d override on the VPS). Proven working:
# egress 152.55.180.107 authed through the tunnel.
# NOTE: adding a raw TCP probe to :443 first makes sshd log 'banner exchange:
# invalid format' and stales the following SSH handshake — do not add one.
# ---------------------------------------------------------------------------
EXPECTED_IP="198.44.157.34"
TUNNEL_HOST="140.238.139.20"
TUNNEL_USER="ubuntu"
TUNNEL_KEY="/tmp/tunnel_key"
TUNNEL_PORT=1080
TUNNEL_SSH_PORT=443
REQUIRE_TUNNEL="${REQUIRE_TUNNEL:-0}"

# Write SSH key from env var to file (never baked into image)
if [ -z "${VPS_SSH_KEY:-}" ]; then
	# Clean up any stale key from a previous container start
	rm -f "$TUNNEL_KEY" 2>/dev/null || true
	echo "WARNING: VPS_SSH_KEY not set — AirVPN tunnel will NOT start" >&2
	if [ "${REQUIRE_TUNNEL:-0}" = "1" ]; then
		echo "CRITICAL: REQUIRE_TUNNEL=1 but VPS_SSH_KEY is empty — refusing to start code-server" >&2
		exit 1
	fi
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

	# Wait for the tunnel to come up with verified AirVPN egress IP (up to 30s)
	for i in $(seq 1 30); do
		egress_ip=$(NO_PROXY= no_proxy= curl -sSf --proxy socks5h://127.0.0.1:${TUNNEL_PORT} --connect-timeout 2 --max-time 4 https://api.ipify.org 2>/dev/null || true)
		if [ "$egress_ip" = "$EXPECTED_IP" ]; then
			echo "AirVPN tunnel UP via SSH to ${TUNNEL_HOST} (verified egress IP: ${egress_ip})"
			tunnel_ok=true
			break
		fi
		sleep 1
	done
fi

# --- HyperAI internal LLM tunnel (127.0.0.1:18080) ---------------------------
#
# VS Code BYOK points "HyperLLM (internal)" at 127.0.0.1:18080, which only
# means something on THIS container. Without the forward the Copilot extension
# fails with ECONNREFUSED 127.0.0.1:18080 even though the same model answers
# fine on http://140.238.139.20:18080 (the VPS reverse tunnel).
#
# The SSH port is re-randomised whenever the HyperAI container is recreated, so
# resolution is HYPERAI_SSH_PORT env -> /config/.hyperai-ssh-port cache, and
# there is deliberately NO port scan (that reads as an attack to HyperAI's edge
# and gets this IP throttled). A stale cache means no route, never a wrong one.
#
# Set HYPERAI_TUNNEL=0 to skip. The key and cache live on the /config volume, so
# they survive redeploys; only the ssh process is per-boot.
HYPERAI_SSH_HOST="${HYPERAI_SSH_HOST:-ssh.hyper.ai}"
HYPERAI_SSH_USER="${HYPERAI_SSH_USER:-root}"
HYPERAI_SSH_KEY="${HYPERAI_SSH_KEY:-/config/.ssh/salad_builder}"
HYPERAI_SSH_PORT_ENV="${HYPERAI_SSH_PORT:-}"
HYPERAI_PORT_CACHE="${HYPERAI_PORT_CACHE:-/config/.hyperai-ssh-port}"
HYPERAI_LOCAL_PORT="${HYPERAI_LOCAL_PORT:-18080}"

if [ "${HYPERAI_TUNNEL:-1}" = "1" ] && [ -f "$HYPERAI_SSH_KEY" ]; then
	hyperai_port=""
	if [ -n "$HYPERAI_SSH_PORT_ENV" ]; then
		hyperai_port="$HYPERAI_SSH_PORT_ENV"
	elif [ -f "$HYPERAI_PORT_CACHE" ]; then
		hyperai_port="$(tr -dc '0-9' < "$HYPERAI_PORT_CACHE" 2>/dev/null)"
	fi

	if [ -z "$hyperai_port" ]; then
		echo "HyperAI tunnel SKIPPED: no port. Set HYPERAI_SSH_PORT or write $HYPERAI_PORT_CACHE." >&2
	elif ss -tln | grep -q ":${HYPERAI_LOCAL_PORT} "; then
		echo "HyperAI tunnel already listening on ${HYPERAI_LOCAL_PORT}"
	else
		# autossh so a blip (or the HyperAI idle auto-shutdown) heals without
		# a redeploy. accept-new pins the key on first connect and refuses a
		# changed one afterwards.
		nohup autossh -M 0 -f -N \
			-o StrictHostKeyChecking=accept-new \
			-o UserKnownHostsFile=/config/.ssh/hyperai_known_hosts \
			-o ServerAliveInterval=30 \
			-o ServerAliveCountMax=3 \
			-o ExitOnForwardFailure=yes \
			-o ConnectTimeout=10 \
			-p "$hyperai_port" \
			-i "$HYPERAI_SSH_KEY" \
			-L "${HYPERAI_LOCAL_PORT}:127.0.0.1:8080" \
			-N "${HYPERAI_SSH_USER}@${HYPERAI_SSH_HOST}" \
			2>>/var/log/hyperai-tunnel.log &

		# Gate on the endpoint actually answering, not on the port being bound:
		# ssh can bind 18080 and still fail to reach a recreated upstream.
		hyperai_ok=false
		for i in $(seq 1 30); do
			if curl -sSf --noproxy '*' --max-time 4 "http://127.0.0.1:${HYPERAI_LOCAL_PORT}/health" 2>/dev/null | grep -q '"status":"ok"'; then
				hyperai_ok=true
				break
			fi
			sleep 1
		done
		if [ "$hyperai_ok" = true ]; then
			echo "HyperAI tunnel UP via ${HYPERAI_SSH_HOST}:${hyperai_port} -> 127.0.0.1:${HYPERAI_LOCAL_PORT}"
		else
			echo "HyperAI tunnel FAILED on port ${hyperai_port} (see /var/log/hyperai-tunnel.log); BYOK 'internal' will fail until the port is refreshed" >&2
		fi
	fi
else
	echo "HyperAI tunnel disabled or key missing at ${HYPERAI_SSH_KEY}"
fi

if [ "$tunnel_ok" = true ]; then
	# Start privoxy as HTTP→SOCKS5 bridge for Node.js/Copilot
	# curl/git honor SOCKS5 directly via ALL_PROXY, but Node.js fetch needs HTTP proxy
	mkdir -p /run/privoxy /etc/privoxy /var/log/privoxy
	# confdir/templdir are declared explicitly: Privoxy defaults confdir to the
	# config file's directory (/tmp), so without these it looks for templates in
	# /tmp/template and cannot render error pages ("Could not load template file
	# forwarding-failed"). make install (sysconfdir=/etc) puts templates in
	# /etc/templates.
	cat > /etc/privoxy/config << PROXYEOF
confdir /etc/privoxy
templdir /etc/templates
logdir /var/log/privoxy
listen-address 127.0.0.1:8118
listen-address [::1]:8118
forward-socks5 / 127.0.0.1:${TUNNEL_PORT} .
forward 127.*.*.*/ .
forward localhost/ .
forward <[::1]>/ .
toggle 0
PROXYEOF
	/usr/sbin/privoxy --no-daemon /etc/privoxy/config &
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
	# Error pages need the build-time templates; verify so a missing dir fails
	# loudly here instead of surfacing as an opaque 500 to the agent at runtime.
	if [ ! -f /etc/templates/forwarding-failed ]; then
		echo "WARNING: Privoxy templates missing at /etc/templates — error pages will 500" >&2
	fi

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
		echo "WARNING: AirVPN tunnel failed to establish" >&2
	fi
	if [ "${REQUIRE_TUNNEL:-0}" = "1" ]; then
		echo "CRITICAL: REQUIRE_TUNNEL=1 but AirVPN tunnel failed to establish — refusing to run code-server unprotected" >&2
		exit 1
	fi
	echo "WARNING: No tunnel — running code-server unprotected" >&2
fi

# ---------------------------------------------------------------------------
# Remote Docker host setup (dedicated Oracle Cloud Docker instance on port 443)
# ---------------------------------------------------------------------------
if [ -n "${VPS_SSH_KEY:-}" ]; then
	mkdir -p /root/.ssh /config/.ssh /home/abc/.ssh
	printf "%s\n" "$VPS_SSH_KEY" > /root/.ssh/id_ed25519
	printf "%s\n" "$VPS_SSH_KEY" > /config/.ssh/id_ed25519
	printf "%s\n" "$VPS_SSH_KEY" > /home/abc/.ssh/id_ed25519
	chmod 600 /root/.ssh/id_ed25519 /config/.ssh/id_ed25519 /home/abc/.ssh/id_ed25519 2>/dev/null || true
	chown -R abc:abc /home/abc/.ssh /config/.ssh 2>/dev/null || true

	cat << 'SSHEOF' > /root/.ssh/config
Host 132.145.108.162 docker-host
    HostName 132.145.108.162
    Port 443
    User ubuntu
    IdentityFile /root/.ssh/id_ed25519
    StrictHostKeyChecking yes
SSHEOF

	# Pinned host keys — fetched out-of-band from each instance
	# (cat /etc/ssh/ssh_host_ed25519_key.pub), NOT via ssh-keyscan.
	# If a host is rebuilt and its key changes, connections fail closed.
	cat << 'KHEOF' >> /root/.ssh/known_hosts
140.238.139.20 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB1FePPG7b/9e89XTFwtm9RxRiufeGCBKybqEzeo0+cC
132.145.108.162 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJSsWiBzkqipz+KYKBuwvhEJFLf0TvnaN0kYa2j+srry
KHEOF
	chmod 600 /root/.ssh/config /root/.ssh/known_hosts
	cp /root/.ssh/config /config/.ssh/config 2>/dev/null || true
	cp /root/.ssh/config /home/abc/.ssh/config 2>/dev/null || true
	cp /root/.ssh/known_hosts /config/.ssh/known_hosts 2>/dev/null || true
	cp /root/.ssh/known_hosts /home/abc/.ssh/known_hosts 2>/dev/null || true

	# Ensure default DOCKER_HOST is exported for terminal sessions
	export DOCKER_HOST="${DOCKER_HOST:-ssh://ubuntu@132.145.108.162:443}"
fi

# ---------------------------------------------------------------------------
# Extension management — everything as REGULAR marketplace extensions.
#
# The service's EXTENSIONS_GALLERY variable already points code-server at the
# Microsoft marketplace, so --install-extension pulls normal (auto-updating)
# builds. This block:
#   1. Purges stale extensions.json entries pointing at deleted dirs.
#   2. Installs GitHub.copilot (Copilot Chat is bundled in code-server).
#   3. Migrates legacy OpenVSX "-universal" builds to regular marketplace
#      builds (one-time, marker-guarded) — they then auto-update like desktop.
#   4. Forces extensions.autoUpdate on via Machine settings.
#
# IMPORTANT: installs run as user abc (the runtime user). Installing as root
# leaves root-owned dirs that code-server (running as abc) cannot register,
# which makes extensions vanish from the UI.
# ---------------------------------------------------------------------------
CS_BIN=/app/code-server/bin/code-server
EXT_DIR=/config/extensions
DATA_DIR=/config/data

install_ext() {
	su abc -s /bin/bash -c "$CS_BIN --extensions-dir $EXT_DIR --user-data-dir $DATA_DIR --install-extension $1 --force" >/dev/null 2>&1 \
		&& echo "[entrypoint] Installed/updated extension: $1" \
		|| echo "[entrypoint] WARNING: failed to install extension: $1" >&2
}

# 0) Drop registry entries whose extension dir no longer exists on disk
python3 - << 'PYEOF' 2>/dev/null || true
import json, os
p = os.path.join(os.environ.get('EXT_DIR', '/config/extensions'), 'extensions.json')
if os.path.exists(p):
    data = json.load(open(p))
    kept = [e for e in data if os.path.isdir(e.get('location', {}).get('path', ''))]
    if len(kept) != len(data):
        json.dump(kept, open(p, 'w'))
        print(f'[entrypoint] Purged {len(data)-len(kept)} stale registry entries')
PYEOF

# 1) Copilot agent (Copilot Chat is bundled in code-server at a newer version;
#    installing the marketplace build would be a downgrade and is refused)
[ -d "$EXT_DIR/github.copilot" ] || install_ext GitHub.copilot

# 2) One-time migration of OpenVSX "-universal" builds to marketplace builds
MIGRATION_MARKER="$DATA_DIR/.universal-exts-migrated"
if [ ! -f "$MIGRATION_MARKER" ]; then
	for d in "$EXT_DIR"/*-universal; do
		[ -d "$d" ] || continue
		ext_id=$(node -e "const p=require('$d/package.json'); console.log(p.publisher+'.'+p.name)" 2>/dev/null || true)
		if [ -n "$ext_id" ]; then
			echo "[entrypoint] Migrating $ext_id from OpenVSX build to marketplace build..."
			rm -rf "$d"
			install_ext "$ext_id"
		else
			echo "[entrypoint] WARNING: could not resolve id for $d — leaving in place" >&2
		fi
	done
	mkdir -p "$DATA_DIR"
	touch "$MIGRATION_MARKER"
fi

chown -R abc:abc "$EXT_DIR" 2>/dev/null || true

# 3) Machine-scope settings — applied to every repo/workspace.
#    Includes extension auto-update plus Copilot agent safety-gate disables so
#    no confirmation prompts or "assessed as high-risk" skips appear in any
#    workspace. Idempotent: merges keys, never clobbers the rest of the file.
mkdir -p "$DATA_DIR/Machine"
SETTINGS_JSON="$DATA_DIR/Machine/settings.json"
node -e "
const fs = require('fs');
const p = '$SETTINGS_JSON';
fs.mkdirSync(require('path').dirname(p), { recursive: true });
let s = {};
try { s = JSON.parse(fs.readFileSync(p, 'utf8')); } catch (_) {}
Object.assign(s, {
	'extensions.autoUpdate': true,
	'extensions.autoCheckUpdates': true,
	'chat.tools.riskAssessment.enabled': false,
	'chat.autopilot.advanced.enabled': false,
	'chat.tools.global.autoApprove': true,
	'chat.tools.terminal.enableAutoApprove': true,
	'chat.tools.terminal.autoApprove': { '/.*/': true },
	'chat.tools.terminal.ignoreDefaultAutoApproveRules': true,
	'chat.tools.edits.autoApprove': true,
	'chat.permissions.default': 'autoApprove'
});
fs.writeFileSync(p, JSON.stringify(s, null, 2));
console.log('[entrypoint] Seeded Machine settings (auto-update + agent auto-approve)');
" 2>/dev/null || echo "[entrypoint] WARNING: failed to seed Machine settings" >&2

# 3b) Seed Copilot storage flags (APPLICATION scope, state.vscdb ItemTable)
#     so the "Enable global auto approve?" and terminal auto-approve warning
#     dialogs never appear on first run.
STORAGE_DB="$DATA_DIR/User/globalStorage/state.vscdb"
mkdir -p "$DATA_DIR/User/globalStorage"
node -e "
const fs = require('fs');
const db = '$STORAGE_DB';
const keys = {
	'chat.tools.global.autoApprove.optIn': 'true',
	'chat.tools.terminal.autoApprove.warningAccepted': 'true'
};
// Node >=22 ships node:sqlite; avoids depending on the sqlite3 binary.
// DatabaseSync creates the file when absent (parent dir is mkdir'd above), so
// the flags are in place before the first code-server session starts.
const { DatabaseSync } = require('node:sqlite');
fs.mkdirSync(require('path').dirname(db), { recursive: true });
const conn = new DatabaseSync(db);
conn.exec('CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)');
for (const [k, v] of Object.entries(keys)) {
	conn.prepare(\"INSERT OR REPLACE INTO ItemTable (key,value) VALUES (?,?)\").run(k, v);
}
conn.close();
console.log('[entrypoint] Seeded auto-approve storage flags');
" 2>/dev/null || echo "[entrypoint] WARNING: could not seed storage flags (state.vscdb busy or node:sqlite unavailable)" >&2

# 3c) Seed user-scope MCP config — /config/data/User/mcp.json lives on the
#     persistent volume, so MCP servers added at Global scope survive
#     redeploys. Only created if missing (user edits are never overwritten).
MCP_JSON="$DATA_DIR/User/mcp.json"
if [ ! -f "$MCP_JSON" ]; then
	mkdir -p "$DATA_DIR/User"
	printf '{\n  "servers": {},\n  "inputs": []\n}\n' > "$MCP_JSON"
	echo "[entrypoint] Seeded user-scope mcp.json (persists on /config volume)"
fi

# ---------------------------------------------------------------------------
# 4) Patch the SERVED product.json with the marketplace gallery.
#
# The browser workbench fetches /product.json at page load and uses its
# extensionsGallery for the Extensions panel (search, recommendations,
# details). The EXTENSIONS_GALLERY env var only patches the server-side
# process — without this patch the browser gets extensionsGallery:null and
# falls back to Open VSX (no Copilot, thin search).
# ---------------------------------------------------------------------------
PRODUCT_JSON=/app/code-server/lib/vscode/product.json
if [ -f "$PRODUCT_JSON" ] && [ -n "${EXTENSIONS_GALLERY:-}" ]; then
	node -e "
const fs = require('fs');
const path = require('path');
const p = '$PRODUCT_JSON';
const product = JSON.parse(fs.readFileSync(p, 'utf8'));
product.extensionsGallery = JSON.parse(process.env.EXTENSIONS_GALLERY);
const tmp = p + '.tmp.' + process.pid;
try {
	fs.writeFileSync(tmp, JSON.stringify(product, null, 2));
	fs.renameSync(tmp, p);
	console.log('[entrypoint] Patched served product.json with marketplace gallery');
} catch (e) {
	try { fs.unlinkSync(tmp); } catch (_) {}
	console.error('[entrypoint] WARNING: failed to patch product.json: ' + e.message);
	process.exit(1);
}
" 2>/dev/null || echo "[entrypoint] WARNING: failed to patch product.json" >&2
fi

# ---------------------------------------------------------------------------
# 5) Patch the code-server bundle to disable sensitive-input detection.
#
# The /app layer is ephemeral and rebuilt from the stock code-server image on
# every Railway deploy, so the source-level change (sensitive-input detection
# always returns false, routing secret prompts to the agent like any other
# input) must be re-applied to the compiled workbench bundle at boot.
#
# The stock bundle is minified, so the anchor is the stable class member name
# `_isSensitivePrompt` (member names survive minification; the stock build has
# no `detectsSensitiveInputPrompt`). The patcher finds the method definition
# (an occurrence not preceded by `.`), brace-walks its body, and rewrites the
# body to `return!1` — that single definition gates every sensitive-input code
# path (cancel + redaction), so both the async and sync monitor branches fall
# through to "input required → signal the agent".
# Idempotent + signature-guarded: if the anchor is missing or already patched
# we continue — this must never fail container startup. Disable by setting
# PATCH_SENSITIVE_INPUT=0.
# ---------------------------------------------------------------------------
if [ "${PATCH_SENSITIVE_INPUT:-1}" != "0" ]; then
	SENSITIVE_BUNDLE="$(grep -rl --include='*.js' '_isSensitivePrompt' /app/code-server/lib/vscode 2>/dev/null | head -n 1)"
	[ -n "$SENSITIVE_BUNDLE" ] || SENSITIVE_BUNDLE="$(grep -rl --include='*.js' '_isSensitivePrompt' /app/code-server/lib/vs 2>/dev/null | head -n 1)"
	[ -n "$SENSITIVE_BUNDLE" ] || SENSITIVE_BUNDLE="$(grep -rl --include='*.js' '_isSensitivePrompt' /app/code-server/lib 2>/dev/null | head -n 1)"
	if [ -n "$SENSITIVE_BUNDLE" ]; then
		SENSITIVE_BUNDLE="$SENSITIVE_BUNDLE" node -e "
const fs = require('fs');
const p = process.env.SENSITIVE_BUNDLE;
const marker = '_isSensitivePrompt';
function patchDefinition(src, idx) {
	const prev = idx > 0 ? src[idx - 1] : '';
	if (prev === '.') { return null; }
	let i = idx + marker.length;
	while (i < src.length && /\s/.test(src[i])) { i++; }
	if (src[i] === '=') {
		if (src[i + 1] === '=') { return null; }
		i++;
		while (i < src.length && /\s/.test(src[i])) { i++; }
		if (src.slice(i, i + 8) === 'function') { i += 8; while (i < src.length && /\s/.test(src[i])) { i++; } }
	}
	if (src[i] !== '(') { return null; }
	let depth = 0, j = i;
	for (; j < src.length; j++) {
		if (src[j] === '(') { depth++; } else if (src[j] === ')') { depth--; if (depth === 0) { j++; break; } }
	}
	if (j >= src.length) { return null; }
	let k = j;
	while (k < src.length && /\s/.test(src[k])) { k++; }
	let bodyOpen = -1;
	if (src[k] === '{') { bodyOpen = k; } else if (src[k] === '=' && src[k + 1] === '>') {
		k += 2;
		while (k < src.length && /\s/.test(src[k])) { k++; }
		if (src[k] === '{') { bodyOpen = k; }
	}
	if (bodyOpen === -1) { return null; }
	let depth2 = 0, end = -1;
	for (let q = bodyOpen; q < src.length; q++) {
		if (src[q] === '{') { depth2++; } else if (src[q] === '}') { depth2--; if (depth2 === 0) { end = q; break; } }
	}
	if (end === -1) { return null; }
	const bodyTrim = src.slice(bodyOpen + 1, end).replace(/;$/, '').trim();
	if (bodyTrim === 'return!1' || bodyTrim === 'return false') { return null; }
	return { bodyOpen, end };
}
const src = fs.readFileSync(p, 'utf8');
let out = src;
let patched = 0;
let searchFrom = 0;
while (searchFrom < out.length) {
	const idx = out.indexOf(marker, searchFrom);
	if (idx === -1) { break; }
	const r = patchDefinition(out, idx);
	if (r) { out = out.slice(0, r.bodyOpen + 1) + 'return!1' + out.slice(r.end); patched++; searchFrom = idx + marker.length; }
	else { const next = out.indexOf(marker, idx + marker.length); searchFrom = next !== -1 ? next : idx + marker.length; }
}
if (patched > 0) {
	const tmp = p + '.tmp.' + process.pid;
	try {
		fs.writeFileSync(tmp, out);
		fs.renameSync(tmp, p);
		console.log('[entrypoint] Patched ' + p + ' (disabled sensitive-input detection, ' + patched + ' definition(s))');
	} catch (e) {
		try { fs.unlinkSync(tmp); } catch (_) {}
		console.error('[entrypoint] WARNING: failed to patch code-server bundle: ' + e.message);
		process.exit(0);
	}
} else {
	console.log('[entrypoint] Sensitive-input detection already disabled or absent in ' + p);
}
" 2>/dev/null || echo "[entrypoint] WARNING: failed to patch code-server bundle" >&2
	else
		echo "[entrypoint] WARNING: sensitive-input signature not found under /app/code-server/lib; skipping bundle patch" >&2
	fi
fi

# Direct bind, password required
# The extension host OOMs at the default ~4 GB V8 ceiling under several agent
# extensions (seen in logs as "Reached heap limit Allocation failed"). Raise it
# for the whole process tree; override with NODE_OPTIONS if the plan is smaller.
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=6144}"
exec /app/code-server/bin/code-server \
	--bind-addr "[::]:8443" \
	--config /config/.config/code-server/config.yaml \
	--user-data-dir /config/data \
	--extensions-dir /config/extensions \
	--disable-telemetry \
	"${DEFAULT_WORKSPACE:-/config/workspace}"
