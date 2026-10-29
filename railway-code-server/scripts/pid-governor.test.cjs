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
// Load the functions without starting the governor or signalling real processes.
const source = fs.readFileSync(filename, 'utf8').replace(/\nmain\(\);\s*$/, '\n');
const governor = vm.createContext({ require, process: { env: {}, pid: 99999 } });
vm.runInContext(source, governor, { filename });

function snapshot(entries) {
	const procs = new Map(entries.map(([pid, ppid, cmd]) => [pid, {
		pid, ppid, cmd,
		cls: governor.isShellCmd(cmd) ? null : governor.classify(cmd),
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
	const ctx = vm.createContext({ require: () => ({ readFileSync: p => p.endsWith('pids.max') ? 'max\n' : 'Max processes unlimited unlimited processes\n' }), process: { env: {}, pid: 1 } });
	vm.runInContext(source, ctx, { filename });
	assert.equal(ctx.readLimit().n, null);
	const zero = vm.createContext({ require: () => ({ readFileSync: p => p.endsWith('pids.max') ? '0\n' : 'Max processes 0 0 processes\n' }), process: { env: {}, pid: 1 } });
	vm.runInContext(source, zero, { filename });
	assert.equal(zero.readLimit().n, null);
});
