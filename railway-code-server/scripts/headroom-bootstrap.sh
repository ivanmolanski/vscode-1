#!/usr/bin/env bash
#
# headroom-bootstrap.sh — make the PATH-2 Headroom Copilot proxy persistent.
#
# Called from docker-entrypoint.sh BEFORE `exec code-server`, on every boot /
# Railway redeploy. It is IDEMPOTENT and NON-FATAL: any failure is logged and
# code-server still starts. It does NOT touch the OAuth credential
# (copilot_auth.json) — that is user-provisioned once via
# `headroom copilot-auth login` and persists on the /config volume.
#
# What it ensures:
#   1. The operator scripts (headroom-proxy.sh / headroom-watchdog.sh /
#      headroom-bootstrap.sh) are refreshed on the persistent /config volume
#      from the image copy, so a fresh volume gets them and a redeploy picks
#      up any update baked into the image.
#   2. The headroom venv + headroom-ai[proxy] exist, always tracking the
#      NEWEST published release — there are NO version pins (this matches the
#      GPU box's auto-update.sh policy). The venv is created only when missing,
#      and an existing venv is upgraded in place when it falls behind, so a
#      redeploy reuses the venv and skips the pip work when already current.
#   3. The flock-deduped self-heal watchdog is running; it launches the proxy
#      if it is not already up and keeps it alive (no cron daemon on this box).
#
# Effect: after this runs, native GitHub Copilot routes
#   client -> 127.0.0.1:8787 (Headroom) -> GitHub Copilot API
# with the model picker untouched, and it stays up across saves and redeploys.
set -u

LOG="/config/.headroom/bootstrap.log"
mkdir -p /config/.headroom
# Route everything from here on to the log (do not spam the code-server boot).
exec >>"$LOG" 2>&1
echo "=== headroom bootstrap $(date -u +%FT%TZ) ==="

IMG_DIR="/usr/local/lib/headroom"
CFG="/config"
VENV="/config/.venv-headroom"
# NO VERSION PINS. The extras ([proxy]) are stable package metadata, not a
# version constraint, so this always resolves to the newest published release.
PKG="headroom-ai[proxy]"
PYPI_JSON="https://pypi.org/pypi/headroom-ai/json"

# Latest published version, or empty when the index is unreachable. Launched
# through the AirVPN SOCKS tunnel (ALL_PROXY=socks5h://127.0.0.1:1080), which
# curl honors; any failure is non-fatal and simply leaves the current install.
latest_version() {
  curl -fsSL --max-time 20 "$PYPI_JSON" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])' 2>/dev/null
}

# 1. Refresh the operator scripts onto the persistent volume.
for s in headroom-proxy.sh headroom-watchdog.sh headroom-bootstrap.sh; do
  if [ -f "$IMG_DIR/$s" ]; then
    cp -f "$IMG_DIR/$s" "$CFG/$s" && chmod +x "$CFG/$s"
  fi
done
if [ ! -f "$CFG/headroom-proxy.sh" ] || [ ! -f "$CFG/headroom-watchdog.sh" ]; then
  echo "WARNING: headroom scripts not found in image ($IMG_DIR); skipping watchdog start"
  exit 0
fi

# 2. Ensure the headroom venv + newest headroom-ai[proxy] exist.
if [ ! -x "$VENV/bin/headroom" ]; then
  echo "headroom venv missing -> creating ($VENV)"
  python3 -m venv "$VENV" || { echo "ERROR: python3 -m venv failed"; exit 0; }
  "$VENV/bin/pip" install --quiet --upgrade pip || true
  "$VENV/bin/pip" install --quiet --upgrade "$PKG" || echo "ERROR: pip install $PKG failed"
fi
# Track the NEWEST release: upgrade in place whenever it is available. `pip
# install --upgrade` is a no-op when the venv already has the latest (and is
# offline-safe: a failed fetch leaves the working install untouched).
installed="$("$VENV/bin/pip" show headroom-ai 2>/dev/null | awk -F': ' '/^Version:/{print $2}')"
latest="$(latest_version)"
if [ -z "$installed" ]; then
  echo "headroom-ai not importable -> installing newest ($PKG)"
  "$VENV/bin/pip" install --quiet --upgrade "$PKG" || echo "ERROR: pip install failed"
elif [ -n "$latest" ] && [ "$installed" != "$latest" ]; then
  echo "headroom-ai $installed != latest $latest -> upgrading"
  "$VENV/bin/pip" install --quiet --upgrade "$PKG" || echo "ERROR: pip upgrade failed"
else
  echo "headroom-ai $installed is current${latest:+ (latest $latest)}"
fi
# Guarantee SOCKS support (idempotent; a persisted volume venv may predate it
# or a fresh venv may not have pulled it transitively).
if ! "$VENV/bin/python" -c "import socksio" >/dev/null 2>&1; then
  echo "socksio missing -> installing (headroom httpx needs it for SOCKS egress)"
  "$VENV/bin/pip" install --quiet socksio || echo "WARNING: socksio install failed (proxy will crash-loop on SOCKS egress)"
fi

# 3. Start the self-heal watchdog (idempotent; launches proxy if down).
bash "$CFG/headroom-watchdog.sh" start || echo "WARNING: headroom watchdog start failed"

echo "=== headroom bootstrap done $(date -u +%FT%TZ) ==="
