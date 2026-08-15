#!/bin/bash
set -euo pipefail

echo "=== PRIVOXY CONFIG (last 20 lines) ==="
sudo cat /etc/privoxy/config | tail -20

echo ""
echo "=== CHECKING EXISTING LISTENER ==="
if ss -tlnp | grep -q ':8118 '; then
    echo "Privoxy already listening on :8118"
    if CURL_OUT=$(curl -sS --max-time 3 --proxy http://127.0.0.1:8118 https://api.ipify.org 2>&1); then
        CURL_RC=0
    else
        CURL_RC=$?
    fi
    echo "Proxy test result: $CURL_OUT"
    exit $CURL_RC
else
    echo "No existing Privoxy listener found, starting one..."
    sudo /usr/sbin/privoxy --no-daemon /etc/privoxy/config &
    PRIVOXY_PID=$!
    trap "kill $PRIVOXY_PID 2>/dev/null" EXIT
    sleep 2
    if CURL_OUT=$(curl -sS --max-time 3 --proxy http://127.0.0.1:8118 https://api.ipify.org 2>&1); then
        CURL_RC=0
    else
        CURL_RC=$?
    fi
    echo "Proxy test result: $CURL_OUT"
    exit $CURL_RC
fi
