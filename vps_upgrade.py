# -*- coding: utf-8 -*-
"""Full apt update + upgrade on the VPS, with reboot check.

Configuration via environment (defaults preserved):
  VPS_KEY  - path to the SSH private key
  VPS_HOST - VPS hostname/IP
  VPS_USER - SSH user

Host key is pinned: ssh fails closed if the server key differs from the
out-of-band verified entry in the controlled known_hosts file.
"""
import os
import subprocess
import sys

VPS_KEY = os.environ.get('VPS_KEY', r'C:\Users\dalkeith\.ssh\oracle_vps')
VPS_HOST = os.environ.get('VPS_HOST', '140.238.139.20')
VPS_USER = os.environ.get('VPS_USER', 'ubuntu')

# Out-of-band verified host key (ed25519). Mismatch = MITM or rebuilt server;
# ssh refuses to connect rather than trusting an unknown key.
KNOWN_HOSTS = r'C:\Users\dalkeith\.ssh\oracle_vps_known_hosts'
KNOWN_HOSTS_ENTRY = (
    '140.238.139.20 ssh-ed25519 '
    'AAAAC3NzaC1lZDI1NTE5AAAAIB1FePPG7b/9e89XTFwtm9RxRiufeGCBKybqEzeo0+cC\n'
)


def ensure_known_hosts():
    if not os.path.isfile(VPS_KEY):
        sys.exit(f'ERROR: SSH key not found: {VPS_KEY}')
    os.makedirs(os.path.dirname(KNOWN_HOSTS), exist_ok=True)
    try:
        with open(KNOWN_HOSTS, 'r', encoding='utf-8') as f:
            if KNOWN_HOSTS_ENTRY in f.read():
                return
    except FileNotFoundError:
        pass
    with open(KNOWN_HOSTS, 'a', encoding='utf-8') as f:
        f.write(KNOWN_HOSTS_ENTRY)


def ssh(cmd, timeout=1800):
    r = subprocess.run(
        ['ssh', '-o', 'ConnectTimeout=10',
         '-o', 'StrictHostKeyChecking=yes',
         '-o', 'UserKnownHostsFile=' + KNOWN_HOSTS,
         '-o', 'BatchMode=yes', '-i', VPS_KEY,
         f'{VPS_USER}@{VPS_HOST}', cmd],
        capture_output=True, text=True, timeout=timeout,
        encoding='utf-8', errors='replace')
    print('RC:', r.returncode)
    print(r.stdout[-6000:] if len(r.stdout) > 6000 else r.stdout)
    if r.stderr:
        print('STDERR:', r.stderr[-2000:])
    return r.returncode


def main():
    ensure_known_hosts()

    print('=== 1. APT UPDATE ===')
    rc = ssh('sudo -n apt-get update -y', timeout=300)
    if rc != 0:
        sys.exit(f'ERROR: apt-get update failed (rc={rc}) — aborting')

    print('=== 2. APT UPGRADE (non-interactive, keep local configs) ===')
    rc = ssh("sudo -n DEBIAN_FRONTEND=noninteractive apt-get upgrade -y "
             "-o Dpkg::Options::='--force-confdef' "
             "-o Dpkg::Options::='--force-confold'", timeout=1800)
    if rc != 0:
        sys.exit(f'ERROR: apt-get upgrade failed (rc={rc}) — aborting')

    print('=== 3. AUTOREMOVE ===')
    rc = ssh('sudo -n DEBIAN_FRONTEND=noninteractive apt-get autoremove -y', timeout=600)
    if rc != 0:
        sys.exit(f'ERROR: apt-get autoremove failed (rc={rc}) — aborting')

    print('=== 4. REBOOT REQUIRED? ===')
    ssh('echo reboot_required=$(sudo -n cat /var/run/reboot-required 2>/dev/null || echo no); '
        'sudo -n cat /var/run/reboot-required.pkgs 2>/dev/null | head -10', timeout=30)

    print('=== 5. POST-UPGRADE HEALTH: services + tunnel ===')
    ssh('echo ---EDDIE---; ip route show | grep -c Eddie; '
        'echo ---FWMARK---; ip rule show | grep 5000; '
        'echo ---DANTE---; systemctl is-active danted; '
        'echo ---PRIVOXY---; systemctl is-active privoxy; '
        'echo ---SSH_ROUTING---; systemctl is-active railway-ssh-routing', timeout=60)


if __name__ == '__main__':
    main()
