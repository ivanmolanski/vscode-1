#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/eddie/eddie.log"

start() {
    echo "[INFO] Starting Eddie service (systemctl start eddie.service)..."
    systemctl start eddie.service
}

stop() {
    echo "[INFO] Stopping Eddie service (systemctl stop eddie.service)..."
    systemctl stop eddie.service
}

status() {
    echo "=== Service Unit Status ==="
    systemctl status eddie.service --no-pager || true
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
