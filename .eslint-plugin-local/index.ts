/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/
import type { ESLint } from 'eslint';
import { globSync } from 'glob';
import path from 'path';

// Re-export all .ts files as rules (loaded as ESM via top-level await)
const ruleFiles = globSync(`${import.meta.dirname}/*.ts`)
	.filter(file => !file.endsWith('index.ts') && !file.endsWith('utils.ts'));

const rules: NonNullable<ESLint.Plugin['rules']> = {};
for (const file of ruleFiles) {
	const relative = './' + path.relative(import.meta.dirname, file);
	rules[path.basename(file, '.ts')] = (await import(relative)).default;
}

export { rules };
