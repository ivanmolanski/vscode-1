#!/bin/bash
# code-server (linuxserver) entrypoint for Railway
#
# Runs code-server DIRECTLY (bypassing the linuxserver s6 overlay) so we can
# control auth and telemetry completely:
#   - --auth password    : login required before the editor loads
#   - --disable-telemetry: no data leaves the box
# The password is persisted to /config so it survives restarts, and is
# printed to the log on first boot for easy retrieval.

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
	echo "Generated code-server login password: $CS_PASSWORD" >&2
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

# Direct bind, password required
exec /app/code-server/bin/code-server \
	--bind-addr "[::]:8443" \
	--config /config/.config/code-server/config.yaml \
	--user-data-dir /config/data \
	--extensions-dir /config/extensions \
	--disable-telemetry \
	"${DEFAULT_WORKSPACE:-/config/workspace}"
