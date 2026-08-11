#!/bin/bash
# code-server (linuxserver) entrypoint for Railway
#
# The linuxserver image manages the app via s6-overlay (/init): it starts
# code-server on [::]:8443 as user abc with PUID/PGID, PASSWORD/SUDO_PASSWORD,
# DEFAULT_WORKSPACE, etc. (see root/etc/s6-overlay/s6-rc.d/svc-code-server/run).
# Railway conventions are honored here:
#   - RAILWAY_RUN_UID / RAILWAY_RUN_GID are set by Railway only when a
#     non-root image is detected, to align with volume ownership. The image
#     runs as 'abc' (default 1000:1000) via PUID/PGID, which matches Railway's
#     default mount ownership — so in practice no action is needed.

set -e

# Strip any stale `source .../.cargo/env` (or `. "$CARGO_HOME/env"`) lines that
# rustup may have injected into shell profiles. These lines error on every
# terminal open ("bash: /config/.cargo/env: No such file or directory") when the
# env file is missing or lives on the mounted volume. cargo/rustc are on PATH
# via /usr/local/bin symlinks, so the sourcing is never needed.
for f in /home/abc/.bashrc /home/abc/.profile /home/abc/.bash_profile /root/.bashrc /root/.profile; do
	if [ -f "$f" ]; then
		sed -i '/\.cargo\/env/d; /cargo\/env"/d' "$f" 2>/dev/null || true
	fi
done

if [ -e /init ]; then
	exec /init
fi

# Fallback (should not normally happen): launch code-server directly.
PASSWORD_ARGS=()
if [ -n "${PASSWORD:-}" ]; then
	PASSWORD_ARGS=(--auth password)
fi
exec /app/code-server/bin/code-server \
	--bind-addr "[::]:8443" \
	--user-data-dir /config/data \
	--extensions-dir /config/extensions \
	--disable-telemetry \
	"${PASSWORD_ARGS[@]}" \
	"${DEFAULT_WORKSPACE:-/config/workspace}"
