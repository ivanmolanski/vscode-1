# AirVPN + Tailscale exit-node gateway for Railway

This service is the **VPN gateway** for your code-server workspaces. It runs
**AirVPN (WireGuard)** for outbound internet and **Tailscale** advertised as an
**exit node**. Because Tailscale runs in **userspace-networking mode**, only
**proxy-aware egress** is routed through this gateway — not all code-server
traffic. Processes that honor `ALL_PROXY` / `HTTP_PROXY` / `HTTPS_PROXY` (git,
curl, node, etc.) are tunneled; raw sockets that ignore proxy variables are not.

## Architecture

```
[Railway: code-server container]  --Tailscale (userspace)-->  [this exit-node service]  --AirVPN-->  Internet
   (proxy-aware egress only)                                  (WireGuard + Tailscale exit node)
```

## Prerequisites (IMPORTANT)

This service **requires** Railway to provide:
- **`/dev/net/tun`** device
- **`NET_ADMIN`** capability

Railway's official "Tailscale Subnet Router" template provides these, so the
platform supports them. If this service fails to start with a TUN/NET_ADMIN
error, you must enable those capabilities on the Railway service (or use a
Railway template that grants them).

## Environment variables (set on the Railway service)

| Variable | Required | Description |
|----------|----------|-------------|
| `TS_AUTHKEY` | ✅ | Tailscale auth key (from Tailscale admin console → Keys) |
| `WG_CONFIG` | ✅ | Full AirVPN WireGuard `.conf` contents |
| `WG_INTERFACE` | ❌ | WireGuard interface name (default `wg0`) |
| `EXIT_NODE_NAME` | ❌ | Tailscale node hostname (default `railway-vpn-exit`) |

## What you need from AirVPN

1. Go to **AirVPN Client Area → Config Generator**
2. Choose **OS: Linux**, **Protocol: WireGuard**, **Port: UDP 4433** (recommended)
3. Choose a **Toronto, Canada** server (e.g. `Agena`, `Alhena`, `Alkurhah`, `Aludra`, `Alwaid`, `Alya`, `Angetenar`, `Arkab`, `Avior`, `Castula`, `Cephei`, `Chamukuy`, `Chort`, `Elgafar`, `Enif`, `Gorgonea`, `Kornephoros`, `Lesath`, `Mintaka`, `Regulus`, `Rotanev`, `Sadalbari`, `Saiph`, `Sargas`, `Sharatan`, `Sualocin`, `Tegmen`, `Tejat`, `Titawin`, `Tyl`, `Ukdah` — all Toronto)
4. Download the generated **`.conf`** file
5. Set the **entire contents** of that `.conf` as the `WG_CONFIG` env var on this Railway service

## What you need from Tailscale

1. Go to **Tailscale admin console → Settings → Keys**
2. Generate a **non-ephemeral** auth key (reusable). Do **not** use an
   ephemeral key: this is a long-lived exit node, and an ephemeral key would
   discard the node (and its exit-node approval) on every restart.
3. Set it as the `TS_AUTHKEY` env var on this Railway service
4. Mount a **Railway Volume at `/var/lib/tailscale`** so the node identity
   (`tailscaled.state`) persists across redeploys
5. After it connects, in the admin console find this node and **enable "Use as
   exit node"** (Edit route settings)

## Proxy flags and egress scope

`tailscaled` runs with userspace networking and exposes a SOCKS5 proxy and an
HTTP proxy listener:

```
tailscaled --tun=userspace-networking \
  --socks5-server=localhost:1055 \
  --outbound-http-proxy-listen=localhost:1055
```

On each code-server container, route proxy-aware traffic through this exit
node:

```bash
tailscale set --exit-node=<this-service-tailscale-ip>
export ALL_PROXY=socks5://localhost:1055
export HTTP_PROXY=socks5://localhost:1055
export HTTPS_PROXY=socks5://localhost:1055
```

These variables affect **only processes that honor proxy variables** (git,
curl, node, etc.). Programs that open raw sockets and ignore `*_PROXY` will
bypass the tunnel and use the container's default egress.

## Deploy

Deploy this directory as a **new Railway service** (Dockerfile builder). It is
independent from the code-server service.
