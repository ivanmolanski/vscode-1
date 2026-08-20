# code-server (VS Code in the browser) on Railway
# Base: linuxserver/code-server — web GUI on port 8443, state persisted in /config
FROM lscr.io/linuxserver/code-server:latest

# ---------------------------------------------------------------------------
# Developer toolchains & default packages (kept in the image, not in the volume)
# ---------------------------------------------------------------------------
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	git \
	git-lfs \
	curl \
	wget \
	unzip \
	zip \
	sudo \
	build-essential \
	pkg-config \
	python3 \
	python3-pip \
	python3-venv \
	python3-full \
	pipx \
	jq \
	less \
	htop \
	nano \
	vim-tiny \
	ca-certificates \
	gnupg \
	lsb-release \
	software-properties-common \
	openssh-client \
	rsync \
	net-tools \
	iputils-ping \
	dnsutils \
	libssl-dev \
	libffi-dev \
	python3-dev \
	docker.io \
	iproute2 \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

# Verify Docker CLI installed
RUN docker --version

# Node.js current (from Nodesource) - installs node + npm
RUN curl -fsSL https://deb.nodesource.com/setup_current.x | bash - && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

# npm global installs live in /usr/local (already on PATH automatically,
# just like npm --prefix on a local machine). With PUID=0 at runtime the
# user is root and can write anywhere, so no permission gymnastics needed.
# Cache goes to /tmp since it's ephemeral and doesn't need persistence.
ENV NPM_CONFIG_PREFIX=/usr/local \
	NPM_CONFIG_CACHE=/tmp/.npm-cache
# Ensure /usr/local/bin is on PATH for every process (not only login shells)
ENV PATH="/usr/local/bin:${PATH}"

# Corepack, yarn, pnpm - npm 11+ blocks install scripts by default, so opt
# corepack in via `--allow-scripts=corepack`
RUN cd /tmp && \
	npm install -g --allow-scripts=corepack corepack && \
	corepack enable && \
	corepack prepare yarn@stable --activate && \
	corepack prepare pnpm@latest --activate

# Bun — installed via its official installer (single static binary), NOT npm.
# npm's install-script lockdown skips bun's postinstall (which compiles the
# binary from node install.js) on some npm versions, leaving a dangling
# symlink; the official script is deterministic and arch-aware.
# BUN_INSTALL is under /opt (world-readable, shared) so the runtime user 'abc'
# can execute it; /root is not traversable by abc.
ENV BUN_INSTALL=/opt/bun
RUN curl -fsSL https://bun.com/install | bash && \
	ln -sf /opt/bun/bin/bun /usr/local/bin/bun && \
	chmod -R a+rX /opt/bun

# Python tooling:
#   - uv: standalone Rust binary via official installer (deterministic, no
#     pipx/venv, works for every user). Installed into /usr/local/bin (PATH).
#   - poetry, hatch: pip-installed CLIs → via pipx, with PIPX_BIN_DIR on the
#     shared PATH and PIPX_HOME under /opt so the runtime user 'abc' can
#     execute them (abc cannot traverse /root).
ENV PIPX_HOME=/opt/pipx \
	PIPX_BIN_DIR=/usr/local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh && \
	pipx install poetry && \
	pipx install hatch && \
	chmod -R a+rX /opt/pipx && \
	echo 'export PATH="/usr/local/bin:$PATH"' >> /etc/profile.d/pipx.sh

# Go 1.23
RUN curl -fsSL https://go.dev/dl/go1.23.0.linux-amd64.tar.gz | tar -xz -C /usr/local && \
	ln -sf /usr/local/go/bin/go /usr/local/bin/go && \
	ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# Rust (minimal profile). Install with --no-modify-path so rustup does NOT
# inject a `source $CARGO_HOME/env` line into the shell profile - that line
# errors on every terminal open ("bash: /config/.cargo/env: No such file or
# directory") when the env file is missing or lives on the mounted volume.
# The binaries are symlinked into /usr/local/bin, so no env sourcing is needed.
# RUSTUP_HOME/CARGO_HOME live under /opt/rust (world-readable, shared) so the
# runtime user 'abc' can traverse and write them; /root is not traversable by
# abc.
ENV RUSTUP_HOME=/opt/rust/.rustup \
	CARGO_HOME=/opt/rust/.cargo
RUN HOME=/opt/rust curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-host x86_64-unknown-linux-gnu --profile minimal --no-modify-path && \
	chown -R abc:abc /opt/rust && \
	chmod -R a+rX /opt/rust && \
	ln -sf /opt/rust/.cargo/bin/rustc /usr/local/bin/rustc && \
	ln -sf /opt/rust/.cargo/bin/cargo /usr/local/bin/cargo && \
	ln -sf /opt/rust/.cargo/bin/rustfmt /usr/local/bin/rustfmt && \
	ln -sf /opt/rust/.cargo/bin/clippy-driver /usr/local/bin/clippy-driver

# ---------------------------------------------------------------------------
# NO TELEMETRY — every toolchain opt-out. "No big brother anywhere."
# ---------------------------------------------------------------------------
ENV DO_NOT_TRACK=1 \
	CHECKPOINT_DISABLE=1 \
	TELEMETRY_DISABLED=1 \
	VSCODE_TELEMETRY=off \
	CODESIGNING_HELPER_DISABLE=1 \
	NPM_CONFIG_UPDATE_NOTIFIER=false \
	NPM_CONFIG_FUND=false \
	NPM_CONFIG_AUDIT=false \
	PIP_DISABLE_PIP_VERSION_CHECK=1 \
	PIP_NO_INDEX=0 \
	UV_NO_PROGRESS=1 \
	UV_DISABLE_TELEMETRY=1 \
	GOFLAGS=-buildvcs=false \
	GO111MODULE=on \
	GOTOOLCHAIN=local \
	RUSTUP_UPDATE_ROOT=https://static.rust-lang.org/rustup \
	CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse \
	PYTHONDONTWRITEBYTECODE=1 \
	PYTHONUNBUFFERED=1 \
	BUN_INSTALL=/opt/bun

# ---------------------------------------------------------------------------
# Git defaults - use --system so they apply to EVERY user at runtime, not just
# root. (--global writes /root/.gitconfig, which the runtime user never reads
# because HOME=/config.)
# ---------------------------------------------------------------------------
RUN git config --system init.defaultBranch main && \
	git config --system pull.rebase false && \
	git config --system core.autocrlf false && \
	git config --system core.filemode false && \
	git config --system advice.statusHints false && \
	git lfs install --system && \
	mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
	mkdir -p /home/abc/.ssh && chmod 700 /home/abc/.ssh && \
	chown -R abc:abc /home/abc/.ssh

# ---------------------------------------------------------------------------
# Telemetry opt-outs written to each tool's own config (persistent form)
# ---------------------------------------------------------------------------
RUN mkdir -p /etc/profile.d /root/.config /home/abc/.config && \
	printf '%s\n' \
		'[http]' \
		'	proxy = ""' \
		'[credential]' \
		'	helper = ""' \
		> /root/.gitconfig.telemetry 2>/dev/null; \
	printf '%s\n' \
		'export DO_NOT_TRACK=1' \
		'export CHECKPOINT_DISABLE=1' \
		'export TELEMETRY_DISABLED=1' \
		'export VSCODE_TELEMETRY=off' \
		'export PIP_DISABLE_PIP_VERSION_CHECK=1' \
		'export UV_DISABLE_TELEMETRY=1' \
		'export UV_NO_PROGRESS=1' \
		'export CARGO_HTTP_MULTIPLEXING=false' \
		'export RUSTUP_UPDATE_ROOT=https://static.rust-lang.org/rustup' \
		'export GOFLAGS=-buildvcs=false' \
		'export PYTHONDONTWRITEBYTECODE=1' \
		'export NPM_CONFIG_UPDATE_NOTIFIER=false' \
		'export NPM_CONFIG_FUND=false' \
		'export NPM_CONFIG_AUDIT=false' \
		> /etc/profile.d/99-telemetry-off.sh && \
	chmod 644 /etc/profile.d/99-telemetry-off.sh && \
	chown -R abc:abc /home/abc/.config && \
	chmod -R a+rX /etc/profile.d

# ---------------------------------------------------------------------------
# Entrypoint + helper. The image has NO original docker-entrypoint.sh (its
# usr/local/bin only ships install-extension), so this COPY is additive.
# Persistence: the image's own s6 init creates /config/{extensions,data,
# workspace,.ssh} and chowns them to abc - attach the Railway volume at
# /config.
# ---------------------------------------------------------------------------
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=755 clone-repo.sh /usr/local/bin/clone-repo.sh

# ---------------------------------------------------------------------------
# AirVPN tunnel — SSH dynamic SOCKS proxy through Oracle VPS (port 443).
# The VCN security list + instance iptables now allow inbound TCP 443 (v4+v6),
# and sshd listens on 22+443 via ssh.socket.d override, so we open an
# ssh -D tunnel from inside the container to the VPS where Dante routes
# traffic through AirVPN. ALL_PROXY points to localhost:1080 (the tunnel).
# Privoxy 4.2.0 provides an HTTP proxy on :8118 that forwards to the SOCKS5
# tunnel, for applications (like Node.js/Copilot) that don't honor socks5h://.
# ---------------------------------------------------------------------------
RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	autossh \
	autoconf \
	libpcre2-dev \
	libssl-dev \
	zlib1g-dev \
	build-essential \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

# Build privoxy 4.2.0 from source (Ubuntu only ships 3.x)
RUN cd /tmp && \
	wget -q http://deb.debian.org/debian/pool/main/p/privoxy/privoxy_4.2.0.orig.tar.gz && \
	tar xzf privoxy_4.2.0.orig.tar.gz && \
	cd privoxy-4.2.0-stable && \
	autoheader && autoconf && \
	./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var && \
	make -j$(nproc) && \
	make install && \
	rm -rf /tmp/privoxy-4.2.0-stable /tmp/privoxy_4.2.0.orig.tar.gz

# Tunnel SSH key is provided at runtime via VPS_SSH_KEY env var
# (written to /tmp/tunnel_key by the entrypoint — never baked into the image)
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh
# Out-of-band verified host key — never use ssh-keyscan at runtime
RUN printf '140.238.139.20 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB1FePPG7b/9e89XTFwtm9RxRiufeGCBKybqEzeo0+cC\n140.238.139.20 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQD0a/NfRiZgfQy6GLA6knSezltiZ8sFPMqRGtwNaGqJwgCKwlnaHzQsWLD1iLJftaQNTpg+44otgPWFqIfpx6pQMen67pJte+XDIFcru/5cD8RWUdh9VEhIgfTu/KWR8yjaHg+bnOSzn/vrbfFrG0avyMyyWiEWb6FkIgEfFluxiuZx3KoRWQXWnttsBPXPrbYTZ0ZgAfqHZ/L6pzya63o0jZHSQJ4OlI9SirCMDeH5qsGiLX0LarIy5AUpoG22oaINhZlMobvqg+JzXlWfr69BG/gV8nCQcRYojgKdLOY7vlo1C21aW79TM7xydYIHnidr2uWjwv2MYcc9hR6TX2G7z5ICS5D3JmdNh6TKnd/4kWHYEPDBR5OI38GN0/c3BMDas48oXVrEgSkoAplgd07yuD1xYi3s4BIvQN+ZMFlrJo8EdB800s8DOx/rjcoP0xlY12Luwem0ZTDCFLUuRmjrYbAYodSDm1g9ilgmE/CfD2SuHHhllCJfNEYe7akIDkU=\n' >> /root/.ssh/known_hosts

# ---------------------------------------------------------------------------
# Fail-fast: verify every toolchain and tunnel tool is runnable. Catches a
# broken install at build time. The Rust checks run as 'abc' (the runtime
# user) to prove the toolchain is usable by the actual user, not just root.
# ssh-keygen validates the pinned host keys are parseable.
# ---------------------------------------------------------------------------
RUN set -eux; \
	node --version; npm --version; yarn --version; pnpm --version; bun --version; \
	python3 --version; pip3 --version; uv --version; poetry --version; \
	go version; git --version; git-lfs --version; jq --version; \
	su abc -s /bin/bash -c 'rustc --version && cargo --version'; \
	ssh -V; \
	autossh -V; \
	ssh-keygen -l -f /root/.ssh/known_hosts >/dev/null; \
	/usr/sbin/privoxy --version; \
	echo "All toolchains OK"

EXPOSE 8443

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
