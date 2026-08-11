/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import path from 'path';
import * as fs from 'fs';
import * as child_process from 'child_process';
import * as os from 'os';
import { isUpToDate, forceInstallMessage } from './installStateHash.ts';

if (!process.env['VSCODE_SKIP_NODE_VERSION_CHECK']) {
	// Get the running Node.js version.
	const nodeVersion = /^(\d+)\.(\d+)\.(\d+)/.exec(process.versions.node);

	if (!nodeVersion) {
		console.error('\x1b[1;31m*** Unable to determine the running Node.js version.\x1b[0;0m');
		throw new Error();
	}

	const majorNodeVersion = parseInt(nodeVersion[1], 10);
	const minorNodeVersion = parseInt(nodeVersion[2], 10);

	// Get the minimum Node.js version from .nvmrc.
	// This fork intentionally allows newer Node.js versions rather than
	// requiring an exact match with the repository-pinned version.
	const nvmrcPath = path.join(import.meta.dirname, '..', '..', '.nvmrc');
	const requiredVersion = fs.readFileSync(nvmrcPath, 'utf8').trim();
	const requiredVersionMatch = /^(\d+)\.(\d+)\.(\d+)/.exec(requiredVersion);

	if (!requiredVersionMatch) {
		console.error('\x1b[1;31m*** Unable to parse required Node.js version from .nvmrc\x1b[0;0m');
		throw new Error();
	}

	const floorMajor = parseInt(requiredVersionMatch[1], 10);
	const floorMinor = parseInt(requiredVersionMatch[2], 10);

	// Allow the repository-pinned version and any newer Node.js version.
	if (
		majorNodeVersion < floorMajor ||
		(majorNodeVersion === floorMajor && minorNodeVersion < floorMinor)
	) {
		console.error(
			`\x1b[1;31m*** Please use Node.js v${requiredVersion} or newer. Currently using v${process.versions.node}.\x1b[0;0m`
		);
		throw new Error();
	}
}

if (process.env.npm_execpath?.includes('yarn')) {
	console.error(
		'\x1b[1;31m*** Seems like you are using `yarn` which is not supported in this repo any more, please use `npm i` instead. ***\x1b[0;0m'
	);
	throw new Error();
}

// Fast path: if nothing changed since last successful install, skip everything.
// This makes `npm i` near-instant when dependencies haven't changed.
if (!process.env['VSCODE_FORCE_INSTALL'] && isUpToDate()) {
	console.log(`\x1b[32mAll dependencies up to date.\x1b[0m ${forceInstallMessage}`);
	process.exit(0);
}

if (process.platform === 'win32') {
	if (!hasSupportedVisualStudioVersion()) {
		console.error(
			'\x1b[1;31m*** Invalid C/C++ Compiler Toolchain. Please check https://github.com/microsoft/vscode/wiki/How-to-Contribute#prerequisites.\x1b[0;0m'
		);
		console.error(
			'\x1b[1;31m*** If you have Visual Studio installed in a custom location, you can specify it via the environment variable:\x1b[0;0m'
		);
		console.error(
			'\x1b[1;31m*** set vs2022_install=<path> (or a matching vs<year>_install variable for your version)\x1b[0;0m'
		);
		throw new Error();
	}
}

installHeaders();

if (process.arch !== os.arch()) {
	console.error(
		`\x1b[1;31m*** ARCHITECTURE MISMATCH: The Node.js process is ${process.arch}, but your OS architecture is ${os.arch()}. ***\x1b[0;0m`
	);
	console.error(
		'\x1b[1;31m*** This can greatly increase the build time of VS Code. ***\x1b[0;0m'
	);
}

function hasSupportedVisualStudioVersion(): boolean {
	// Translated over from:
	// https://source.chromium.org/chromium/chromium/src/+/master:build/vs_toolchain.py;l=140-175
	const supportedVersions = ['2022', '2019'];

	const vsTypes = [
		'Enterprise',
		'Professional',
		'Community',
		'Preview',
		'BuildTools',
		'IntPreview'
	];

	const programFiles86Path = process.env['ProgramFiles(x86)'];
	const programFiles64Path = process.env['ProgramFiles'];

	// Honor every explicit vs<year>_install override, not just the two known
	// years. Custom install paths may point at any VS release line.
	for (const [environmentVariable, vsPath] of Object.entries(process.env)) {
		if (environmentVariable.startsWith('vs') && environmentVariable.endsWith('_install')) {
			if (vsPath && fs.existsSync(vsPath)) {
				return true;
			}
		}
	}

	for (const version of supportedVersions) {
		// Check environment variable first (explicit override).
		const environmentVariable = `vs${version}_install`;
		let vsPath = process.env[environmentVariable];

		if (vsPath && fs.existsSync(vsPath)) {
			return true;
		}

		// Check default installation paths.
		if (programFiles64Path) {
			vsPath = path.join(
				programFiles64Path,
				'Microsoft Visual Studio',
				version
			);

			if (vsTypes.some(vsType => fs.existsSync(path.join(vsPath!, vsType)))) {
				return true;
			}
		}

		if (programFiles86Path) {
			vsPath = path.join(
				programFiles86Path,
				'Microsoft Visual Studio',
				version
			);

			if (vsTypes.some(vsType => fs.existsSync(path.join(vsPath!, vsType)))) {
				return true;
			}
		}
	}

	// Also accept newer Visual Studio release lines (e.g. VS 2026 / v18). Node-gyp
	// itself discovers these fine, so scan any versioned directory under
	// "Microsoft Visual Studio" for a known VS type (Community, Professional,
	// Enterprise, Preview, BuildTools, IntPreview).
	for (const programFilesPath of [programFiles64Path, programFiles86Path]) {
		if (!programFilesPath) {
			continue;
		}

		const vsRoot = path.join(programFilesPath, 'Microsoft Visual Studio');

		if (!fs.existsSync(vsRoot)) {
			continue;
		}

		for (const entry of fs.readdirSync(vsRoot, { withFileTypes: true })) {
			if (!entry.isDirectory()) {
				continue;
			}

			if (vsTypes.some(vsType => fs.existsSync(path.join(vsRoot, entry.name, vsType)))) {
				return true;
			}
		}
	}

	return false;
}

function installHeaders(): void {
	const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';

	child_process.execSync(`${npm} ${process.env.npm_command || 'ci'}`, {
		env: process.env,
		cwd: path.join(import.meta.dirname, 'gyp'),
		stdio: 'inherit'
	});

	// The node-gyp package was installed using the above npm command
	// and the gyp/package.json file checked into our repository.
	// From that point it is safe to construct the path to that executable.
	const nodeGyp = process.platform === 'win32'
		? path.join(import.meta.dirname, 'gyp', 'node_modules', '.bin', 'node-gyp.cmd')
		: path.join(import.meta.dirname, 'gyp', 'node_modules', '.bin', 'node-gyp');

	const local = getHeaderInfo(path.join(import.meta.dirname, '..', '..', '.npmrc'));
	const remote = getHeaderInfo(path.join(import.meta.dirname, '..', '..', 'remote', '.npmrc'));

	if (local !== undefined) {
		// Both disturl and target come from a file checked into our repository.
		child_process.execFileSync(
			nodeGyp,
			['install', '--dist-url', local.disturl, local.target],
			{ shell: true }
		);
	}

	const remoteDistUrl = remote?.disturl ?? 'https://nodejs.org/dist';

	// Always build the remote native modules against the node version that is
	// actually running this machine/build, rather than a version pinned in
	// remote/.npmrc. This keeps local builds on the latest runtime.
	const remoteTarget = process.versions.node;

	child_process.execFileSync(
		nodeGyp,
		['install', '--dist-url', remoteDistUrl, remoteTarget],
		{ shell: true }
	);

	// Overlay any custom headers shipped in build/npm/gyp/custom-headers
	// on top of the downloaded Electron headers. This is used to work
	// around upstream issues:
	//
	//   - v8-source-location.h: remove dependency on std::source_location
	//     (GCC 11+ requirement)
	//
	// Refs:
	// https://chromium-review.googlesource.com/c/v8/v8/+/6879784
	if (local !== undefined) {
		const localHeaderPath = getLocalHeaderPath(local.target);

		if (localHeaderPath && fs.existsSync(localHeaderPath)) {
			copyCustomHeaders(
				path.join(import.meta.dirname, 'gyp', 'custom-headers'),
				localHeaderPath
			);
		}
	}
}

function copyCustomHeaders(sourceDir: string, targetDir: string): void {
	for (const entry of fs.readdirSync(sourceDir, { withFileTypes: true })) {
		const sourcePath = path.join(sourceDir, entry.name);
		const targetPath = path.join(targetDir, entry.name);

		if (entry.isDirectory()) {
			fs.mkdirSync(targetPath, { recursive: true });
			copyCustomHeaders(sourcePath, targetPath);
		} else if (entry.isFile()) {
			console.log('Overlaying custom header', targetPath);
			fs.copyFileSync(sourcePath, targetPath);
		}
	}
}

function getLocalHeaderPath(target: string): string | undefined {
	if (process.platform === 'win32') {
		const localAppData = process.env.LOCALAPPDATA;

		if (!localAppData) {
			return undefined;
		}

		return path.join(
			localAppData,
			'node-gyp',
			'Cache',
			target,
			'include',
			'node'
		);
	}

	const homedir = os.homedir();
	const cachePath = process.env.XDG_CACHE_HOME || path.join(homedir, '.cache');

	return path.join(
		cachePath,
		'node-gyp',
		target,
		'include',
		'node'
	);
}

function getHeaderInfo(
	rcFile: string
): { disturl: string; target: string } | undefined {
	// Tolerate a missing .npmrc: header installation is best-effort and must
	// not block `npm install` when the file has been removed.
	if (!fs.existsSync(rcFile)) {
		return undefined;
	}

	const lines = fs.readFileSync(rcFile, 'utf8').split(/\r\n|\n/g);

	let disturl: string | undefined;
	let target: string | undefined;

	for (const line of lines) {
		let match = line.match(/\s*disturl="(.*)"\s*$/);

		if (match !== null && match.length >= 1) {
			disturl = match[1];
		}

		match = line.match(/\s*target="(.*)"\s*$/);

		if (match !== null && match.length >= 1) {
			target = match[1];
		}
	}

	return disturl !== undefined && target !== undefined
		? { disturl, target }
		: undefined;
}
