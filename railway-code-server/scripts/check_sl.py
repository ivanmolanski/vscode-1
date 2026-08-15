#!/usr/bin/env python3
"""Check VCN security list via OCI API."""
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

net = oci.core.VirtualNetworkClient({"region": region}, signer=signer)

# Get security list directly by OCID
sl_id = "ocid1.securitylist.oc1.ca-toronto-1.aaaaaaaaeh3cjcv3puxbaehmrhn32rrxn5e3oe4qrdldpwrulkhgxweqojxq"
try:
    sl = net.get_security_list(sl_id)
    print(f"SL: {sl.data.display_name}")
    print(f"Ingress rules: {len(sl.data.ingress_security_rules)}")
    for r in sl.data.ingress_security_rules:
        proto = r.protocol or "all"
        port = "all"
        if r.tcp_options and r.tcp_options.destination_port_range:
            port = f"{r.tcp_options.destination_port_range.min}-{r.tcp_options.destination_port_range.max}"
        print(f"  {r.source} -> proto={proto} port={port}")
except Exception as e:
    print(f"Error: {e}")
