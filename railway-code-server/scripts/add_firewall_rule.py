#!/usr/bin/env python3
"""
Add TCP port 1080 to an Oracle VCN security list.
Usage: python3 add_firewall_rule.py <security-list-ocid> <compartment-ocid>
Uses instance-principal authentication via the OCI Python SDK.
"""
import json
import sys
import urllib.request

import oci
from oci.auth.signers import InstancePrincipalsSecurityTokenSigner

IMDS_BASE = "http://169.254.169.254/opc/v2"


def get_region():
    """Get region from instance metadata."""
    req = urllib.request.Request(
        f"{IMDS_BASE}/instance/",
        headers={"Authorization": "Bearer Oracle"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())["region"]


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 add_firewall_rule.py <security-list-ocid> <compartment-ocid>")
        sys.exit(1)

    sl_id = sys.argv[1]
    compartment_id = sys.argv[2]

    try:
        signer = InstancePrincipalsSecurityTokenSigner()
        region = get_region()
    except Exception as e:
        print(f"Auth failed: {e}")
        sys.exit(1)

    net_client = oci.core.VirtualNetworkClient(config={"region": region}, signer=signer)

    # Validate security list belongs to the expected compartment
    try:
        sl_data = net_client.get_security_list(sl_id).data
    except oci.exceptions.ServiceError as e:
        print(f"ERROR: Failed to read security list {sl_id}: {e.status} {e.message}")
        sys.exit(1)

    if sl_data.compartment_id != compartment_id:
        print(f"ERROR: Security list compartment {sl_data.compartment_id} does not match expected {compartment_id}")
        sys.exit(1)

    existing_rules = list(sl_data.ingress_security_rules)

    # Check if port 1080 rule already exists
    has_1080 = False
    for rule in existing_rules:
        if rule.protocol == "6" and rule.tcp_options and rule.tcp_options.destination_port_range:
            pr = rule.tcp_options.destination_port_range
            if pr.min <= 1080 <= pr.max:
                has_1080 = True
                print(f"Port 1080 already allowed: {rule.source}:{pr.min}-{pr.max}")

    if has_1080:
        print("Done. Port 1080 already present.")
        sys.exit(0)

    # Append port-1080 rule to existing set
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

    details = oci.core.models.UpdateSecurityListDetails(
        display_name=sl_data.display_name,
        ingress_security_rules=existing_rules,
        egress_security_rules=sl_data.egress_security_rules,
    )
    try:
        result = net_client.update_security_list(sl_id, details)
        print(f"Security list updated: {result.status}")
    except oci.exceptions.ServiceError as e:
        print(f"ERROR: Failed to update security list: {e.status} {e.message}")
        sys.exit(1)
    print("Done. Port 1080 added to security list.")
