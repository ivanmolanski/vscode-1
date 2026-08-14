# VS Code (code-server) on Railway

Deploy [code-server](https://coder.com/) — VS Code in the browser — on
[Railway](https://railway.com) with **full persistence** and all the common
dev toolchains baked in (node, npm, yarn, pnpm, bun, python3, pip, uv, poetry,
hatch, go, rust/cargo, git-lfs, jq, htop, nano, vim ...).

## Why this exists

The previous attempt failed to build. Three distinct bugs were found and fixed,
each validated against the official tool docs:

1. **npm 11+ blocks install scripts by default.** The old Dockerfile ran
   `npm install -g bun`; npm never ran bun's `postinstall` (which builds the
   binary), leaving `chmod` on a dangling symlink → build failure. Fix: keep
   corepack/yarn/pnpm on npm with the `--allow-scripts=<pkg>` **equals syntax**
   (a bare `--allow-scripts <pkg>` makes npm consume `<pkg>` as the flag value
   and fail with `ENOENT <cwd>/package.json`).
2. **uv wasn't on PATH.** pipx installs to `~/.local/bin`, which a fresh
   non-interactive `RUN` shell doesn't put on PATH. Fix: install uv via its
   official standalone installer into `/usr/local/bin`; put poetry/hatch
   (pipx-managed) wrappers on the shared PATH too.
3. **Runtime user `abc` can't traverse `/root`.** The image drops privileges to
   user `abc` (UID 1000) via s6. Any toolchain symlink pointing INTO `/root`
   (rustup/cargo at `/root/.cargo`, bun at `/root/.bun`) would fail with
   permission denied at runtime. Fix: install shared tools under `/opt` and
   `/usr/local`, and `chmod -R a+rX` the rest.

A **fail-fast verification step** at the end of the `Dockerfile` runs every
tool's `--version` during the build, so a broken install fails the build
instead of surfacing later inside the running container.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Image with all toolchains + corrected npm installs |
| `docker-entrypoint.sh` | Bridges Railway UID/GID conventions to the image's s6 init |
| `clone-repo.sh` | Helper: clone/pull a repo into the persistent workspace |
| `railway.json` | Nixpacks/Railpack builder config override (port 8443) |

## Railway setup (once)

1. **Project** — create `code-server` (already exists).
2. **Service** — `code-server` (already exists; the current service has no source
   connected, which is why every deployment fails).
3. **Connect source**: in the service, set *Deploy from Local / CLI*, or run:
   ```bash
   railway link -s code-server
   railway up            # uploads ./ (this folder only)
   ```
4. **Volume (persistence)** — create a volume mounted at **`/config`**
   (this is where code-server keeps settings, the workspace, extensions and
   ssh keys). Size per your plan (Free: 0.5GB, Hobby: 5GB).
5. **Variables** — set at least:
   - `PASSWORD` — web GUI login (or `HASHED_PASSWORD`)
   - `SUDO_PASSWORD` — sudo in the integrated terminal
   - `DEFAULT_WORKSPACE=/config/workspace`
   - `TZ=Etc/UTC`
6. **Domain** — add `code-server.up.railway.app` or a custom domain → generates
   an HTTPS URL for the GUI.

## VPN exit-node egress (AirVPN via Oracle)

The `code-server` service egresses through the `tailscale-vpn` sibling service's
userspace SOCKS5/HTTP proxy, which routes through a Tailscale exit node (the
Oracle VPS AirVPN gateway). This is wired via Railway **reference variables**
that resolve the sibling service's private domain dynamically:

| Variable | Value |
|----------|-------|
| `ALL_PROXY` | `socks5h://${{tailscale-vpn.RAILWAY_PRIVATE_DOMAIN}}:1055` |
| `HTTP_PROXY` | `http://${{tailscale-vpn.RAILWAY_PRIVATE_DOMAIN}}:1055` |
| `HTTPS_PROXY` | `http://${{tailscale-vpn.RAILWAY_PRIVATE_DOMAIN}}:1055` |

```bash
railway variable set \
  'ALL_PROXY=socks5h://${{tailscale-vpn.RAILWAY_PRIVATE_DOMAIN}}:1055' \
  'HTTP_PROXY=http://${{tailscale-vpn.RAILWAY_PRIVATE_DOMAIN}}:1055' \
  'HTTPS_PROXY=http://${{tailscale-vpn.RAILWAY_PRIVATE_DOMAIN}}:1055' \
  --service code-server
```

Verify egress exits through AirVPN (returns the AirVPN public IP, not Railway's):

```bash
railway ssh --service code-server "curl -4 http://api.ipify.org"
```

## After deploy

1. Open the generated `*.up.railway.app` URL, sign in with `PASSWORD`.
2. Everything you do — `/config/workspace` files, installed extensions,
   `~/.local/share/code-server` state, ssh keys — persists on the volume.
3. For GitHub auth, drop your ssh key into `/config/.ssh` in the terminal:
   ```bash
   git config --global user.name "you"
   git config --global user.email "you@example.com"
   ```
