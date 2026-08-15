#!/usr/bin/env python3
"""Open port 1080 in Oracle VCN security list using OCI Python SDK + instance principals."""
import oci
import json
import sys
import urllib.request
from oci.auth.signers import InstancePrincipalsSecurityTokenSigner

IMDS_BASE = "http://169.254.169.254/opc/v2"


def imds_get(path):
    req = urllib.request.Request(
        f"{IMDS_BASE}{path}",
        headers={"Authorization": "Bearer Oracle"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


# Auth via instance principals
try:
    signer = InstancePrincipalsSecurityTokenSigner()
except Exception as e:
    print(f"ERROR: Instance principal auth failed: {e}")
    sys.exit(1)

# Get region and instance info from IMDS
try:
    inst = imds_get("/instance/")
    region = inst["region"]
    compartment = inst["compartmentId"]
    instance_id = inst["id"]
except Exception as e:
    print(f"ERROR: IMDS unreachable: {e}")
    sys.exit(1)

print(f"Region: {region}")
print(f"Compartment: {compartment}")

# Get VNIC info
vnic_id = ""
try:
    vnics = imds_get("/vnics/")
    if vnics:
        vnic_id = vnics[0].get("vnicId", "")
        print(f"VNIC from IMDS: {vnic_id}")
except Exception as e:
    print(f"VNIC metadata failed: {e}")

# Create clients
compute_client = oci.core.ComputeClient(config={"region": region}, signer=signer)
net_client = oci.core.VirtualNetworkClient(config={"region": region}, signer=signer)

# Resolve target security lists via VNIC attachment → subnet
target_sl_ids = set()
try:
    attachments = oci.pagination.list_call_get_all_results(
        compute_client.list_vnic_attachments,
        compartment_id=compartment,
        instance_id=instance_id,
    )
    for att in attachments.data:
        if att.subnet_id:
            subnet = net_client.get_subnet(att.subnet_id).data
            target_sl_ids.update(subnet.security_list_ids or [])
            print(f"  Subnet: {subnet.display_name} → SLs: {subnet.security_list_ids}")
except Exception as e:
    print(f"VNIC/subnet resolution failed: {e}")
    sys.exit(1)

if not target_sl_ids:
    print("No security lists resolved — aborting")
    sys.exit(1)

print(f"Target security lists: {len(target_sl_ids)}")

applied = False

for sl_id in target_sl_ids:
    try:
        sl = net_client.get_security_list(sl_id)
    except oci.exceptions.ServiceError as e:
        print(f"  Skipping {sl_id}: {e.status} {e.message}")
        continue

    sl_data = sl.data
    print(f"Security List: {sl_data.display_name} ({sl_data.id})")

    has_1080 = False
    existing_rules = list(sl_data.ingress_security_rules)
    for rule in existing_rules:
        # Match by explicit TCP port-range
        if rule.tcp_options and rule.tcp_options.destination_port_range:
            pr = rule.tcp_options.destination_port_range
            if pr.min <= 1080 <= pr.max:
                has_1080 = True
                print(f"  Port 1080 already allowed: {rule.source}:{pr.min}-{pr.max}")
        # Match by protocol="all" or protocol=None (unrestricted)
        elif rule.protocol is None or rule.protocol == "all":
            has_1080 = True
            print(f"  Port 1080 covered by all-protocol rule: {rule.source}")
        # TCP with no port restriction covers all TCP ports including 1080
        elif rule.protocol == "6":
            has_1080 = True
            print(f"  Port 1080 covered by unrestricted TCP rule: {rule.source}")

    if not has_1080:
        print(f"  Adding port 1080 ingress rule to {sl_data.display_name}...")
        existing_rules.append(
            oci.core.models.IngressSecurityRule(
                source="0.0.0.0/0",
                protocol="6",
                is_stateless=False,
                tcp_options=oci.core.models.TcpOptions(
                    destination_port_range=oci.core.models.PortRange(min=1080, max=1080)
                ),
                description="Dante SOCKS5 proxy",
            )
        )

        update_details = oci.core.models.UpdateSecurityListDetails(
            display_name=sl_data.display_name,
            ingress_security_rules=existing_rules,
            egress_security_rules=sl_data.egress_security_rules,
        )
        try:
            result = net_client.update_security_list(sl_id, update_details)
            print(f"  Result: {result.status}")
            applied = True
        except oci.exceptions.ServiceError as e:
            print(f"  FAILED to update {sl_data.display_name}: {e.status} {e.message}")

if not applied:
    print("No port-1080 rule was applied to any security list")
    sys.exit(1)
