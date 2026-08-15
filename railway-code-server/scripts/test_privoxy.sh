#!/bin/bash
echo "=== PRIVOXY CONFIG (last 20 lines) ==="
sudo cat /etc/privoxy/config | tail -20

echo ""
echo "=== PRIVOXY LOG ==="
sudo journalctl -u privoxy.service -n 5 --no-pager 2>&1

echo ""
echo "=== TRY RUNNING MANUALLY ==="
sudo privoxy --no-daemon /etc/privoxy/config &
PRIVOXY_PID=$!
sleep 2
curl -sS --max-time 3 --proxy http://127.0.0.1:8118 https://api.ipify.org 2>&1
echo ""
kill $PRIVOXY_PID 2>/dev/null
