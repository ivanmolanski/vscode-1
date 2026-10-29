/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const filename = path.join(__dirname, 'pid-governor.cjs');
// main() only runs for the entry point, so loading the source here is inert.
const source = fs.readFileSync(filename, 'utf8');

// Evaluates the script with Node's CommonJS wrapper semantics. `require` delegates
// to the real one, except `fs` members listed in `fsOverrides`.
function load(pid = 99999, fsOverrides = {}) {
	const delegatingRequire = Object.assign(id => {
		const mod = require(id);
		return id === 'fs' || id === 'node:fs' ? { ...mod, ...fsOverrides } : mod;
	}, { main: undefined });
	const module = { exports: {} };
	const context = vm.createContext({
		module, exports: module.exports, require: delegatingRequire,
		__filename: filename, __dirname: path.dirname(filename),
		process: { env: {}, pid },
	});
	vm.runInContext(source, context, { filename });
	return context;
}

const governor = load();

function snapshot(entries) {
	const procs = new Map(entries.map(([pid, ppid, cmd]) => [pid, {
		pid, ppid, cmd,
		cls: governor.isShellCmd(cmd) ? null : governor.classify(cmd),
		start: '1',
		ticks: 0,
		active: 0,
		orphanSince: null,
	}]));
	const children = new Map();
	for (const p of procs.values()) {
		if (!children.has(p.ppid)) children.set(p.ppid, []);
		children.get(p.ppid).push(p.pid);
	}
	return { procs, children };
}

function rootPids(snap) {
	return Array.from(governor.roots(snap), p => p.pid);
}

test('same-class descendants collapse across one or more shell wrappers', () => {
	for (const wrappers of [[], ['sh -c context7-mcp'], ['/bin/bash -lc context7-mcp', '/bin/sh -c context7-mcp']]) {
		const entries = [[10, 1, 'npm exec @upstash/context7-mcp']];
		for (const cmd of wrappers) entries.push([entries.at(-1)[0] + 1, entries.at(-1)[0], cmd]);
		entries.push([20, entries.at(-1)[0], 'node @upstash/context7-mcp']);
		assert.deepEqual(rootPids(snapshot(entries)), [10]);
	}
});

test('other process boundaries and server classes keep their roots', () => {
	for (const boundary of ['node worker.js', '/bin/bash', 'node github-mcp-server']) {
		const snap = snapshot([
			[10, 1, 'npm exec @upstash/context7-mcp'],
			[11, 10, boundary],
			[12, 11, 'sh -c context7-mcp'],
			[20, 12, 'node @upstash/context7-mcp'],
		]);
		assert.deepEqual(rootPids(snap), boundary.includes('github-mcp-server') ? [10, 11, 20] : [10, 20]);
	}
});

test('standalone servers remain roots through missing parents and shell cycles', () => {
	for (const wrappers of [
		[[11, 404, 'sh -c context7-mcp']],
		[[11, 12, 'sh -c context7-mcp'], [12, 11, 'bash -lc context7-mcp']],
	]) {
		assert.deepEqual(rootPids(snapshot([...wrappers, [20, 11, 'node @upstash/context7-mcp']])), [20]);
	}
});

test('orphan grace applies through unclassified shell wrappers without classifying them', () => {
	for (const wrappers of [[], ['sh -c @upstash/context7-mcp'], ['/bin/bash -lc @upstash/context7-mcp', '/bin/sh -c @upstash/context7-mcp']]) {
		governor.track(snapshot([]), 0);
		const entries = [[1, 0, 'init']];
		for (const cmd of wrappers) {
			entries.push([10 + entries.length, entries.at(-1)[0], cmd]);
		}
		entries.push([20, entries.at(-1)[0], 'node @upstash/context7-mcp']);
		const snap = snapshot(entries);
		// Exercise both cached shell flags and the command-line fallback.
		if (wrappers.length === 2) {
			for (const p of snap.procs.values()) {
				p.shell = governor.isShellCmd(p.cmd);
			}
		}
		governor.track(snap, 1000);
		governor.track(snap, 60999);
		assert.deepEqual(Array.from(snap.procs.values(), p => [p.pid, p.cls, p.orphanSince]), [
			[1, null, null],
			...entries.slice(1, -1).map(([pid]) => [pid, null, null]),
			[20, 'context7', 1000],
		]);
		assert.deepEqual(Array.from(governor.alwaysPlan(snap, 60999)), []);
		governor.track(snap, 61000);
		assert.deepEqual(Array.from(governor.alwaysPlan(snap, 61000), item => [item.root.pid, item.why]), [[20, 'orphan']]);
	}
});

test('orphan ancestry stops at missing, classified, non-shell and visited parents', () => {
	for (const parents of [
		[],
		[[11, 404, 'sh -c @upstash/context7-mcp']],
		[[11, 1, 'node @upstash/context7-mcp']],
		[[11, 1, 'node github-mcp-server']],
		[[11, 1, 'node worker.js']],
		[[11, 1, 'bash script.sh']],
		[[11, 1, 'bash']],
		[[11, 12, 'sh -c x'], [12, 11, 'bash -lc x']],
		[[11, 11, 'sh -c x']],
		[[11, 20, 'sh -c x']],
	]) {
		governor.track(snapshot([]), 0);
		const snap = snapshot([...parents, [19, 11, 'sh -c x'], [20, 19, 'node @upstash/context7-mcp']]);
		governor.track(snap, 1000);
		assert.equal(snap.procs.get(20).orphanSince, null);
	}
});

test('orphan timing resets on attachment and PID reuse', () => {
	governor.track(snapshot([]), 0);
	const snap = snapshot([[11, 1, 'sh -c x'], [20, 11, 'node @upstash/context7-mcp']]);
	const server = snap.procs.get(20);
	const wrapper = snap.procs.get(11);
	const observed = [];
	for (const [now, ppid, start] of [[1000, 1, '1'], [2000, 1, '1'], [3000, 404, '1'], [4000, 1, '1'], [5000, 1, '2']]) {
		wrapper.ppid = ppid;
		server.start = start;
		governor.track(snap, now);
		observed.push(server.orphanSince);
	}
	assert.deepEqual(observed, [1000, 1000, null, 4000, 5000]);
});

test('duplicate and pressure plans count each wrapped instance once and track child activity', () => {
	const entries = [];
	for (const pid of [10, 20, 30]) {
		entries.push([pid, 1, 'npm exec @upstash/context7-mcp']);
		entries.push([pid + 1, pid, 'sh -c context7-mcp']);
		entries.push([pid + 2, pid + 1, 'node @upstash/context7-mcp']);
	}
	const snap = snapshot(entries);
	const now = 1000000;
	snap.procs.get(12).active = now;
	assert.deepEqual({
		duplicates: Array.from(governor.alwaysPlan(snap, now), item => item.root.pid),
		pressure: Array.from(governor.pressureCandidates(snap, now), item => item.root.pid),
	}, { duplicates: [], pressure: [20, 30] });
});

test('isShellCmd recognizes -c wrapper forms and rejects other shell uses', () => {
	const wrappers = ['bash -c x', 'bash -uc x', 'bash -euxc x', 'bash -e -c x', 'bash -l -c x', '-bash -c x',
		'bash --noprofile --norc -c x', 'bash --noprofile -lc x', 'bash -o pipefail -c x', 'bash -O extglob -c x',
		'/bin/ash -c x', 'bash\0-c\0a b c\0', 'bash\0-e\0-c\0\0'];
	const others = ['bash', 'bash script.sh', 'bash -- -c x', 'bash -l', 'bash +c x', 'node -c x', 'bash -o -c'];
	assert.deepEqual(wrappers.filter(c => !governor.isShellCmd(c)), []);
	assert.deepEqual(others.filter(c => governor.isShellCmd(c)), []);
});

test('toArgv keeps empty argv elements and drops only the trailing terminator', () => {
	assert.deepEqual(Array.from(governor.toArgv('bash\0\0-c\0x\0')), ['bash', '', '-c', 'x']);
});

test('readLimit reports no finite limit for unlimited or zero values', () => {
	const ctx = load(1, { readFileSync: p => p.endsWith('pids.max') ? 'max\n' : 'Max processes unlimited unlimited processes\n' });
	assert.equal(ctx.readLimit().n, null);
	const zero = load(1, { readFileSync: p => p.endsWith('pids.max') ? '0\n' : 'Max processes 0 0 processes\n' });
	assert.equal(zero.readLimit().n, null);
});

test('tick resets pressure state and rate-limits no-limit logs across limit transitions', async () => {
	const isolated = load();
	const limits = [
		{ n: 100, src: 'test' },
		{ n: null, src: 'none' },
		{ n: null, src: 'none' },
		{ n: 100, src: 'test' },
		{ n: null, src: 'none' },
	];
	const logs = [];
	isolated.scan = () => ({ procs: new Map(), total: 80 });
	isolated.alwaysPlan = () => [];
	isolated.readLimit = () => limits.shift();
	isolated.readCurrent = () => ({ n: 80, src: 'test' });
	isolated.pressureCandidates = () => [];
	isolated.log = message => logs.push(message);

	for (let i = 0; i < 5; i++) {
		await isolated.tick();
	}

	assert.deepEqual({
		noLimitLogs: logs.filter(message => message.startsWith('pressure rule off')).length,
		pressureStarts: logs.filter(message => message.startsWith('pressure pids=')).length,
		stuckLogs: logs.filter(message => message.startsWith('pressure not relieved')).length,
	}, { noLimitLogs: 2, pressureStarts: 2, stuckLogs: 2 });
});
