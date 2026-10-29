#!/usr/bin/env node
'use strict';
// pid-governor: keeps the container under its process/thread limit.
//
// Railway caps the container's pids cgroup (pids.max=1000 per the Dockerfile
// note). Stdio MCP servers started by the editor are the processes that pile
// up: they are orphaned when their client goes away, or left dormant while
// attached. Every PID_GOVERNOR_INTERVAL seconds this reads /proc and reaps
// only processes whose command line matches the MCP allowlist below.
// Editor, daemon (headroom, autossh, privoxy, socat) and shell processes are
// never matched, whatever their parent.
//
// Rules, each run once per tick:
//  1. Orphans: an MCP root whose parent is PID 1 for MCP_ORPHAN_GRACE seconds
//     is reaped. Nothing is attached to it any more.
//  2. Duplicates: more than MAX_PER_SERVER live roots of one server class are
//     reaped, least recently active first, once idle for PID_EVICT_IDLE seconds.
//  3. Pressure: at PID_HIGH_PCT of the limit, attached MCP roots idle for
//     PID_EVICT_IDLE seconds are reaped, longest idle first, until usage falls
//     below PID_TARGET_PCT. Below PID_HIGH_PCT an attached idle server is left
//     alone, because its client may still hold the stdio pipe.
//
// Activity is measured on the subtree: a root is active while any process it
// spawned (npx -> node, ssh -> docker dial-stdio) consumes CPU.
// Kill: SIGTERM to the subtree, wait PID_KILL_GRACE seconds, SIGKILL survivors.
// The MCP spec's first step (closing the server's stdin) is not possible from
// outside the process, so SIGTERM is the first signal. Each signal rechecks
// the process starttime in /proc/<pid>/stat so a reused PID is never signalled.

const fs = require('fs');

function num(name, def) {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === '') return def;
  const v = Number(raw);
  return Number.isFinite(v) ? v : def;
}

const CFG = {
  intervalMs: num('PID_GOVERNOR_INTERVAL', 15) * 1000,
  highPct: num('PID_HIGH_PCT', 75),
  targetPct: num('PID_TARGET_PCT', 60),
  orphanGraceMs: num('MCP_ORPHAN_GRACE', 60) * 1000,
  evictIdleMs: num('PID_EVICT_IDLE', 120) * 1000,
  maxPerServer: num('MCP_MAX_PER_SERVER', 3),
  killGraceMs: num('PID_KILL_GRACE', 5) * 1000,
  limitOverride: num('PID_LIMIT', 0),
  dryRun: process.env.PID_GOVERNOR_DRY_RUN === '1',
  logPath: process.env.PID_GOVERNOR_LOG || '/config/.pid-governor.log',
};
const LOG_MAX_BYTES = 1024 * 1024;
const SELF = process.pid;

// Reapable server classes. Matched against the space-joined command line.
const CLASSES = [
  ['context7', /@upstash\/context7-mcp/],
  ['mcp-server', /@modelcontextprotocol\/server-/],
  ['github-mcp', /github-mcp-server/],
  ['brave-search-docker', /mcp\/brave-search/],
  ['railway-mcp', /railway mcp proxy/],
  ['docker-stdio', /docker run -i --rm/],
  ['docker-dial-stdio', /docker system dial-stdio/],
];

function classify(cmd) {
  for (const [name, re] of CLASSES) if (re.test(cmd)) return name;
  return null;
}

// A shell wrapper (bash -c "...") can carry an MCP package name in its
// arguments without being an MCP server. Its MCP child is still a root because
// the child's parent is not in the same class, so skipping the shell loses nothing.
function isShellCmd(cmd) {
  // `/proc/<pid>/cmdline` uses NUL separators; allow both whitespace and NUL.
  const argv0 = String(cmd).trim().split(/[\s\0]+/, 1)[0] || '';
  // Login shells commonly prefix argv0 with `-` (e.g. `-bash`).
  return /(^|\/)-?(bash|sh|dash|zsh|ash)$/.test(argv0);
}

function readText(p) {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch (e) {
    return null;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function log(msg) {
  const line = `${new Date().toISOString()} ${msg}\n`;
  try {
    const st = fs.statSync(CFG.logPath, { throwIfNoEntry: false });
    if (st && st.size > LOG_MAX_BYTES) fs.renameSync(CFG.logPath, `${CFG.logPath}.1`);
    fs.appendFileSync(CFG.logPath, line);
  } catch (e) {
    process.stderr.write(line);
  }
}

// /proc/<pid>/stat fields after the comm field, which is wrapped in parens and
// may contain spaces: index 0 is state (field 3), 1 ppid (4), 11 utime (14),
// 12 stime (15), 19 starttime (22).
function parseStat(text) {
  return text.slice(text.lastIndexOf(')') + 2).split(' ');
}

function readProcs() {
  const procs = new Map();
  let entries = [];
  try {
    entries = fs.readdirSync('/proc');
  } catch (e) {
    return procs;
  }
  for (const name of entries) {
    if (!/^\d+$/.test(name)) continue;
    const pid = Number(name);
    const stat = readText(`/proc/${pid}/stat`);
    if (stat === null) continue;
    const f = parseStat(stat);
    const state = f[0];
    let tasks = 0;
    try {
      tasks = fs.readdirSync(`/proc/${pid}/task`).length;
    } catch (e) {
      // exited while scanning
    }
    const cmd = state === 'Z' ? '' : (readText(`/proc/${pid}/cmdline`) || '').replace(/\0/g, ' ').trim();
    procs.set(pid, {
      pid,
      state,
      ppid: Number(f[1]),
      ticks: Number(f[11]) + Number(f[12]),
      start: f[19],
      tasks,
      cmd,
      cls: state === 'Z' || isShellCmd(cmd) ? null : classify(cmd),
      active: 0,
      orphanSince: null,
    });
  }
  return procs;
}

// Last-seen state per process, keyed by pid and starttime so a reused PID is a
// new process.
const seen = new Map();

function track(snap, now) {
  const next = new Map();
  for (const p of snap.procs.values()) {
    const key = `${p.pid}:${p.start}`;
    const prev = seen.get(key);
    let active = prev ? prev.active : now;
    if (prev && prev.ticks !== p.ticks) active = now;
    let orphanSince = null;
    if (p.cls && p.ppid === 1) orphanSince = prev && prev.orphanSince !== null ? prev.orphanSince : now;
    next.set(key, { ticks: p.ticks, active, orphanSince });
    p.active = active;
    p.orphanSince = orphanSince;
  }
  seen.clear();
  for (const [k, v] of next) seen.set(k, v);
}

function scan() {
  const now = Date.now();
  const procs = readProcs();
  const children = new Map();
  let total = 0;
  for (const p of procs.values()) {
    total += p.tasks;
    if (!children.has(p.ppid)) children.set(p.ppid, []);
    children.get(p.ppid).push(p.pid);
  }
  const snap = { procs, children, total };
  track(snap, now);
  return snap;
}

function subtree(snap, pid) {
  const out = [];
  const stack = [pid];
  const visited = new Set();
  while (stack.length) {
    const q = stack.pop();
    if (visited.has(q)) continue;
    visited.add(q);
    const p = snap.procs.get(q);
    if (p) out.push(p);
    for (const c of snap.children.get(q) || []) stack.push(c);
  }
  return out;
}

function lastActive(snap, root) {
  return Math.max(...subtree(snap, root.pid).map((p) => p.active));
}

// PIDs that must never be signalled: PID 1, the governor, and its ancestors
// (entrypoint shell, tini, container runtime shim).
function protectedSet(snap) {
  const set = new Set([1, SELF]);
  let cur = snap.procs.get(SELF);
  while (cur && !set.has(cur.ppid)) {
    set.add(cur.ppid);
    cur = snap.procs.get(cur.ppid);
  }
  return set;
}

// Roots: MCP processes whose parent is not in the same class. Each root stands
// for one server instance, and its subtree is the instance.
function roots(snap) {
  const out = [];
  for (const p of snap.procs.values()) {
    if (!p.cls) continue;
    const parent = snap.procs.get(p.ppid);
    if (parent && parent.cls === p.cls) continue;
    out.push(p);
  }
  return out;
}

function alwaysPlan(snap, now) {
  const prot = protectedSet(snap);
  const rs = roots(snap).filter((r) => !prot.has(r.pid));
  const out = [];
  for (const r of rs) {
    if (r.orphanSince !== null && now - r.orphanSince >= CFG.orphanGraceMs) {
      out.push({ root: r, why: 'orphan' });
    }
  }
  const byClass = new Map();
  for (const r of rs) {
    if (r.orphanSince !== null) continue;
    if (!byClass.has(r.cls)) byClass.set(r.cls, []);
    byClass.get(r.cls).push(r);
  }
  for (const [cls, list] of byClass) {
    if (list.length <= CFG.maxPerServer) continue;
    // lastActive walks the subtree; cache it once per root instead of inside sort.
    const withLast = list
      .map((r) => ({ root: r, last: lastActive(snap, r) }))
      .sort((a, b) => b.last - a.last);
    for (const x of withLast.slice(CFG.maxPerServer)) {
      if (now - x.last >= CFG.evictIdleMs) {
        out.push({ root: x.root, why: `duplicate ${cls} beyond ${CFG.maxPerServer}` });
      }
    }
  }
  return out;
}

function pressureCandidates(snap, now) {
  const prot = protectedSet(snap);
  return roots(snap)
    .filter((r) => !prot.has(r.pid) && r.orphanSince === null)
    .map((r) => ({ root: r, last: lastActive(snap, r) }))
    .filter((x) => now - x.last >= CFG.evictIdleMs)
    .sort((a, b) => a.last - b.last);
}

function readCurrent(snap) {
  for (const f of ['/sys/fs/cgroup/pids.current', '/sys/fs/cgroup/pids/pids.current']) {
    const v = readText(f);
    if (v !== null && /^\d+$/.test(v.trim())) return { n: Number(v.trim()), src: 'cgroup' };
  }
  return { n: snap.total, src: 'counted' };
}

// Returns { n: null } when no finite limit is visible (cgroup pids.max and
// RLIMIT_NPROC both unlimited). The pressure rule is then off; orphan and
// duplicate reaping still run. PID_LIMIT sets an explicit limit.
function readLimit() {
  if (CFG.limitOverride > 0) return { n: CFG.limitOverride, src: 'PID_LIMIT' };
  for (const f of ['/sys/fs/cgroup/pids.max', '/sys/fs/cgroup/pids/pids.max']) {
    const v = (readText(f) || '').trim();
    if (/^\d+$/.test(v) && Number(v) > 0) return { n: Number(v), src: f };
  }
  const limits = readText('/proc/self/limits') || '';
  const m = limits.match(/^Max processes\s+(\S+)/m);
  if (m && /^\d+$/.test(m[1])) return { n: Number(m[1]), src: 'RLIMIT_NPROC' };
  return { n: null, src: 'none' };
}

function alive(p) {
  const s = readText(`/proc/${p.pid}/stat`);
  if (s === null) return false;
  const f = parseStat(s);
  return f[19] === p.start && f[0] !== 'Z';
}

function signal(p, sig) {
  if (!alive(p)) return;
  try {
    process.kill(p.pid, sig);
  } catch (e) {
    // EPERM or already gone
  }
}

// Reap the MCP instance rooted at `root`. Returns false if the root is no
// longer the same process in `snap`.
async function reap(snap, root, why) {
  const cur = snap.procs.get(root.pid);
  if (!cur || cur.start !== root.start) return false;
  const prot = protectedSet(snap);
  const targets = subtree(snap, root.pid).filter((p) => !prot.has(p.pid) && p.state !== 'Z');
  const label = `${root.cls} pid=${root.pid} members=${targets.length} why=${why} cmd=${root.cmd.slice(0, 160)}`;
  if (CFG.dryRun) {
    log(`dry-run reap ${label}`);
    return true;
  }
  log(`reap ${label}`);
  for (const p of targets) signal(p, 'SIGTERM');
  await sleep(CFG.killGraceMs);
  const survivors = targets.filter((p) => alive(p));
  for (const p of survivors) signal(p, 'SIGKILL');
  if (survivors.length) log(`sigkill ${survivors.length} survivor(s) of pid=${root.pid}`);
  return true;
}

let inPressure = false;
let stuck = false;
let noLimitLogged = false;

async function tick() {
  let snap = scan();
  const now = Date.now();
  const limit = readLimit();

  for (const item of alwaysPlan(snap, now)) {
    await reap(snap, item.root, item.why);
  }
  snap = scan();

  if (limit.n === null) {
    if (!noLimitLogged) {
      noLimitLogged = true;
      log(`pressure rule off: no finite pids limit is visible (source: ${limit.src}; may be unavailable or unlimited); set PID_LIMIT to enable it`);
    }
    // Pressure rule is disabled, so ensure prior pressure state does not remain latched.
    inPressure = false;
    stuck = false;
    return;
  }

  // A finite limit is visible again; allow "pressure rule off" log to re-emit on future transitions.
  noLimitLogged = false;

  let cur = readCurrent(snap);
  let pct = (cur.n / limit.n) * 100;
  if (pct < CFG.highPct) {
    if (inPressure) log(`pressure ended pids=${cur.n}/${limit.n} at ${pct.toFixed(1)}%`);
    inPressure = false;
    stuck = false;
    return;
  }
  if (!inPressure) {
    inPressure = true;
    log(`pressure pids=${cur.n}/${limit.n} (${cur.src}, limit ${limit.src}) at ${pct.toFixed(1)}%`);
  }
  for (const c of pressureCandidates(snap, Date.now())) {
    if (pct < CFG.targetPct) break;
    await reap(snap, c.root, 'pressure');
    snap = scan();
    cur = readCurrent(snap);
    pct = (cur.n / limit.n) * 100;
  }
  if (pct < CFG.targetPct) {
    stuck = false;
    return;
  }
  if (!stuck) {
    stuck = true;
    log(`pressure not relieved pids=${cur.n}/${limit.n} at ${pct.toFixed(1)}%: no idle MCP process left to reap`);
  }
}

async function main() {
  const limit = readLimit();
  log(
    `start interval=${CFG.intervalMs / 1000}s high=${CFG.highPct}% target=${CFG.targetPct}% ` +
      `orphan_grace=${CFG.orphanGraceMs / 1000}s evict_idle=${CFG.evictIdleMs / 1000}s ` +
      `max_per_server=${CFG.maxPerServer} kill_grace=${CFG.killGraceMs / 1000}s ` +
      `dry_run=${CFG.dryRun} limit=${limit.n ?? 'none'} (${limit.src})`,
  );
  for (;;) {
    try {
      await tick();
    } catch (e) {
      log(`error ${e && e.stack ? e.stack : e}`);
    }
    await sleep(CFG.intervalMs);
  }
}

main();
