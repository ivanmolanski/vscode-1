#!/usr/bin/env bash
#
# config-persist.sh — guarantee that EVERYTHING the operator changes in the
# VS Code (code-server) client, the Kilo client, and the agent clients survives
# a Railway redeploy.
#
# Called from docker-entrypoint.sh BEFORE `exec code-server`, on every boot /
# Railway redeploy. IDEMPOTENT and NON-FATAL: any failure is logged and
# code-server still starts.
#
# WHY THIS EXISTS
#   The whole editor state already lives on the /config volume
#   (--user-data-dir /config/data, HOME=/config), so a plain restart keeps it.
#   The failure mode is a DEPLOY: a step that rewrites a managed config, a
#   schema-mismatch reset, or a fresh volume — which is the "I have to re-add
#   MCP servers / models / settings after every deploy" symptom. This script is
#   the healing + recovery layer:
#
#     * SNAPSHOT  — copy the operator-editable state to
#                   /config/.state-snapshots/<ts>/ (rotating, last 5) on every
#                   boot, so there is always a known-good copy on the volume.
#     * FILL      — restore any managed key that is MISSING (deleted, or a fresh
#                   volume) from the shipped baseline. By DEFAULT an existing
#                   live value is NEVER overwritten, so anything the operator
#                   changed persists exactly as changed. `--heal` opts in to
#                   restoring drifted values too.
#     * SEED      — create a managed file from the shipped baseline only when it
#                   is absent (fresh volume), then fill.
#     * RESTORE   — `--restore` rolls the whole managed set back from the newest
#                   snapshot (disaster recovery after a bad deploy).
#
#   VS Code's own state (settings.json, keybindings.json, snippets/, profiles/,
#   globalStorage/, History/, workspaceStorage/) is pure operator data on the
#   volume; this script SNAPSHOTS it but never rewrites it.
#
# MODEL
#   Identical to OpenClaw's write_full_gambit(): the on-disk config stays the
#   source of truth and this baseline is what it heals toward.
#
# SECRETS
#   No credential is hard-coded as the primary source. Values come from, in
#   order: (1) /config/.config-secrets.env on the volume, (2) the process
#   environment, (3) a non-rotating local default where one is safe (the local
#   Headroom loopback password). Only a fixed whitelist of ${TOKEN}s in the
#   seeds is substituted — VS Code's own ${input:...} / ${apiKey} refs are left
#   literal. A missing secret is a warning, never a crash.
#
# USAGE
#   bash config-persist.sh            # snapshot + seed + fill missing keys (default)
#   bash config-persist.sh --heal     # also restore keys whose value has drifted
#   bash config-persist.sh --status   # report managed-file state, change nothing
#   bash config-persist.sh --restore  # restore the managed set from the newest snapshot
set -u

LOG="/config/.config-persist.log"
mkdir -p /config
exec >>"$LOG" 2>&1
echo "=== config-persist $(date -u +%FT%TZ) ==="

MODE="apply"
[ "${1:-}" = "--status" ] && MODE="status"
[ "${1:-}" = "--restore" ] && MODE="restore"
[ "${1:-}" = "--heal" ] && MODE="heal"

VOL="/config"
VOL_DATA="/config/data"
SNAP_ROOT="$VOL/.state-snapshots"
SECRETS_FILE="$VOL/.config-secrets.env"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SEEDS_DIR="$SELF_DIR/config-seeds"
KEEP_SNAPSHOTS=5

# --- 1. Secrets (secrets-file wins, then env, then a safe local default) -----
if [ -f "$SECRETS_FILE" ]; then
	set -a
	# shellcheck source=/dev/null
	. "$SECRETS_FILE" 2>/dev/null || true
	set +a
fi
# The local Headroom gateway password is a fixed loopback value (not a rotating
# secret), so it is a safe default — mirrors the entrypoint's own fallback.
export HEADROOM_API_KEY="${HEADROOM_API_KEY:-headroom-kali-proxy-2026}"
# Every other credential must come from the secrets file or the environment.
for v in CONTEXT7_API_KEY BRAVE_API_KEY GITHUB_PERSONAL_ACCESS_TOKEN OPENROUTER_API_KEY; do
	eval "val=\${$v:-}"
	[ -n "$val" ] || echo "WARNING: $v not found (secrets file + env empty) — any on-disk value is kept"
done

# --- 2. Managed set ----------------------------------------------------------
# JSON/JSONC config files we READ + additive-merge (heal toward baseline).
# Newline-separated (no leading newline, so the first entry is never empty).
JSON_CONFIGS="$VOL_DATA/User/chatLanguageModels.json
$VOL_DATA/User/mcp.json
$VOL/.config/Code/User/mcp.json
$VOL/.cursor/mcp.json
$VOL/.config/kilo/kilo.jsonc"
# Operator state we SNAPSHOT (and restore on --restore) but never rewrite.
STATE_PATHS="$VOL_DATA/User/settings.json
$VOL_DATA/User/keybindings.json
$VOL_DATA/User/tasks.json
$VOL_DATA/User/snippets
$VOL_DATA/User/chatLanguageModels.json
$VOL_DATA/User/mcp.json
$VOL_DATA/User/globalStorage/state.vscdb
$VOL_DATA/Machine/settings.json
$VOL/.config/Code/User
$VOL/.cursor
$VOL/.config/kilo/kilo.jsonc
$VOL/.agents
$VOL/.claude"

snapshot() {
	local ts dest; ts="$(date -u +%Y%m%dT%H%M%SZ)"; dest="$SNAP_ROOT/$ts"
	mkdir -p "$dest"
	local p rel
	for p in $STATE_PATHS; do
		[ -e "$p" ] || continue
		rel="${p#"$VOL"/}"
		mkdir -p "$dest/$(dirname "$rel")"
		cp -a "$p" "$dest/$rel" 2>/dev/null || true
	done
	ln -sfn "$ts" "$SNAP_ROOT/latest"
	# Rotate: keep the newest N snapshots. Glob (no ls|grep), and guard the
	# removal target so a bad glob can never expand to "/".
	local old
	for old in $(find "$SNAP_ROOT" -maxdepth 1 -type d -name '[0-9]*T*Z' -printf '%f\n' 2>/dev/null | sort -r | tail -n +$((KEEP_SNAPSHOTS + 1))); do
		case "$old" in
		'' | */* | *..*) continue ;;
		esac
		[ -d "$SNAP_ROOT/$old" ] && rm -rf "${SNAP_ROOT:?}/$old"
	done
	echo "SNAPSHOT $dest"
}

restore() {
	local dir="$SNAP_ROOT/latest"
	[ -d "$dir" ] || dir="$(find "$SNAP_ROOT" -maxdepth 1 -type d -name '[0-9]*T*Z' 2>/dev/null | sort | tail -1)"
	if [ -z "${dir:-}" ] || [ ! -d "$dir" ]; then
		echo "restore: no snapshot found under $SNAP_ROOT — nothing to restore"
		return 0
	fi
	echo "restore: from $dir"
	( cd "$dir" && find . -mindepth 1 -maxdepth 1 -printf '%P\n' ) 2>/dev/null | while read -r top; do
		[ -n "$top" ] || continue
		# Fill in only what is absent (never clobber newer live edits); the JSON
		# config files are additionally healed by the normal apply pass.
		case "$top" in
		data | .config | .cursor | .agents | .claude)
			cp -an "$dir/$top/." "$VOL/$top/" 2>/dev/null || true ;;
		*)
			[ -e "$VOL/$top" ] || cp -a "$dir/$top" "$VOL/$top" 2>/dev/null || true ;;
		esac
	done
	echo "restore: done"
}

status_report() {
	local f
	for f in $JSON_CONFIGS; do
		if [ -f "$f" ]; then printf '%-48s %8s bytes\n' "$f" "$(wc -c <"$f" | tr -d ' ')"
		else printf '%-48s MISSING\n' "$f"; fi
	done
	local n; n="$(find "$SNAP_ROOT" -maxdepth 1 -type d -name '[0-9]*T*Z' 2>/dev/null | wc -l | tr -d ' ')"
	echo "snapshots: $n (latest -> $(readlink "$SNAP_ROOT/latest" 2>/dev/null || echo none))"
}

case "$MODE" in
status)  status_report; exit 0 ;;
restore) restore; exit 0 ;;
esac

mkdir -p "$VOL_DATA/User" "$VOL_DATA/Machine" "$VOL/.config/Code/User" "$VOL/.cursor" "$VOL/.config/kilo" "$SNAP_ROOT"

# --- 3. Snapshot BEFORE we touch anything ------------------------------------
snapshot

# --- 4. Seed + fill the JSON configs (additive deep-merge) --------------------
# PERSIST_MODE=fill (default) only adds keys that are MISSING, so operator edits
# always win. PERSIST_MODE=heal additionally restores drifted scalar values.
PERSIST_MODE="$MODE" SELF_SEEDS="$SEEDS_DIR" VOL="$VOL" VOL_DATA="$VOL_DATA" \
node - <<'NODE' || echo "WARNING: config seed/fill failed (non-fatal)"
"use strict";
const fs = require("fs");
const path = require("path");
const env = process.env;
const seeds = env.SELF_SEEDS;
const VOL = env.VOL;
const VOL_DATA = env.VOL_DATA;
const MODE = env.PERSIST_MODE || "apply";
const HEAL = MODE === "heal";

const managed = [
  ["chatLanguageModels.json", path.join(VOL_DATA, "User/chatLanguageModels.json")],
  ["vscode-mcp.json",         path.join(VOL_DATA, "User/mcp.json")],
  ["code-user-mcp.json",      path.join(VOL, ".config/Code/User/mcp.json")],
  ["cursor-mcp.json",         path.join(VOL, ".cursor/mcp.json")],
  ["kilo-global.json",        path.join(VOL, ".config/kilo/kilo.jsonc")],
];

// Only these tokens are substituted; VS Code's ${input:...}/${apiKey} stay literal.
const TOKENS = ["HEADROOM_API_KEY", "CONTEXT7_API_KEY", "BRAVE_API_KEY",
                "GITHUB_PERSONAL_ACCESS_TOKEN", "OPENROUTER_API_KEY"];

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// Additive merge. `undefined` = absent.
//   HEAL mode: drifted scalars are restored to the seed value.
//   fill mode: a key is written ONLY when it is missing (operator edits win).
function merge(dst, src, p, changed) {
  for (const k of Object.keys(src)) {
    const sv = src[k], dv = dst[k], np = p ? p + "." + k : k;
    if (isObj(sv) && isObj(dv)) {
      merge(dv, sv, np, changed);
    } else if (Array.isArray(sv) && Array.isArray(dv)
        && sv.length && dv.length
        && sv.every((it) => isObj(it) && it.id != null)
        && dv.every((it) => isObj(it) && it.id != null)) {
      const byId = new Map(), order = [];
      for (const it of dv) {
        if (isObj(it) && it.id != null) { byId.set(it.id, it); order.push(it.id); }
        else { const key = "__live__" + order.length; byId.set(key, it); order.push(key); }
      }
      for (const sit of sv) {
        const id = isObj(sit) && sit.id != null ? sit.id : null;
        if (id != null && byId.has(id)) merge(byId.get(id), sit, np + "[" + id + "]", changed);
        else if (id != null && !byId.has(id)) {
          // Missing entry -> always add it (fill or heal).
          byId.set(id, JSON.parse(JSON.stringify(sit))); order.push(id); changed.push(np + "[" + id + "]");
        }
      }
      const finalArr = order.map((key) => byId.get(key));
      if (JSON.stringify(finalArr) !== JSON.stringify(dv)) { dst[k] = finalArr; changed.push(np); }
    } else if (Array.isArray(sv)) {
      if (dv === undefined) { dst[k] = JSON.parse(JSON.stringify(sv)); changed.push(np); }
      else if (HEAL && JSON.stringify(dv) !== JSON.stringify(sv)) { dst[k] = JSON.parse(JSON.stringify(sv)); changed.push(np); }
    } else {
      if (dv === undefined) { dst[k] = sv; changed.push(np); }
      else if (HEAL && JSON.stringify(dv) !== JSON.stringify(sv)) { dst[k] = sv; changed.push(np); }
    }
  }
}

function substitute(node) {
  if (typeof node === "string") {
    return node.replace(/\$\{([A-Z0-9_]+)\}/g, (m, n) =>
      TOKENS.includes(n) ? (env[n] !== undefined ? env[n] : "") : m);
  }
  if (Array.isArray(node)) return node.map(substitute);
  if (isObj(node)) { const o = {}; for (const k of Object.keys(node)) o[k] = substitute(node[k]); return o; }
  return node;
}

function stripComments(text) {
  let out = "", inStr = false, esc = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i], n = text[i + 1];
    if (inStr) {
      out += c;
      if (esc) esc = false; else if (c === "\\") esc = true; else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') { inStr = true; out += c; continue; }
    if (c === "/" && n === "/") { while (i < text.length && text[i] !== "\n") i++; out += "\n"; continue; }
    if (c === "/" && n === "*") { i += 2; while (i < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++; i++; continue; }
    out += c;
  }
  return out;
}
const readAny = (p, jsonc) => jsonc
  ? JSON.parse(stripComments(fs.readFileSync(p, "utf8")))
  : JSON.parse(fs.readFileSync(p, "utf8"));

function atomicWrite(p, data) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const tmp = path.join(path.dirname(p), "." + path.basename(p) + ".tmp-" + process.pid);
  fs.writeFileSync(tmp, data, { mode: 0o600 });
  fs.renameSync(tmp, p);
}

for (const [seedName, dest] of managed) {
  const seedPath = path.join(seeds, seedName);
  if (!fs.existsSync(seedPath)) { console.log("seed missing: " + seedName + " (skipped)"); continue; }
  const jsonc = dest.endsWith(".jsonc");
  const seed = substitute(JSON.parse(fs.readFileSync(seedPath, "utf8")));
  if (!fs.existsSync(dest)) {
    atomicWrite(dest, JSON.stringify(seed, null, 2) + "\n");
    console.log("CREATED  " + dest);
    continue;
  }
  let live;
  try { live = readAny(dest, jsonc); }
  catch (e) { console.log("SKIP     " + dest + " (unparseable: " + e.message + ")"); continue; }
  const changed = [];
  merge(live, seed, "", changed);
  if (changed.length) {
    atomicWrite(dest, JSON.stringify(live, null, 2) + "\n");
    console.log((HEAL ? "HEALED   " : "FILLED   ") + dest + " (" + changed.length + " key(s): " + changed.slice(0, 8).join(", ") + ")");
  } else {
    console.log("OK       " + dest);
  }
}
NODE

# --- 5. Skills: create the dirs, restore any image-bundled skill that is gone.
for d in "$VOL/.agents/skills" "$VOL/.claude/skills" "$VOL/.agents" "$VOL/.claude"; do mkdir -p "$d"; done
if [ -d "$SEEDS_DIR/skills" ]; then
	for src in "$SEEDS_DIR/skills"/*; do
		[ -e "$src" ] || continue
		name="$(basename "$src")"
		if [ ! -e "$VOL/.agents/skills/$name" ]; then
			cp -a "$src" "$VOL/.agents/skills/$name" 2>/dev/null && echo "restored skill: $name"
		fi
		[ -e "$VOL/.claude/skills/$name" ] || cp -a "$src" "$VOL/.claude/skills/$name" 2>/dev/null || true
	done
fi

chown -R abc:abc "$VOL/.agents" "$VOL/.claude" "$VOL/.config/kilo" "$VOL/.cursor" 2>/dev/null || true
chown abc:abc "$VOL_DATA/User/chatLanguageModels.json" "$VOL_DATA/User/mcp.json" 2>/dev/null || true

echo "=== config-persist done $(date -u +%FT%TZ) ==="
