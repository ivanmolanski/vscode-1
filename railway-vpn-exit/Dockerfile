# AirVPN + Tailscale exit-node gateway for Railway
#
# This service is the VPN gateway for all your code-server workspaces.
# It runs:
#   1. WireGuard (AirVPN)  -> outbound internet via AirVPN
#   2. Tailscale           -> advertised as an EXIT NODE on your tailnet
#
# Your code-server containers (userspace Tailscale) route their traffic
# through this exit node, so all repo/VSCode traffic exits via AirVPN.
#
# Requires Railway to provide /dev/net/tun + NET_ADMIN (see README).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# --- Base packages -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
	iproute2 \
	iputils-ping \
	curl \
	wget \
	ca-certificates \
	gnupg \
	lsb-release \
	software-properties-common \
	wireguard-tools \
	iptables \
	procps \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

# --- Tailscale ---------------------------------------------------------------
# Official static binary (no systemd needed; we run tailscaled directly).
RUN curl -fsSL https://pkgs.tailscale.com/stable/tailscale_1.102.2_amd64.tgz -o /tmp/ts.tgz \
	&& tar -xzf /tmp/ts.tgz -C /tmp \
	&& cp /tmp/tailscale_1.102.2_amd64/tailscale /usr/local/bin/tailscale \
	&& cp /tmp/tailscale_1.102.2_amd64/tailscaled /usr/local/bin/tailscaled \
	&& rm -rf /tmp/ts.tgz /tmp/tailscale_1.102.2_amd64

# --- Entrypoint --------------------------------------------------------------
COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
