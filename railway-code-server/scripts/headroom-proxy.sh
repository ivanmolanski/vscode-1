#!/usr/bin/env bash
#
# headroom-proxy.sh — keep the PATH-2 Headroom Copilot proxy alive on the
# code-server box.
#
# It supervises a DETACHED `headroom wrap vscode` process, which:
#   * validates GitHub Copilot access (from ~/.headroom/copilot_auth.json),
#   * exchanges it for a short-lived Copilot API token kept in-process
#     (never written to VS Code settings),
#   * starts the Headroom proxy on 127.0.0.1:8787,
#   * writes the marker-owned block to the VS Code settings file
#     (github.copilot.advanced.debug.overrideProxyUrl + overrideCapiUrl),
#   * runs a crash-restart watchdog on the proxy.
#
# Effect: native GitHub Copilot (model picker untouched, no "Headroom"
# model added) routes  client -> 127.0.0.1:8787 -> Headroom -> GitHub
# Copilot API. When the proxy is down, Copilot fails closed (no bypass).
#
# Auth: uses the GitHub OAuth user token in /config/.headroom/copilot_auth.json
# (produced by `headroom copilot-auth login` device flow). A ghp_ PAT is NOT
# valid for Copilot inference endpoints (400 "PATs not supported"), so any
# GITHUB_COPILOT_API_TOKEN / COPILOT_PROVIDER_BEARER_TOKEN in the environment
# is UNSET before launch — otherwise headroom's token provider short-circuits
# on the PAT and never consults the OAuth file.
#
# Persistence: this script + the headroom venv + copilot_auth.json all live on
# the persistent /config volume. A detached watchdog (headroom-watchdog.sh)
# keeps the process alive, and the image boot hook (docker-entrypoint.sh ->
# headroom-bootstrap.sh) re-launches it after every Railway redeploy.
#
# Usage: headroom-proxy.sh {start|stop|status}
set -u

HR_BIN="/config/.venv-headroom/bin/headroom"
SETTINGS="/config/data/User/settings.json"
PORT=8787
HEALTH_URL="http://127.0.0.1:${PORT}/health"
AUTH="/config/.headroom/copilot_auth.json"
LOG="/config/.headroom/proxy.log"
PIDFILE="/config/.headroom/proxy.pid"
# Launch dir = the headroom /p/<slug> project. headroom writes the matching
# /p/<slug> into settings.json, so it stays stable when we always launch from
# the same cwd (no slug thrash) and it is readable in the logs.
WORKDIR="/config/.headroom/kali-rolling"

# Keep OpenBLAS/OMP quiet and single-threaded (large-RAM box, small proxy).
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1

# GitHub Copilot credential — use the OAuth file, NOT the PAT.
#
# headroom's token provider (copilot_auth.py get_api_token) returns
# GITHUB_COPILOT_API_TOKEN verbatim whenever it is set, BEFORE it ever looks
# at copilot_auth.json. Railway injects GITHUB_COPILOT_API_TOKEN=<ghp_ PAT> as
# a service env var, and a PAT is hard-rejected by the Copilot inference
# endpoints (400 "Personal Access Tokens are not supported for this endpoint").
# So we UNSET both PAT-bearing vars; that forces headroom to fall through to
# the device-flow OAuth token saved at /config/.headroom/copilot_auth.json,
# which we verified returns 200 on /models and /chat/completions.
unset GITHUB_COPILOT_API_TOKEN COPILOT_PROVIDER_BEARER_TOKEN
if [ ! -f "$AUTH" ]; then
  echo "headroom-proxy: WARNING: no $AUTH — run 'headroom copilot-auth login' (OAuth required; a PAT will not work)" >&2
fi

health()  { curl -sf --max-time 4 "$HEALTH_URL" >/dev/null 2>&1; }

port_bound() {
  (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -Eq ":${PORT}(\s|$)"
}

# The wrap launcher's child proxy runs as `python -m headroom.cli proxy`
# (a DIFFERENT cmdline), so match both to stop the whole tree.
kill_headroom() {
  pkill -f "venv-headroom/bin/headroom wrap vscode" 2>/dev/null
  pkill -f "headroom\.cli proxy" 2>/dev/null
}

wrap_pid() {
  pgrep -f "venv-headroom/bin/headroom wrap vscode" 2>/dev/null | head -1
}

start() {
  if health; then
    echo "headroom-proxy: already healthy on :${PORT}"
    return 0
  fi
  if [ ! -x "$HR_BIN" ]; then
    echo "headroom-proxy: ERROR: $HR_BIN not found" >&2
    return 1
  fi
  if port_bound; then
    echo "headroom-proxy: :${PORT} bound but proxy not healthy yet; not launching a duplicate"
    return 0
  fi
  mkdir -p "$WORKDIR"
  # headroom reads the OAuth token via $HEADROOM_WORKSPACE_DIR (fallback
  # $HOME/.headroom). Pin it explicitly so it resolves the same regardless of
  # the calling user's HOME. Pin -p to a fixed port so the settings.json
  # override + this script's health check never drift to a free port.
  # Fully detach so the proxy survives the calling (watchdog/boot) shell.
  setsid nohup env HOME=/config HEADROOM_WORKSPACE_DIR=/config/.headroom \
    bash -c "cd '$WORKDIR' && exec '$HR_BIN' wrap vscode -p '$PORT' --settings-file '$SETTINGS'" \
    >>"$LOG" 2>&1 </dev/null &
  echo $! >"$PIDFILE"
  echo "headroom-proxy: launched (pid $(cat "$PIDFILE")); log: $LOG"
}

stop() {
  kill_headroom
  # Give the child proxy a moment, then force-kill stragglers.
  sleep 1
  kill_headroom
  pkill -9 -f "headroom\.cli proxy" 2>/dev/null
  pkill -9 -f "venv-headroom/bin/headroom wrap vscode" 2>/dev/null
  rm -f "$PIDFILE"
  echo "headroom-proxy: stop signalled"
}

status() {
  if health; then
    echo "headroom-proxy: healthy on :8787 (pid $(wrap_pid))"
    return 0
  fi
  local pid
  pid=$(wrap_pid)
  if [ -n "$pid" ]; then
    echo "headroom-proxy: process up (pid $pid) but proxy not healthy yet"
    return 1
  fi
  echo "headroom-proxy: DOWN"
  return 1
}

case "${1:-status}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  *) echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac
