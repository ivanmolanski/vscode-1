#!/usr/bin/env python3
"""Open port 1080 in Oracle VCN security list using local OCI API key."""
import oci
import sys

# Load config from default OCI config location (~/.oci/config)
config = oci.config.from_file(profile_name="DEFAULT")
print(f"Region: {config['region']}")

# Create clients
net_client = oci.core.VirtualNetworkClient(config)
compute_client = oci.core.ComputeClient(config)

# Resolve target security lists via VNIC attachment → subnet
try:
    instance_client = oci.core.ComputeClient(config)
    # Get the instance's own VNICs to find the subnet
    # Use the compartment to list VCNs and find security lists
    vcns = oci.pagination.list_call_get_all_results(
        net_client.list_vcns, compartment_id=config["tenancy"]
    )
    target_sl_ids = set()
    for vcn in vcns.data:
        try:
            sls = oci.pagination.list_call_get_all_results(
                net_client.list_security_lists,
                compartment_id=config["tenancy"],
                vcn_id=vcn.id,
            )
            target_sl_ids.update(sl.id for sl in sls.data)
        except Exception:
            continue
except Exception as e:
    print(f"Resolution failed: {e}")
    sys.exit(1)

if not target_sl_ids:
    print("No security lists found")
    sys.exit(1)

for sl_id in target_sl_ids:
    try:
        sl = net_client.get_security_list(sl_id)
    except oci.exceptions.ServiceError as e:
        print(f"  Skipping {sl_id}: {e.status} {e.message}")
        continue

    sl_data = sl.data
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
                source="0.0.0.0/0",
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
            result = net_client.update_security_list(sl_data.id, update)
            print(f"    SUCCESS: {result.status}")
        except oci.exceptions.ServiceError as e:
            print(f"    FAILED: {e.status} - {e.message}")

print("\nDone!")
