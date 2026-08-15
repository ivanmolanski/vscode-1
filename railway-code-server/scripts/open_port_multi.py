#!/usr/bin/env python3
"""
Open port 1080 in Oracle VCN security list via VNIC → subnet resolution.
Uses instance-principal authentication.
"""
import oci
import json
import os
import sys
import urllib.request

from oci.auth.signers import InstancePrincipalsSecurityTokenSigner

IMDS_BASE = "http://169.254.169.254/opc/v2"
SOURCE_CIDR = os.environ.get("ALLOWED_SOURCE_CIDR", "0.0.0.0/0")


def covers_port_1080(rule):
    """Check if an ingress rule covers TCP port 1080."""
    if rule.protocol is None or rule.protocol == "all":
        return True
    if rule.protocol == "6" and (rule.tcp_options is None or rule.tcp_options.destination_port_range is None):
        return True
    if rule.tcp_options and rule.tcp_options.destination_port_range:
        pr = rule.tcp_options.destination_port_range
        if pr.min <= 1080 <= pr.max:
            return True
    return False


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
print(f"Instance: {instance_id}")

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
    print(f"Found {len(attachments.data)} VNIC attachments")
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

# Apply port-1080 rule to each resolved security list
success = False
for sl_id in target_sl_ids:
    try:
        sl_response = net_client.get_security_list(sl_id)
        sl_data = sl_response.data
        etag = sl_response.headers.get("etag")
    except oci.exceptions.ServiceError as e:
        print(f"  Skipping {sl_id}: {e.status} {e.message}")
        continue
    print(f"\nSecurity List: {sl_data.display_name} ({sl_data.id})")

    has_1080 = False
    has_matching_source = False
    existing_rules = list(sl_data.ingress_security_rules)
    for rule in existing_rules:
        if covers_port_1080(rule):
            if rule.source == SOURCE_CIDR:
                has_1080 = True
                has_matching_source = True
                print(f"  Port 1080 already allowed with correct source: {rule.source}")
            else:
                print(f"  WARNING: Port 1080 covered by {rule.source} but expected {SOURCE_CIDR} — will add correct rule")

    if has_1080 and has_matching_source:
        success = True
        continue

    print(f"  Adding port 1080 ingress rule...")
    existing_rules.append(
        oci.core.models.IngressSecurityRule(
            source=SOURCE_CIDR,
            protocol="6",
            is_stateless=False,
            tcp_options=oci.core.models.TcpOptions(
                destination_port_range=oci.core.models.PortRange(min=1080, max=1080)
            ),
            description="Dante SOCKS5 proxy - Railway egress",
        )
    )
    update = oci.core.models.UpdateSecurityListDetails(
        display_name=sl_data.display_name,
        ingress_security_rules=existing_rules,
        egress_security_rules=sl_data.egress_security_rules,
    )
    try:
        result = net_client.update_security_list(sl_id, update, if_match=etag)
        print(f"  Result: {result.status} - SUCCESS!")
        success = True
    except oci.exceptions.ServiceError as e:
        print(f"  FAILED: {e.status} - {e.message}")

if success:
    print("\nDone.")
else:
    print("\nFailed to open port 1080 on any security list.")
    sys.exit(1)
