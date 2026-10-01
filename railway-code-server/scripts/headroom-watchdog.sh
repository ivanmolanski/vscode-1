#!/usr/bin/env bash
#
# headroom-watchdog.sh — keep the PATH-2 Headroom proxy alive (no cron here).
#
# The code-server image has NO cron daemon and code-server is PID 1, so there
# is no resident service to respawn a dead proxy. This detached loop is the
# self-heal: every ~20s it health-checks :8787 and starts the proxy if down.
# Single-instance guarded with `flock`.
#
#   start   (default): launch the detached watchdog if not already running
#   stop:              stop the detached watchdog (leaves the proxy running)
#   status:            show whether the watchdog loop is running
#
# Source of truth: railway-code-server/scripts/headroom-watchdog.sh in the
# vscode-1 repo. Do not drift the two copies.
set -u

LOCK="/run/headroom-watchdog.lock"
LOG="/config/.headroom/watchdog.log"
PROXY="/config/headroom-proxy.sh"
INTERVAL="${HEADROOM_WATCHDOG_INTERVAL:-20}"

loop_body() {
  while :; do
    # Recreate the venv if it was wiped (e.g. volume restore) — guarded, cheap.
    if [ ! -x /config/.venv-headroom/bin/headroom ]; then
      bash /config/headroom-bootstrap.sh >>"$LOG" 2>&1 || true
    fi
    if ! bash "$PROXY" status >/dev/null 2>&1; then
      bash "$PROXY" start >>"$LOG" 2>&1 || true
    fi
    sleep "$INTERVAL"
  done
}

watchdog_pid() {
  # The detached loop's cmdline is: bash /config/headroom-watchdog.sh _run
  pgrep -f "headroom-watchdog.sh _run" 2>/dev/null | head -1
}

case "${1:-start}" in
  _run)
    # Runs under `flock` so only one loop ever holds the lock.
    loop_body
    ;;
  start)
    if [ -n "$(watchdog_pid)" ]; then
      echo "headroom-watchdog: already running (pid $(watchdog_pid))"
      exit 0
    fi
    setsid nohup flock "$LOCK" bash "$0" _run >>"$LOG" 2>&1 </dev/null &
    sleep 1
    if [ -n "$(watchdog_pid)" ]; then
      echo "headroom-watchdog: started (pid $(watchdog_pid)); log: $LOG"
    else
      echo "headroom-watchdog: FAILED to start; see $LOG" >&2
      exit 1
    fi
    ;;
  stop)
    pkill -f "headroom-watchdog.sh _run" 2>/dev/null || true
    echo "headroom-watchdog: stopped"
    ;;
  status)
    if [ -n "$(watchdog_pid)" ]; then
      echo "headroom-watchdog: running (pid $(watchdog_pid))"
    else
      echo "headroom-watchdog: not running"
    fi
    ;;
  *)
    echo "usage: $0 {start|stop|status}" >&2; exit 2
    ;;
esac
