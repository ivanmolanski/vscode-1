# Railway code-server + AirVPN Tunnel — State & Runbook

> Working state as of 2026-08-20. Everything below is verified live.

## Architecture

```
Browser ──> code-server (Railway, [::]:8443 behind Railway TLS)
                │
                ├─ direct egress ──────────────> Railway egress IP (observed:
                │                                 152.55.180.107 on deployment
                │                                 24beb6d3 — NOT stable, may change)
                │
                └─ privoxy :8118 (HTTP→SOCKS bridge)
                        │
                        └─ autossh SOCKS5 :1080 ──SSH:443──> Oracle VPS (Eddie/AirVPN)
                                                                │
                                                                └─ egress ──> 213.152.162.5 (AirVPN)
```

> The Railway egress IP is **not a routing or allowlist contract** — Railway's
> static outbound IP is disabled (see table below), so the address can change on
> any redeploy. The fwmark fix below is deliberately port-based and
> source-IP-independent for exactly this reason. Never pin or allowlist the
> Railway egress IP on the VPS.

## Railway

| Item | Value |
|---|---|
| Project | `37771514-d09d-4507-afa2-8c1789b586a4` |
| Environment | `6ec20020-b515-48d3-9903-54cefa9efc0e` (production) |
| Service | `d02a2391-fb16-4741-8819-d4739f0a20c9` |
| Domain | `code-server-production-e830.up.railway.app` |
| rootDirectory | `/railway-code-server` |
| Region | us-east4, plan pro |
| Static outbound IP | **disabled** (intentional) |
| Outbound IPv6 | **disabled** (intentional — VPS has no global v6; Eddie IPv6 stays intact inside container) |

## VPS `slayerfush` (Oracle)

- `140.238.139.20`, user `ubuntu`, key `C:\Users\dalkeith\.ssh\oracle_vps`
- ens3 = `10.0.0.96/24`, gateway `10.0.0.1` (OCI 1:1 NAT to public IP)
- sshd listens on **22 + 443** (Railway blocks outbound 22; tunnel connects on 443)
- Eddie (AirVPN) full-tunnel routes: `0.0.0.0/1 + 128.0.0.0/1 dev Eddie` (v4), `::/1 + 8000::/1` (v6)

### The fwmark fix (CRITICAL — do not remove)

Eddie's full-tunnel routes hijacked SYN-ACK replies to inbound SSH, killing the
Railway→VPS handshake. Fix: port-based fwmark policy routing (source-IP-independent,
immune to Railway egress changes):

```
mangle PREROUTING -i ens3 -p tcp --dport 22  -j CONNMARK --set-xmark 0x100010
mangle PREROUTING -i ens3 -p tcp --dport 443 -j CONNMARK --set-xmark 0x100010
mangle OUTPUT -m connmark --mark 0x100010 -j MARK --set-xmark 0x100010
ip rule add priority 5000 fwmark 0x100010 lookup railway-ssh
table railway-ssh (101): default via 10.0.0.1 dev ens3
```

Persistence (verified active+enabled):
- `/usr/local/sbin/railway-ssh-routing.sh` — idempotent applier
- `/etc/systemd/system/railway-ssh-routing.service` — oneshot, enabled
- `/etc/iptables/rules.v4` + `rules.v6` — netfilter-persistent save (includes mangle marks)
- `/etc/iproute2/rt_tables` — contains `101 railway-ssh` (verified intact)

Validated against iproute2 docs (baturin.org via Context7): `ip rule add fwmark X lookup T`
+ `ip route add default via GW dev IF table T` is the canonical PBR pattern; mark must be
set in a chain processed before the routing decision (mangle PREROUTING/OUTPUT ✓).

## Container entrypoint (`railway-code-server/docker-entrypoint.sh`)

- Tunnel gate: autossh → poll SOCKS :1080 via api.ipify.org (max 12s) → only then start privoxy
- Privoxy poll for readiness; CRITICAL aborts go to stderr (correct); status messages to stdout
- Proxy env: `ALL_PROXY=socks5h://127.0.0.1:1080`, `HTTP(S)_PROXY=http://127.0.0.1:8118`,
  NO_PROXY preserves inherited + Railway-internal defaults
- Stale-tunnel cleanup: root pidfile `/run/airvpn-tunnel.pid` + cmdline validation + bounded
  port-1080 release wait; aborts rather than racing an unkillable listener
- Do NOT add a raw TCP probe to :443 before SSH — it stales the sshd handshake
  ("banner exchange: invalid format")

## Verified end-to-end (deployment 24beb6d3, SUCCESS)

- SOCKS 1080 → `213.152.162.5` (AirVPN) ✓
- HTTP 8118 → `213.152.162.5` (AirVPN) ✓
- Direct → Railway egress IP (observed `152.55.180.107` on this deployment; may change) ✓
- privoxy active+enabled, dante active (1080 v4+v6), vpn-health clean
  (`EXPECTED_IP=213.152.162.5`) ✓

## PROTECTED files — NEVER commit

- `package.json` (custom deps)
- `.vscode/settings.json`
- Deleted `SECURITY.md` / `ThirdPartyNotices.txt` (must stay deleted locally, never commit the deletion)

## Secrets / rotation (ACTION FOR USER)

`rw-vars.json` (contained the `PASSWORD` value and the full `VPS_SSH_KEY` private key)
was **deleted** from disk. It was never committed (untracked), so no git history scrub
needed. **Rotate both:**
1. `PASSWORD` — set a strong value on the Railway service variable
2. `VPS_SSH_KEY` — generate a new keypair, put the private key in the Railway var.
   On the VPS, **remove the exposed key's public-key line from
   `/home/ubuntu/.ssh/authorized_keys`** before (or immediately after) appending the
   replacement, then verify the old private key can no longer authenticate
   (`ssh -i <old-key> ubuntu@140.238.139.20` must fail).

## Operational notes / lessons

- PowerShell mangles nested quotes in SSH commands — use `py -3` subprocess helper files
  (`python`/`python3` not on PATH; `py -3` works)
- `pkill -f tcpdump` over SSH kills the SSH session itself (cmdline match) — use
  `nohup timeout N tcpdump ... &` inside `sudo bash -c`
- Heredocs over SSH get mangled — write remote files via base64 encode/decode
- `railway exec` does not exist; use `railway ssh -- sh -c '...'`
- `railway logs --json` is NDJSON (line-delimited), not an array
- Terminal host is laggy; prefer short commands or Python helpers

## Git state

- Remote origin: `https://github.com/ivanmolanski/vscode-1.git`; upstream: `microsoft/vscode`
- HEAD == origin/main at last check; stash `stash@{0}: On main: local proxy fixes` — keep intact
- Upstream merges are safe for the tunnel solution: upstream never touches `railway-code-server/`
