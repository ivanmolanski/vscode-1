#!/usr/bin/env python3
"""Check Oracle VCN security list via OCI API."""
import oci
from oci.auth.signers import InstancePrincipalsSecurityTokenSigner
import json, urllib.request

signer = InstancePrincipalsSecurityTokenSigner()
headers = {"Authorization": "Bearer Oracle"}
req = urllib.request.Request("http://169.254.169.254/opc/v2/instance/", headers=headers)
inst = json.loads(urllib.request.urlopen(req).read())
region = inst["region"]
compartment = inst["compartmentId"]
print(f"Region: {region}")
print(f"Compartment: {compartment}")

net = oci.core.VirtualNetworkClient({"region": region}, signer=signer)
vcns = net.list_vcns(compartment_id=compartment)
for v in vcns.data:
    print(f"\nVCN: {v.display_name} ({v.id})")
    sls = net.list_security_lists(compartment_id=compartment, vcn_id=v.id)
    for sl in sls.data:
        print(f"  SL: {sl.display_name} ({sl.id})")
        for rule in sl.ingress_security_rules:
            proto = "all" if rule.protocol is None else rule.protocol
            port = "all"
            if rule.tcp_options and rule.tcp_options.destination_port_range:
                pr = rule.tcp_options.destination_port_range
                port = f"{pr.min}-{pr.max}"
            print(f"    {rule.source} -> proto={proto} port={port}")
