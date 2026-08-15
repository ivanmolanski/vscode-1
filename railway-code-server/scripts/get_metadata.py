#!/usr/bin/env python3
"""Get instance metadata from OCI IMDS."""
import json
import sys
import urllib.request

HEADERS = {"Authorization": "Bearer Oracle"}
IMDS_BASE = "http://169.254.169.254/opc/v2"

# Fetch instance metadata
try:
    req = urllib.request.Request(f"{IMDS_BASE}/instance/", headers=HEADERS)
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = json.loads(resp.read())
except Exception as e:
    print(f"ERROR: Instance metadata unreachable: {e}")
    sys.exit(1)

print(f"compartmentId: {data.get('compartmentId', 'N/A')}")
print(f"region: {data.get('region', 'N/A')}")
print(f"availabilityDomain: {data.get('availabilityDomain', 'N/A')}")
print(f"id: {data.get('id', 'N/A')}")
print(f"displayName: {data.get('displayName', 'N/A')}")

# Also try VNIC attachments
try:
    req = urllib.request.Request(f"{IMDS_BASE}/vnics/", headers=HEADERS)
    with urllib.request.urlopen(req, timeout=5) as resp:
        vnics = json.loads(resp.read())
    print(f"\nVNICs found: {len(vnics)}")
    for v in vnics:
        print(f"  VNIC: {v.get('vnicId', 'N/A')}")
        print(f"  Subnet: {v.get('subnetId', 'N/A')}")
        print(f"  PrivateIP: {v.get('privateIp', 'N/A')}")
except Exception as e:
    print(f"\nVNIC fetch failed: {e}")
