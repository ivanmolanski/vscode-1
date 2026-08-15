#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/eddie/eddie.log"

start() {
    echo "[INFO] Starting Eddie CLI..."
    if pgrep -f "eddie-cli" >/dev/null 2>&1; then
        echo "[WARN] Eddie is already running."
        exit 0
    fi
    /usr/bin/eddie-cli \
        -batch \
        -connect \
        -login=allcaps \
        -password=cxz21cxz \
        -server=Chort \
        -mode.type=wireguard \
        -mode.protocol=udp \
        -network.entry.iplayer=ipv4-ipv6 \
        -network.ipv4.mode=in \
        -network.ipv6.mode=in \
        -network.ipv4.autoswitch=True \
        -network.ipv6.autoswitch=True \
        -wireguard.interface.mtu=1320 \
        -dns.mode=auto \
        -dns.check=True \
        -netlock=False \
        -netlock.connection=False \
        -log.file.enabled=True \
        -log.file.path="$LOG_FILE" \
        -ui.skip.promotional=True \
        -ui.skip.netlock.confirm=True \
        -updater.channel=none
}

stop() {
    echo "[INFO] Stopping Eddie CLI cleanly..."
    pkill -TERM -f "eddie-cli" || true
    sleep 2
    if pgrep -f "eddie-cli" >/dev/null 2>&1; then
        echo "[INFO] Sending SIGKILL to remaining eddie-cli processes..."
        pkill -KILL -f "eddie-cli" || true
    fi
    if pgrep -f "eddie-cli-elevated" >/dev/null 2>&1; then
        echo "[INFO] Sending SIGKILL to remaining eddie-cli-elevated processes..."
        pkill -KILL -f "eddie-cli-elevated" || true
    fi
    echo "[INFO] Eddie stopped."
}

status() {
    echo "=== Processes ==="
    ps aux | grep -E 'eddie-cli' | grep -v grep || echo "No eddie processes active."
    echo "=== Interfaces ==="
    ip link show | grep -E 'wg|tun|airvpn' || echo "No VPN interfaces."
    echo "=== Routes ==="
    ip route show default
    ip -6 route show default || true
    echo "=== Management Route ==="
    ip route get 38.64.163.31
}

case "${1:-}" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    status)
        status
        ;;
    restart)
        stop
        start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
