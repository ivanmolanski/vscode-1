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
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

# Node.js current (from Nodesource) — installs node + npm
RUN curl -fsSL https://deb.nodesource.com/setup_current.x | bash - && \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs && \
	apt-get clean && \
	rm -rf /var/lib/apt/lists/*

# npm global installs must not touch the mounted volume (/config is a Railway
# volume at runtime; npm resolves the prefix from CWD, so pin cache+prefix to
# /usr/local).
ENV NPM_CONFIG_PREFIX=/usr/local \
	NPM_CONFIG_CACHE=/usr/local/.npm-cache

# Corepack, yarn, pnpm — npm 11+ blocks install scripts by default, so opt
# corepack in via `--allow-scripts=corepack` (equals syntax! a bare
# `--allow-scripts <pkg>` consumes <pkg> as the flag value, leaving npm with
# no install target → ENOENT <cwd>/package.json).
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

# Rust (minimal profile). Pin RUSTUP_HOME/CARGO_HOME to /tmp-free shared paths
# and HOME=/root so the install location is deterministic (the base image may
# otherwise leave $HOME pointing somewhere unexpected). The toolchain lives
# under /root, which the runtime user 'abc' cannot traverse, so chmod the
# homes world-executable and symlink the binaries into /usr/local/bin.
ENV RUSTUP_HOME=/root/.rustup \
	CARGO_HOME=/root/.cargo \
	HOME=/root
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-host x86_64-unknown-linux-gnu --profile minimal && \
	chmod -R a+rX /root/.cargo /root/.rustup && \
	ln -sf /root/.cargo/bin/rustc /usr/local/bin/rustc && \
	ln -sf /root/.cargo/bin/cargo /usr/local/bin/cargo && \
	ln -sf /root/.cargo/bin/rustfmt /usr/local/bin/rustfmt && \
	ln -sf /root/.cargo/bin/clippy-driver /usr/local/bin/clippy-driver

# ---------------------------------------------------------------------------
# Git defaults + SSH dirs for github integration
# ---------------------------------------------------------------------------
RUN git config --global init.defaultBranch main && \
	git config --global pull.rebase false && \
	git lfs install --system && \
	mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
	mkdir -p /home/abc/.ssh && chmod 700 /home/abc/.ssh && \
	chown -R abc:abc /home/abc/.ssh

# ---------------------------------------------------------------------------
# Entrypoint + helper. The image has NO original docker-entrypoint.sh (its
# usr/local/bin only ships install-extension), so this COPY is additive.
# Persistence: the image's own s6 init creates /config/{extensions,data,
# workspace,.ssh} and chowns them to abc — attach the Railway volume at /config.
# ---------------------------------------------------------------------------
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=755 clone-repo.sh /usr/local/bin/clone-repo.sh

# Fail-fast: verify every toolchain from the image is runnable. This catches a
# broken install at build time instead of when a user tries to run it.
RUN set -eux; \
	node --version; npm --version; yarn --version; pnpm --version; bun --version; \
	python3 --version; pip3 --version; uv --version; poetry --version; \
	go version; rustc --version; cargo --version; \
	git --version; git-lfs --version; jq --version; \
	echo "All toolchains OK"

EXPOSE 8443

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
