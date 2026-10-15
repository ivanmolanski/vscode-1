const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const { patchOptionalAssets } = require('./patch-optional-assets.cjs');

function fixture(t, { assets = false, changed = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'optional-assets-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const workbench = path.join(root, 'out/vs/code/browser/workbench/workbench.js');
  const worker = path.join(root, 'out/vs/workbench/services/languageDetection/browser/languageDetectionWebWorkerMain.js');
  for (const file of [workbench, worker]) fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(workbench, 'class Sign {async vsda(){throw new Error("fetch attempted")}}');
  fs.writeFileSync(worker, changed ? 'class Worker {}' : 'class Worker {async getRegexpModel(){throw new Error("fetch attempted")}}');
  if (assets) {
    for (const file of ['vsda/rust/web/vsda.js', 'vsda/rust/web/vsda_bg.wasm', 'vscode-regexp-languagedetection/dist/index.js']) {
      const target = path.join(root, 'node_modules', file);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, 'present');
    }
  }
  return { root, workbench, worker };
}

test('missing modules use fallbacks without attempting fetch; patch is idempotent', async t => {
  const { root, workbench, worker } = fixture(t);
  assert.equal(patchOptionalAssets(root), 2);
  const sign = new (new Function(`${fs.readFileSync(workbench, 'utf8')}; return Sign;`)())();
  await assert.rejects(sign.vsda(), /Optional vsda unavailable/);
  const detector = new (new Function(`${fs.readFileSync(worker, 'utf8')}; return Worker;`)())();
  assert.equal(await detector.getRegexpModel(), undefined);
  assert.equal(patchOptionalAssets(root), 0);
});

test('complete optional modules are left untouched', t => {
  const { root, workbench, worker } = fixture(t, { assets: true });
  const before = [workbench, worker].map(file => fs.readFileSync(file, 'utf8'));
  assert.equal(patchOptionalAssets(root), 0);
  assert.deepEqual([workbench, worker].map(file => fs.readFileSync(file, 'utf8')), before);
});

test('changed upstream signatures fail before writing either bundle', t => {
  const { root, workbench } = fixture(t, { changed: true });
  const before = fs.readFileSync(workbench, 'utf8');
  assert.throws(() => patchOptionalAssets(root), /Expected exactly one/);
  assert.equal(fs.readFileSync(workbench, 'utf8'), before);
});

test('partial vsda installation also uses the fallback', t => {
  const { root } = fixture(t, { assets: true });
  fs.unlinkSync(path.join(root, 'node_modules/vsda/rust/web/vsda_bg.wasm'));
  assert.equal(patchOptionalAssets(root), 1);
});
