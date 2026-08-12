# AirVPN + Tailscale exit-node gateway for Railway

This service is the **VPN gateway** for all your code-server workspaces. It runs
**AirVPN (WireGuard)** for outbound internet and **Tailscale** advertised as an
**exit node**, so every code-server container on your tailnet can route its
traffic through AirVPN.

## Architecture

```
[Railway: code-server container]  --Tailscale-->  [Railway: this exit-node service]  --AirVPN-->  Internet
   (userspace Tailscale client)                    (WireGuard + Tailscale exit node)
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
2. Generate an **auth key** (ephemeral is fine, or reusable)
3. Set it as the `TS_AUTHKEY` env var on this Railway service
4. After it connects, in the admin console find this node and **enable "Use as exit node"** (Edit route settings)

## Pointing code-server containers at this exit node

On each code-server container (userspace Tailscale), route traffic through this
exit node:

```bash
tailscale set --exit-node=<this-service-tailscale-ip>
export ALL_PROXY=socks5://localhost:1055
export HTTP_PROXY=socks5://localhost:1055
export HTTPS_PROXY=socks5://localhost:1055
```

## Deploy

Deploy this directory as a **new Railway service** (Dockerfile builder). It is
independent from the code-server service.
