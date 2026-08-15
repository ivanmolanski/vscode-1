#!/usr/bin/env python3
"""Get compartment, VNIC, subnet, VCN, and security-list OCIDs from instance metadata."""
import json
import sys
import urllib.request

import oci
from oci.auth.signers import InstancePrincipalsSecurityTokenSigner

IMDS_BASE = "http://169.254.169.254/opc/v2"
HEADERS = {"Authorization": "Bearer Oracle"}


def imds_get(path):
    req = urllib.request.Request(f"{IMDS_BASE}{path}", headers=HEADERS)
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


try:
    signer = InstancePrincipalsSecurityTokenSigner()
except Exception as e:
    print(f"ERROR: Instance principal auth failed: {e}")
    sys.exit(1)

try:
    inst = imds_get("/instance/")
    region = inst["region"]
except Exception as e:
    print(f"ERROR: IMDS metadata retrieval failed: {e}")
    sys.exit(1)

compartment = inst.get("compartmentId", "N/A")
print(f"Compartment: {compartment}")

compute_client = oci.core.ComputeClient(config={"region": region}, signer=signer)
net_client = oci.core.VirtualNetworkClient(config={"region": region}, signer=signer)

try:
    vnics = imds_get("/vnics/")
except Exception:
    vnics = []

# Collect every non-empty subnetId from all VNICs
subnet_ids = set()
for v in vnics:
    vnic_id = v.get("vnicId")
    print(f"Vnic: {vnic_id}")
    subnet_id = v.get("subnetId")
    print(f"Subnet: {subnet_id}")
    if subnet_id:
        subnet_ids.add(subnet_id)

for sid in subnet_ids:
    try:
        subnet = net_client.get_subnet(sid).data
        print(f"VCN: {subnet.vcn_id}")
        for sl in (subnet.security_list_ids or []):
            print(f"SecurityList: {sl}")
    except Exception as e:
        print(f"Subnet lookup failed for {sid}: {e}")
