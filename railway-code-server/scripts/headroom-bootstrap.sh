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
#   2. The headroom venv + pinned headroom-ai[proxy] exist (created only when
#      missing, so a redeploy reuses the volume venv and skips the pip work).
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
PIN="headroom-ai[proxy]==0.39.1"

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

# 2. Ensure the headroom venv + pinned package exist.
if [ ! -x "$VENV/bin/headroom" ]; then
  echo "headroom venv missing -> creating ($VENV)"
  python3 -m venv "$VENV" || { echo "ERROR: python3 -m venv failed"; exit 0; }
  "$VENV/bin/pip" install --quiet --upgrade pip || true
  "$VENV/bin/pip" install --quiet "$PIN" || echo "ERROR: pip install $PIN failed"
fi
# Keep it at the known-good pin (no-op / offline-safe when already correct).
installed="$("$VENV/bin/pip" show headroom-ai 2>/dev/null | awk -F': ' '/^Version:/{print $2}')"
if [ "$installed" != "0.39.1" ]; then
  echo "headroom-ai version '$installed' != 0.39.1 -> reinstalling"
  "$VENV/bin/pip" install --quiet "$PIN" || echo "ERROR: pip pin failed"
fi

# 3. Start the self-heal watchdog (idempotent; launches proxy if down).
bash "$CFG/headroom-watchdog.sh" start || echo "WARNING: headroom watchdog start failed"

echo "=== headroom bootstrap done $(date -u +%FT%TZ) ==="
