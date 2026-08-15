#!/usr/bin/env python3
"""Open port 1080 in Oracle VCN security list using OCI Python SDK + instance principals."""
import oci
import json
from oci.auth.signers import InstancePrincipalsSecurityTokenSigner

# Auth via instance principals
signer = InstancePrincipalsSecurityTokenSigner()

# Get region from IMDS
import urllib.request
headers = {"Authorization": "Bearer Oracle"}
req = urllib.request.Request("http://169.254.169.254/opc/v2/instance/", headers=headers)
inst = json.loads(urllib.request.urlopen(req).read())
region = inst["region"]
compartment = inst["compartmentId"]
print(f"Region: {region}")
print(f"Compartment: {compartment}")

# Create network client
net_client = oci.core.VirtualNetworkClient(config={"region": region}, signer=signer)

# List VCNs to find ours
vcns = oci.pagination.list_call_get_all_results(net_client.list_vcns, compartment_id=compartment)
print(f"Found {len(vcns.data)} VCNs")
vcn = vcns.data[0]
print(f"VCN: {vcn.display_name} ({vcn.id})")

# List security lists
sls = oci.pagination.list_call_get_all_results(net_client.list_security_lists, compartment_id=compartment, vcn_id=vcn.id)
print(f"Found {len(sls.data)} security lists")

for sl in sls.data:
    print(f"Security List: {sl.display_name} ({sl.id})")

    # Check if port 1080 rule already exists
    has_1080 = False
    existing_rules = []
    for rule in sl.ingress_security_rules:
        existing_rules.append(rule)
        if rule.tcp_options and rule.tcp_options.destination_port_range:
            if rule.tcp_options.destination_port_range.min <= 1080 <= rule.tcp_options.destination_port_range.max:
                has_1080 = True
                print(f"  Port 1080 already allowed by rule: {rule.source} port {rule.tcp_options.destination_port_range.min}-{rule.tcp_options.destination_port_range.max}")

    if not has_1080:
        print(f"  Adding port 1080 ingress rule to {sl.display_name}...")

        # Build new rules - keep existing SSH rule + add 1080
        new_rules = list(existing_rules)
        new_rules.append(oci.core.models.IngressSecurityRule(
            source="0.0.0.0/0",
            protocol="6",  # TCP
            is_stateless=False,
            tcp_options=oci.core.models.TcpOptions(
                destination_port_range=oci.core.models.PortRange(min=1080, max=1080)
            ),
            description="Dante SOCKS5 proxy"
        ))

        update_details = oci.core.models.UpdateSecurityListDetails(
            display_name=sl.display_name,
            ingress_security_rules=new_rules,
            egress_security_rules=sl.egress_security_rules
        )

        result = net_client.update_security_list(sl.id, update_details)
        print(f"  Result: {result.status}")
    else:
        print(f"  Port 1080 already open, skipping")

print("Done")
