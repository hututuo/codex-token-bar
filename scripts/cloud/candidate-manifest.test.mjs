import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const script = fileURLToPath(new URL('./manifest.py', import.meta.url));
const python = process.platform === 'win32' ? 'python' : 'python3';
function fixture(body) {
  const root=mkdtempSync(join(tmpdir(),'ctb-candidate-'));
  try {
    writeFileSync(join(root,'installer.exe'),'synthetic installer');
    assert.equal(run('write',root,'--lane','windows').status,0);
    body(root);
  } finally { rmSync(root,{recursive:true,force:true}); }
}
function run(...args) { return spawnSync(python,[script,...args],{encoding:'utf8'}); }
test('candidate verifies exact content and binds immutable source identity', () => fixture(root => {
  const data=JSON.parse(readFileSync(join(root,'candidate-manifest.json'),'utf8'));
  assert.equal(run('verify',root,'--source-sha',data.source_sha,'--lane','windows').status,0);
  assert.notEqual(run('verify',root,'--source-sha','0'.repeat(40)).status,0);
  assert.notEqual(run('verify',root,'--lane','macos-arm64').status,0);
  assert.notEqual(run('write',root,'--lane','windows').status,0);
}));
test('candidate rejects changed bytes and additional files', () => fixture(root => {
  writeFileSync(join(root,'unexpected.txt'),'not part of candidate');
  assert.notEqual(run('verify',root).status,0);
  rmSync(join(root,'unexpected.txt'));
  writeFileSync(join(root,'installer.exe'),'tampered installer');
  assert.notEqual(run('verify',root).status,0);
}));
test('candidate rejects traversal and false signed claims', () => fixture(root => {
  const path=join(root,'candidate-manifest.json');
  const data=JSON.parse(readFileSync(path,'utf8'));
  data.update_signed=true; writeFileSync(path,JSON.stringify(data));
  assert.notEqual(run('verify',root).status,0);
  data.update_signed=false; data.assets[0].name='..\\installer.exe';
  writeFileSync(path,JSON.stringify(data));
  assert.notEqual(run('verify',root).status,0);
}));
