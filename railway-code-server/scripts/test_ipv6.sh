#!/bin/bash
set -euo pipefail
PROXY="socks5h://127.0.0.1:1080"

echo "=== IPv6 TEST via SOCKS5 proxy ==="
CURL_OUT=$(curl -6 -sS --max-time 5 --proxy "$PROXY" https://api.ipify.org 2>&1)
CURL_RC=$?
if [ $CURL_RC -eq 0 ]; then
    echo "IPv6 egress: $CURL_OUT"
else
    echo "IPv6 test FAILED (exit=$CURL_RC): $CURL_OUT"
fi
exit $CURL_RC
