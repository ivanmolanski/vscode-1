#!/bin/bash
# AirVPN (WireGuard) + Tailscale exit-node entrypoint for Railway.
#
# Environment variables (set on the Railway service):
#   TS_AUTHKEY        - Tailscale auth key (required, from Tailscale admin console)
#   WG_CONFIG         - full AirVPN WireGuard .conf contents (required)
#   WG_INTERFACE      - WireGuard interface name (default: wg0)
#   EXIT_NODE_NAME    - hostname for this Tailscale node (default: railway-vpn-exit)
#
# The container must have /dev/net/tun and NET_ADMIN capability.

set -e

WG_INTERFACE="${WG_INTERFACE:-wg0}"
EXIT_NODE_NAME="${EXIT_NODE_NAME:-railway-vpn-exit}"

# Enable IPv4 and IPv6 kernel IP forwarding. Required for this node to act as
# an exit node (route traffic for other tailnet devices). Must happen before
# `tailscale up --advertise-exit-node`.
if [ -f /proc/sys/net/ipv4/ip_forward ]; then
	echo 1 > /proc/sys/net/ipv4/ip_forward
fi
if [ -f /proc/sys/net/ipv6/conf/all/forwarding ]; then
	echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
fi

echo "[entrypoint] Starting AirVPN + Tailscale exit node..."

# --- 1. WireGuard (AirVPN) ---------------------------------------------------
if [ -z "$WG_CONFIG" ]; then
	echo "ERROR: WG_CONFIG environment variable is not set." >&2
	echo "Set it to the full AirVPN WireGuard .conf contents." >&2
	exit 1
fi

# Write the WireGuard config
mkdir -p /etc/wireguard
printf '%s\n' "$WG_CONFIG" > "/etc/wireguard/${WG_INTERFACE}.conf"
chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"

# Bring up the WireGuard interface (needs TUN + NET_ADMIN)
wg-quick up "$WG_INTERFACE"
echo "[entrypoint] WireGuard (AirVPN) is up."

# --- 2. Tailscale (exit node) ------------------------------------------------
if [ -z "$TS_AUTHKEY" ]; then
	echo "ERROR: TS_AUTHKEY environment variable is not set." >&2
	exit 1
fi

# Start tailscaled in the background (no systemd).
#
# The state file lives on a Railway Volume mounted at /var/lib/tailscale so
# the node identity survives redeploys. Use a NON-EPHEMERAL Tailscale auth
# key for this long-lived exit node; an ephemeral key would discard the node
# (and its exit-node approval) on every restart.
nohup tailscaled \
	--state=/var/lib/tailscale/tailscaled.state \
	--socket=/var/run/tailscale/tailscaled.sock \
	>/var/log/tailscaled.log 2>&1 &

# Wait for the socket
for i in $(seq 1 30); do
	[ -S /var/run/tailscale/tailscaled.sock ] && break
	sleep 1
done

# Authenticate and advertise as an exit node
tailscale up \
	--authkey="$TS_AUTHKEY" \
	--hostname="$EXIT_NODE_NAME" \
	--advertise-exit-node \
	--accept-routes=false

echo "[entrypoint] Tailscale exit node is up: $(tailscale ip -4 2>/dev/null || echo 'unknown')"

# --- 3. Keep alive -----------------------------------------------------------
# Tailscale needs the process to stay alive; tailscaled is backgrounded, so
# block here. If tailscaled dies, exit so Railway restarts the container.
while kill -0 "$(pgrep -f tailscaled | head -1)" 2>/dev/null; do
	sleep 10
done

echo "[entrypoint] tailscaled exited; restarting container." >&2
exit 1
