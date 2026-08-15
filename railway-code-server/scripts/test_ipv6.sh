#!/bin/bash
echo "=== EDDIE IPv6 ADDRESS ==="
EDDIE6=$(ip -6 addr show dev Eddie | grep 'inet6' | grep -v 'link' | head -1 | awk '{print $2}' | cut -d'/' -f1)
echo "Eddie IPv6: $EDDIE6"

echo "=== DANTE IPv6 TEST ==="
curl -6 -v --max-time 5 --proxy "socks5h://[$EDDIE6]:1080" https://api.ipify.org 2>&1 | head -20

echo "=== DANTE LOGS ==="
journalctl -u danted.service -n 20 --no-pager 2>/dev/null | tail -10
