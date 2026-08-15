#!/bin/bash
set -euo pipefail
PROXY="socks5h://127.0.0.1:1080"

# IPv6-formatted address pattern (hex digits + colons)
IPV6_RE='^[0-9a-fA-F:]+$'

echo "=== IPv6 TEST via SOCKS5 proxy ==="
# Wrap the curl substitution in an if so a non-zero status does not trigger
# set -e; record the status in CURL_RC and process output afterwards.
if CURL_OUT=$(curl -6 -sS --max-time 5 --proxy "$PROXY" https://api.ipify.org 2>&1); then
    CURL_RC=0
else
    CURL_RC=$?
fi
if [ $CURL_RC -eq 0 ] && [[ "$CURL_OUT" =~ $IPV_RE ]]; then
    echo "IPv6 egress: $CURL_OUT"
    exit 0
elif [ $CURL_RC -ne 0 ]; then
    echo "IPv6 test FAILED (exit=$CURL_RC): $CURL_OUT"
    exit $CURL_RC
else
    echo "IPv6 test FAILED (invalid IPv6 response): $CURL_OUT"
    exit 1
fi
