#!/usr/bin/env python3
import urllib.request, json
headers = {"Authorization": "Bearer Oracle"}
base = "http://169.254.169.254/opc/v2"
inst = json.loads(urllib.request.urlopen(urllib.request.Request(base+"/instance/", headers=headers)).read())
print("Compartment:", inst.get("compartmentId"))
vnic_att = json.loads(urllib.request.urlopen(urllib.request.Request(base+"/vnicAttachments/", headers=headers)).read())
for v in vnic_att:
    print("Vnic:", v.get("vnicId"))
    print("Subnet:", v.get("subnetId"))
    sid = v.get("subnetId","").split("/")[-1] if v.get("subnetId") else ""
if sid:
    sub = json.loads(urllib.request.urlopen(urllib.request.Request(f"{base}/subnet/{sid}/", headers=headers)).read())
    print("VCN:", sub.get("vcnId"))
    for sl in (sub.get("securityListIds") or []):
        print("SecurityList:", sl)
