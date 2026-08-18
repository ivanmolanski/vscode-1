#!/bin/bash
set -euo pipefail
PROXY="socks5h://127.0.0.1:1080"

echo "=== IPv6 TEST via SOCKS5 proxy ==="
# Quick structural pre-check; authoritative validation is the ipaddress
# parser below (rejects values like 1234 or :::: that this regex allows).
IPV6_RE='^[0-9a-fA-F:]+$'
# Wrap the curl substitution in an if so a non-zero status does not trigger
# set -e; record the status in CURL_RC and process output afterwards.
if CURL_OUT=$(curl -6 -sS --max-time 5 --proxy "$PROXY" https://api.ipify.org 2>&1); then
    CURL_RC=0
else
    CURL_RC=$?
fi
if [ $CURL_RC -eq 0 ] && [[ "$CURL_OUT" =~ $IPV6_RE ]] && python3 -c 'import ipaddress, sys
try:
    ipaddress.IPv6Address(sys.argv[1].strip())
except ValueError:
    sys.exit(1)' "$CURL_OUT"; then
    echo "IPv6 egress: $CURL_OUT"
    exit 0
elif [ $CURL_RC -ne 0 ]; then
    echo "IPv6 test FAILED (exit=$CURL_RC): $CURL_OUT"
    exit $CURL_RC
else
    echo "IPv6 test FAILED (invalid IPv6 response): $CURL_OUT"
    exit 1
fi
