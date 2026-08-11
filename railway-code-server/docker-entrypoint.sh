#!/bin/bash
# code-server (linuxserver) entrypoint for Railway
#
# Runs code-server DIRECTLY (bypassing the linuxserver s6 overlay) so we can
# control auth and telemetry completely:
#   - --auth none        : no passwords, behaves like local VS Code
#   - --disable-telemetry: no data leaves the box
# The linuxserver /init always forces password auth and its own env handling,
# so we don't exec it — we own the process.

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

# Force the config to auth:none even if a stale config.yaml exists.
# Update checks stay ENABLED (no disable-update-check) so you're always
# prompted when a newer code-server version is available.
mkdir -p /config/.config/code-server
cat > /config/.config/code-server/config.yaml <<'EOF'
bind-addr: 0.0.0.0:8443
auth: none
password: ''
disable-telemetry: true
EOF

chown -R abc:abc /config 2>/dev/null || true

# No proxy domain, direct bind
exec /app/code-server/bin/code-server \
	--bind-addr "[::]:8443" \
	--user-data-dir /config/data \
	--extensions-dir /config/extensions \
	--auth none \
	--disable-telemetry \
	"${DEFAULT_WORKSPACE:-/config/workspace}"
