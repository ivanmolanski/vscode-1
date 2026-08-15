#!/usr/bin/env python3
"""Get instance metadata from OCI IMDS."""
import json
import urllib.request

headers = {"Authorization": "Bearer Oracle"}
req = urllib.request.Request("http://169.254.169.254/opc/v2/instance/", headers=headers)
resp = urllib.request.urlopen(req)
data = json.loads(resp.read())

print(f"compartmentId: {data.get('compartmentId', 'N/A')}")
print(f"region: {data.get('region', 'N/A')}")
print(f"availabilityDomain: {data.get('availabilityDomain', 'N/A')}")
print(f"id: {data.get('id', 'N/A')}")
print(f"displayName: {data.get('displayName', 'N/A')}")

# Also try VNIC attachments
try:
    vnic_req = urllib.request.Request(
        "http://169.254.169.254/opc/v2/vnics/",
        headers=headers
    )
    vnic_resp = urllib.request.urlopen(vnic_req)
    vnics = json.loads(vnic_resp.read())
    print(f"\nVNICs found: {len(vnics)}")
    for v in vnics:
        print(f"  VNIC: {v.get('vnicId', 'N/A')}")
        print(f"  Subnet: {v.get('subnetId', 'N/A')}")
        print(f"  PrivateIP: {v.get('privateIp', 'N/A')}")
except Exception as e:
    print(f"\nVNIC fetch failed: {e}")
