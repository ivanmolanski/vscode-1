#!/usr/bin/env python3
"""
Attempt to open port 1080 via multiple OCI API strategies.
Strategy 1: Instance principal → compute API → get VNIC attachment → get subnet → get security list → update
Strategy 2: Try to list security lists directly at tenancy level
Strategy 3: Use metadata to get VNIC details, then use compute API
"""
import oci
import json
import urllib.request

# Auth via instance principals
signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()

# Get region from IMDS
headers = {"Authorization": "Bearer Oracle"}
req = urllib.request.Request("http://169.254.169.254/opc/v2/instance/", headers=headers)
inst = json.loads(urllib.request.urlopen(req).read())
region = inst["region"]
compartment = inst["compartmentId"]
instance_id = inst["id"]
print(f"Region: {region}")
print(f"Compartment: {compartment}")
print(f"Instance: {instance_id}")

# Also get VNIC ID from IMDS
vnic_req = urllib.request.Request("http://169.254.169.254/opc/v2/vnics/", headers=headers)
try:
    vnics = json.loads(urllib.request.urlopen(vnic_req).read())
    if vnics:
        vnic_id = vnics[0].get("vnicId", "")
        print(f"VNIC from IMDS: {vnic_id}")
    else:
        vnic_id = ""
except Exception as e:
    print(f"VNIC metadata failed: {e}")
    vnic_id = ""

# Create clients
compute_client = oci.core.ComputeClient(config={"region": region}, signer=signer)
net_client = oci.core.VirtualNetworkClient(config={"region": region}, signer=signer)

# Strategy 1: Use compute API to get VNIC attachment → subnet → security list
print("\n--- Strategy 1: Compute API → VNIC Attachment → Subnet → Security List ---")
try:
    attachments = oci.pagination.list_call_get_all_results(
        compute_client.list_vnic_attachments,
        compartment_id=compartment,
        instance_id=instance_id
    )
    print(f"Found {len(attachments.data)} VNIC attachments")
    for att in attachments.data:
        print(f"  Attachment: {att.id} VNIC: {att.vnic_id} Subnet: {att.subnet_id}")
        if att.subnet_id:
            print(f"  Getting subnet details...")
            subnet = net_client.get_subnet(att.subnet_id)
            print(f"  Subnet: {subnet.data.display_name} ({subnet.data.id})")
            print(f"  Security Lists: {subnet.data.security_list_ids}")

            for sl_id in subnet.data.security_list_ids:
                print(f"\n  Getting security list {sl_id}...")
                sl = net_client.get_security_list(sl_id)
                sl_data = sl.data

                has_1080 = False
                existing_rules = list(sl_data.ingress_security_rules)
                for rule in existing_rules:
                    if rule.tcp_options and rule.tcp_options.destination_port_range:
                        if rule.tcp_options.destination_port_range.min <= 1080 <= rule.tcp_options.destination_port_range.max:
                            has_1080 = True
                            print(f"    Port 1080 already open!")

                if not has_1080:
                    print(f"    Adding port 1080 ingress rule...")
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
                        display_name=sl_data.display_name,
                        ingress_security_rules=existing_rules,
                        egress_security_rules=sl_data.egress_security_rules
                    )
                    result = net_client.update_security_list(sl_id, update)
                    print(f"    Result: {result.status} - SUCCESS!")
except Exception as e:
    print(f"Strategy 1 failed: {e}")

# Strategy 2: Try VCN list at compartment level
print("\n--- Strategy 2: List VCNs directly ---")
try:
    vcns = oci.pagination.list_call_get_all_results(net_client.list_vcns, compartment_id=compartment)
    print(f"Found {len(vcns.data)} VCNs")
except Exception as e:
    print(f"Strategy 2 failed: {e}")

# Strategy 3: Try using the VNIC OCID from metadata to call get_vnic
if vnic_id:
    print(f"\n--- Strategy 3: Get VNIC details via API ---")
    try:
        vnic = net_client.get_vnic(vnic_id)
        print(f"  VNIC: {vnic.data}")
        subnet_id = vnic.data.subnet_id
        if subnet_id:
            print(f"  Subnet: {subnet_id}")
            subnet = net_client.get_subnet(subnet_id)
            print(f"  Security Lists: {subnet.data.security_list_ids}")
    except Exception as e:
        print(f"Strategy 3 failed: {e}")

print("\nDone!")
