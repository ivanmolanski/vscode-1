#!/usr/bin/env python3
"""Open port 1080 in Oracle VCN security list using local OCI API key."""
import oci
import os
import sys

SOURCE_CIDR = os.environ.get("ALLOWED_SOURCE_CIDR", "0.0.0.0/0")

# Load config from default OCI config location (~/.oci/config)
config = oci.config.from_file(profile_name="DEFAULT")
print(f"Region: {config['region']}")

# Create clients
net_client = oci.core.VirtualNetworkClient(config)
compute_client = oci.core.ComputeClient(config)

# Resolve target security lists via VNIC attachment → subnet
target_sl_ids = set()
try:
    attachments = oci.pagination.list_call_get_all_results(
        compute_client.list_vnic_attachments,
        compartment_id=config["tenancy"],
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
    print("No security lists found")
    sys.exit(1)

for sl_id in target_sl_ids:
    try:
        sl_response = net_client.get_security_list(sl_id)
        sl_data = sl_response.data
        etag = sl_response.headers.get("etag")
    except oci.exceptions.ServiceError as e:
        print(f"  Skipping {sl_id}: {e.status} {e.message}")
        continue
    print(f"  Security List: {sl_data.display_name} ({sl_data.id})")

    has_1080 = False
    existing_rules = list(sl_data.ingress_security_rules)
    for rule in existing_rules:
        if rule.tcp_options and rule.tcp_options.destination_port_range:
            if rule.tcp_options.destination_port_range.min <= 1080 <= rule.tcp_options.destination_port_range.max:
                has_1080 = True
                print(f"    Port 1080 already allowed!")
        elif rule.protocol is None or rule.protocol == "all":
            has_1080 = True
            print(f"    Port 1080 covered by all-protocol rule!")
        elif rule.protocol == "6":
            has_1080 = True
            print(f"    Port 1080 covered by unrestricted TCP rule!")

    if not has_1080:
        print(f"    Adding TCP 1080 ingress rule...")
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
            result = net_client.update_security_list(sl_data.id, update, if_match=etag)
            print(f"    SUCCESS: {result.status}")
        except oci.exceptions.ServiceError as e:
            print(f"    FAILED: {e.status} - {e.message}")

print("\nDone!")
