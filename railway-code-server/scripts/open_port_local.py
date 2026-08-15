#!/usr/bin/env python3
"""Open port 1080 in Oracle VCN security list using local OCI API key."""
import oci
import sys

# Load config from local OCI config
config = oci.config.from_file(
    profile_name="DEFAULT",
    file_location="C:/Users/dalkeith/.oci/config"
)
print(f"Tenancy: {config['tenancy']}")
print(f"User: {config['user']}")
print(f"Region: {config['region']}")

# Create network client
net_client = oci.core.VirtualNetworkClient(config)

# List VCNs in the tenancy
print("\nListing VCNs...")
vcns = oci.pagination.list_call_get_all_results(
    net_client.list_vcns,
    compartment_id=config["tenancy"]
)
print(f"Found {len(vcns.data)} VCNs")
for v in vcns.data:
    print(f"  VCN: {v.display_name} ({v.id})")

# For each VCN, find security lists
for vcn in vcns.data:
    print(f"\nChecking VCN: {vcn.display_name}")
    sls = oci.pagination.list_call_get_all_results(
        net_client.list_security_lists,
        compartment_id=config["tenancy"],
        vcn_id=vcn.id
    )
    for sl in sls.data:
        print(f"  Security List: {sl.display_name} ({sl.id})")

        has_1080 = False
        existing_rules = list(sl.ingress_security_rules)
        for rule in existing_rules:
            if rule.tcp_options and rule.tcp_options.destination_port_range:
                if rule.tcp_options.destination_port_range.min <= 1080 <= rule.tcp_options.destination_port_range.max:
                    has_1080 = True
                    print(f"    Port 1080 already allowed!")

        if not has_1080:
            print(f"    Adding TCP 1080 ingress rule...")
            existing_rules.append(oci.core.models.IngressSecurityRule(
                source="0.0.0.0/0",
                protocol="6",
                is_stateless=False,
                tcp_options=oci.core.models.TcpOptions(
                    destination_port_range=oci.core.models.PortRange(min=1080, max=1080)
                ),
                description="Dante SOCKS5 proxy - Railway egress"
            ))
            update = oci.core.models.UpdateSecurityListDetails(
                display_name=sl.display_name,
                ingress_security_rules=existing_rules,
                egress_security_rules=sl.egress_security_rules
            )
            result = net_client.update_security_list(sl.id, update)
            print(f"    SUCCESS: {result.status}")

print("\nDone!")
