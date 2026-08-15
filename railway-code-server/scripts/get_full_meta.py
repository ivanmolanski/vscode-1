#!/usr/bin/env python3
"""Get full instance metadata to find tenancy info."""
import json, urllib.request
headers = {"Authorization": "Bearer Oracle"}
req = urllib.request.Request("http://169.254.169.254/opc/v2/instance/", headers=headers)
data = json.loads(urllib.request.urlopen(req).read())
# Print ALL top-level keys
for k, v in data.items():
    if not isinstance(v, (dict, list)):
        print(f"{k}: {v}")
    else:
        print(f"{k}: {json.dumps(v)[:200]}")
