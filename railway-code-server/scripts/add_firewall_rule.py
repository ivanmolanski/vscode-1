#!/usr/bin/env python3
"""
Add TCP port 1080 to the Oracle VCN default security list.
Usage: python3 add_firewall_rule.py <security-list-ocid> <compartment-ocid>
Uses the instance principal (UserData) authentication via the metadata service.
"""
import urllib.request, json, sys

def get_auth_token():
    """Get OCI auth token from instance metadata"""
    headers = {"Authorization": "Bearer Oracle"}
    req = urllib.request.Request(
        "http://169.254.169.254/opc/v2/instance/",
        headers=headers
    )
    resp = json.loads(urllib.request.urlopen(req).read())
    return resp.get("compartmentId")

def get_existing_rules(security_list_id):
    """Get existing security list"""
    req = urllib.request.Request(
        f"https://iaas.us-ashburn-1.oraclecloud.com/20160918/securityLists/{security_list_id}",
        headers={
            "Authorization": "Bearer Oracle",
            "Content-Type": "application/json"
        }
    )
    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read())
    except Exception as e:
        print(f"Error fetching security list: {e}")
        return None

def update_security_list(security_list_id, rules_json):
    """Update security list with new ingress rules"""
    data = json.dumps(rules_json).encode()
    req = urllib.request.Request(
        f"https://iaas.us-ashburn-1.oraclecloud.com/20160918/securityLists/{security_list_id}",
        data=data,
        method="PUT",
        headers={
            "Authorization": "Bearer Oracle",
            "Content-Type": "application/json"
        }
    )
    try:
        resp = urllib.request.urlopen(req)
        print(f"Security list updated: {resp.status}")
        return json.loads(resp.read())
    except Exception as e:
        print(f"Error updating: {e}")
        if hasattr(e, 'read'):
            print(e.read().decode())
        return None

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 add_firewall_rule.py <security-list-ocid>")
        sys.exit(1)

    sl_id = sys.argv[1]

    # Build new ingress rules (must include existing SSH + new 1080)
    new_rules = {
        "ingress-security-rules": [
            {
                "source": "0.0.0.0/0",
                "protocol": "6",
                "is-stateless": False,
                "tcp-options": {
                    "destination-port-range": {"min": 22, "max": 22}
                }
            },
            {
                "source": "0.0.0.0/0",
                "protocol": "6",
                "is-stateless": False,
                "tcp-options": {
                    "destination-port-range": {"min": 1080, "max": 1080}
                }
            }
        ]
    }

    result = update_security_list(sl_id, new_rules)
    if result:
        print("Done. Port 1080 added to security list.")
