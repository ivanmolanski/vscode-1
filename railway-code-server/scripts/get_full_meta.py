#!/usr/bin/env python3
"""Get instance metadata from OCI IMDS (allowlisted non-sensitive keys only)."""
import json
import urllib.request

HEADERS = {"Authorization": "Bearer Oracle"}
IMDS_URL = "http://169.254.169.254/opc/v2/instance/"

# Only expose non-sensitive top-level keys
SAFE_KEYS = {
    "compartmentId", "region", "availabilityDomain", "id",
    "displayName", "shape", "state", "timeCreated",
    "agentConfig", "platformConfig",
}

req = urllib.request.Request(IMDS_URL, headers=HEADERS)
with urllib.request.urlopen(req, timeout=5) as resp:
    data = json.loads(resp.read())

for k, v in data.items():
    if k not in SAFE_KEYS:
        continue
    if not isinstance(v, (dict, list)):
        print(f"{k}: {v}")
    else:
        print(f"{k}: {json.dumps(v)[:200]}")
