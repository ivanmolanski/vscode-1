#!/usr/bin/env node
// code-server's OSS image omits these optional Microsoft modules. Avoid loading
// absent assets; retain VS Code's existing unsigned-handshake and ML fallbacks.
const fs = require('node:fs');
const path = require('node:path');

function patchOptionalAssets(root) {
  const workbench = path.join(root, 'out/vs/code/browser/workbench/workbench.js');
  const worker = path.join(root, 'out/vs/workbench/services/languageDetection/browser/languageDetectionWebWorkerMain.js');
  const patches = [];
  if (['vsda.js', 'vsda_bg.wasm'].some(file =>
    !fs.existsSync(path.join(root, 'node_modules/vsda/rust/web', file)))) {
    patches.push({
      file: workbench,
      anchor: 'async vsda(){',
      replacement: 'async vsda(){throw new Error("Optional vsda unavailable in OSS image");',
    });
  }
  if (!fs.existsSync(path.join(root, 'node_modules/vscode-regexp-languagedetection/dist/index.js'))) {
    patches.push({
      file: worker,
      anchor: 'async getRegexpModel(){',
      replacement: 'async getRegexpModel(){return undefined;',
    });
  }
  // Validate every signature before writing anything. A changed upstream bundle
  // must fail the build, not silently reintroduce 404s or corrupt the JavaScript.
  const changes = patches.map(({ file, anchor, replacement }) => {
    const source = fs.readFileSync(file, 'utf8');
    if (source.includes(replacement)) return null;
    if (source.split(anchor).length !== 2) {
      throw new Error(`Expected exactly one ${anchor} in ${file}`);
    }
    return { file, source: source.replace(anchor, replacement) };
  }).filter(Boolean);
  for (const { file, source } of changes) {
    fs.writeFileSync(file, source);
    console.log(`[optional-assets] Guarded missing optional module in ${file}`);
  }
  return changes.length;
}

if (require.main === module) {
  patchOptionalAssets(process.argv[2] || '/app/code-server/lib/vscode');
}
module.exports = { patchOptionalAssets };
