#!/bin/bash
# Health check script for Eddie VPN + Dante SOCKS5
# Checks both services are alive and functional, restarts if dead
# Run via systemd timer every 60 seconds

set -euo pipefail
LOG="/var/log/vpn-health.log"

# Clear proxy env so curl uses direct connectivity for egress checks
unset NO_PROXY no_proxy HTTP_PROXY HTTPS_PROXY http_proxy https_proxy

log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') $1" >> "$LOG"; }

# Validate that a string is a single valid IPv4 address
is_valid_ipv4() {
    case "$1" in
        ''|*[!0-9.]*) return 1 ;;
    esac
    local IFS='.'
    set -- $1
    [ $# -eq 4 ] || return 1
    for octet in "$@"; do
        case "$octet" in
            ''|*[!0-9]*) return 1 ;;
            0?*) return 1 ;;
            25[6-9]|2[6-9][0-9]|[3-9][0-9][0-9]) return 1 ;;
        esac
    done
    return 0
}

# Curl + IPv4 validation: returns the IP or "TIMEOUT"
fetch_egress_ip() {
    local ip rc
    ip=$(curl -sS --fail --max-time 8 --proxy socks5h://127.0.0.1:1080 https://api.ipify.org 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$ip" ] || ! is_valid_ipv4 "$ip"; then
        echo "TIMEOUT"
    else
        echo "$ip"
    fi
}

# --- Check 1: Eddie VPN process alive ---
if ! systemctl is-active --quiet eddie.service; then
    log "EDDIE DOWN — restarting eddie.service"
    systemctl restart eddie.service
    sleep 10
fi

# --- Check 2: Dante SOCKS5 listening on port 1080 (validate before egress) ---
if ! ss -tlnp | grep -q ':1080 '; then
    log "DANTE DOWN — restarting danted.service"
    systemctl restart danted.service
    sleep 3
    if ! ss -tlnp | grep -q ':1080 '; then
        log "CRITICAL: Dante still not listening after restart"
    fi
fi

# --- Check 3: VPN egress IP is AirVPN (not VPS local IP) ---
# Only test egress if Dante is listening
if ss -tlnp | grep -q ':1080 '; then
    VPN_IP=$(fetch_egress_ip)
    if [ "$VPN_IP" = "TIMEOUT" ]; then
        # Retry once after brief pause
        sleep 3
        VPN_IP=$(fetch_egress_ip)
    fi
    EXPECTED_IP="104.254.90.235"
    if [ "$VPN_IP" != "$EXPECTED_IP" ]; then
        log "VPN EGRESS WRONG ($VPN_IP != $EXPECTED_IP) — restarting danted"
        systemctl restart danted.service
        sleep 5
        # Fresh egress check after Dante restart
        VPN_POST=$(fetch_egress_ip)
        if [ "$VPN_POST" = "TIMEOUT" ]; then
            sleep 3
            VPN_POST=$(fetch_egress_ip)
        fi
        # Only restart eddie if post-Dante check shows wrong IP (not a Dante/proxy issue)
        if [ "$VPN_POST" != "$EXPECTED_IP" ] && [ "$VPN_POST" != "TIMEOUT" ]; then
            log "Restarting eddie for wrong egress IP (post-Dante: $VPN_POST)"
            systemctl restart eddie.service
            sleep 8
        fi
        # Final re-verify
        VPN_IP2=$(fetch_egress_ip)
        if [ "$VPN_IP2" != "$EXPECTED_IP" ]; then
            log "CRITICAL: VPN still broken after restart ($VPN_IP2)"
        else
            log "VPN recovered after restart (egress: $VPN_IP2)"
        fi
    fi
else
    log "SKIP egress check: Dante not listening on 1080"
fi

# Rotate log if > 1MB
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv "$LOG" "${LOG}.old"
    log "Log rotated"
fi
