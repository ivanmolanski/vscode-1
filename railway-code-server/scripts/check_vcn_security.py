#!/usr/bin/env python3
"""Check Oracle VCN security list via OCI API."""
import oci
from oci.auth.signers import InstancePrincipalsSecurityTokenSigner
import json
import sys
import urllib.request

# Signer construction may also hit IMDS (federation endpoint), so build it
# inside the same bounded retry path as the metadata request.
signer = None

# Fetch instance metadata with timeout and retry
inst = None
for attempt in range(3):
    try:
        if signer is None:
            signer = InstancePrincipalsSecurityTokenSigner()
        req = urllib.request.Request(
            "http://169.254.169.254/opc/v2/instance/",
            headers={"Authorization": "Bearer Oracle"},
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            inst = json.loads(resp.read())
        break
    except Exception as e:
        if attempt == 2:
            print(f"ERROR: IMDS unreachable after 3 attempts: {e}", file=sys.stderr)
            sys.exit(1)
        import time; time.sleep(1)

region = inst["region"]  # type: ignore[union-attr]
compartment = inst["compartmentId"]  # type: ignore[union-attr]
print(f"Region: {region}")
print(f"Compartment: {compartment}")

net = oci.core.VirtualNetworkClient({"region": region}, signer=signer)
vcns = oci.pagination.list_call_get_all_results(net.list_vcns, compartment_id=compartment)
for v in vcns.data:
    print(f"\nVCN: {v.display_name} ({v.id})")
    sls = oci.pagination.list_call_get_all_results(
        net.list_security_lists, compartment_id=compartment, vcn_id=v.id
    )
    for sl in sls.data:
        print(f"  SL: {sl.display_name} ({sl.id})")
        for rule in sl.ingress_security_rules:
            proto = "all" if rule.protocol is None else rule.protocol
            if rule.protocol == "17" and rule.udp_options and rule.udp_options.destination_port_range:
                pr = rule.udp_options.destination_port_range
                port = f"{pr.min}-{pr.max}"
            elif rule.protocol == "6" and rule.tcp_options and rule.tcp_options.destination_port_range:
                pr = rule.tcp_options.destination_port_range
                port = f"{pr.min}-{pr.max}"
            else:
                port = "all"  # omitted destination range means all ports for that protocol
            print(f"    {rule.source} -> proto={proto} port={port}")
