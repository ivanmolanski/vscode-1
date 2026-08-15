#!/bin/bash
# Deploy hardened systemd units for Eddie VPN + Dante SOCKS5 + health watchdog
# Run this on the VPS to set everything up

set -euo pipefail

# Clear proxy env so internal requests use direct connectivity
unset NO_PROXY no_proxy HTTP_PROXY HTTPS_PROXY http_proxy https_proxy

echo "=== Deploying hardened service units ==="

# --- 1. Dante systemd service (install canonical unit) ---
if [ -f /tmp/danted.service ]; then
    cp /tmp/danted.service /etc/systemd/system/danted.service
else
    echo "WARN: /tmp/danted.service not found, skipping"
fi

# --- 2. VPN Health Watchdog service ---
cat > /etc/systemd/system/vpn-health.service << 'UNIT'
[Unit]
Description=VPN + Dante Health Check & Auto-Recovery
After=network-online.target eddie.service danted.service
Wants=eddie.service danted.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-health-check.sh

# Don't restart this service itself — it's triggered by the timer
Restart=no

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vpn-health
UNIT

# --- 3. VPN Health Watchdog timer (every 60s) ---
cat > /etc/systemd/system/vpn-health.timer << 'UNIT'
[Unit]
Description=VPN Health Check Timer (every 60s)

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=multi-user.target
UNIT

# --- 4. Install health check script ---
cp "$(dirname "$0")/vps_health_check.sh" /usr/local/bin/vpn-health-check.sh
chmod 755 /usr/local/bin/vpn-health-check.sh

# --- 5. Reload and enable ---
systemctl daemon-reload
systemctl enable danted.service
systemctl enable vpn-health.timer
systemctl enable eddie.service

# --- 6. Start Dante (Eddie should already be running) ---
systemctl start danted.service
systemctl start vpn-health.timer

echo "=== Done ==="
echo "eddie.service:  $(systemctl is-active eddie.service)"
echo "danted.service: $(systemctl is-active danted.service)"
echo "vpn-health:     $(systemctl is-active vpn-health.timer)"
echo "VPN egress:     $(curl -sS --max-time 5 https://api.ipify.org 2>/dev/null || echo 'UNREACHABLE')"
