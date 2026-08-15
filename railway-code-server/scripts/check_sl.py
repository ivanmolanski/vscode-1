#!/usr/bin/env python3
"""Check VCN security lists via OCI API."""
import sys
import time
import oci
from oci.auth.signers import InstancePrincipalsSecurityTokenSigner
import json, urllib.request

# Optional: restrict to one security list by OCID (e.g. sys.argv[1]).
filter_sl_id = sys.argv[1] if len(sys.argv) > 1 else None

# Signer construction can also hit IMDS, so bind it together with the
# metadata request in one bounded retry path; exit nonzero on failure.
signer = None
inst = None
for attempt in range(3):
    try:
        if signer is None:
            signer = InstancePrincipalsSecurityTokenSigner()
        headers = {"Authorization": "Bearer Oracle"}
        req = urllib.request.Request("http://169.254.169.254/opc/v2/instance/", headers=headers)
        with urllib.request.urlopen(req, timeout=5) as resp:
            inst = json.loads(resp.read())
        break
    except Exception as e:
        if attempt == 2:
            print(f"ERROR: IMDS/signer init failed after 3 attempts: {e}", file=sys.stderr)
            sys.exit(1)
        time.sleep(1)

region = inst["region"]  # type: ignore[union-attr]
compartment = inst["compartmentId"]  # type: ignore[union-attr]
print(f"Region: {region}")

net = oci.core.VirtualNetworkClient({"region": region}, signer=signer)

try:
    vcns = oci.pagination.list_call_get_all_results(net.list_vcns, compartment_id=compartment)
    found = False
    for v in vcns.data:
        sls = oci.pagination.list_call_get_all_results(
            net.list_security_lists, compartment_id=compartment, vcn_id=v.id
        )
        for sl in sls.data:
            if filter_sl_id and sl.id != filter_sl_id:
                continue
            found = True
            print(f"\nVCN: {v.display_name} ({v.id})")
            print(f"SL: {sl.display_name} ({sl.id})")
            print(f"Ingress rules: {len(sl.ingress_security_rules)}")
            for r in sl.ingress_security_rules:
                proto = r.protocol or "all"
                port = "all"
                if proto == "17" and r.udp_options and r.udp_options.destination_port_range:
                    pr = r.udp_options.destination_port_range
                    port = f"{pr.min}-{pr.max}"
                elif proto == "6" and r.tcp_options and r.tcp_options.destination_port_range:
                    pr = r.tcp_options.destination_port_range
                    port = f"{pr.min}-{pr.max}"
                elif proto in ("17", "6"):
                    port = "all"  # no destination range => all ports for that protocol
                print(f"  {r.source} -> proto={proto} port={port}")
    if filter_sl_id and not found:
        print(f"ERROR: security list {filter_sl_id} not found in any VCN", file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
