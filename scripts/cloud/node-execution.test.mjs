import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const runner = fileURLToPath(new URL('./run-node-tests.mjs', import.meta.url));
function runFixture(files, options = []) {
  const root = mkdtempSync(join(tmpdir(), 'tokenbar-node-gate-'));
  try {
    for (const [name, source] of Object.entries(files)) writeFileSync(join(root, name), source);
    const report = join(root, 'execution.json');
    // NODE_TEST_CONTEXT would make the child runner execute in its parent's
    // test worker instead of acting as an independent acceptance command.
    const env = { ...process.env, TOKENBAR_NODE_EXECUTION_REPORT: report };
    delete env.NODE_TEST_CONTEXT;
    const result = spawnSync(process.execPath, [runner, root, ...options], { env, encoding: 'utf8', timeout: 15000 });
    return { ...result, evidence: (() => { try { return JSON.parse(readFileSync(report, 'utf8')); } catch { return null; } })() };
  } finally { rmSync(root, { recursive: true, force: true }); }
}
const pass = "import test from 'node:test';test('actual test',()=>{});";
test('declared passing tests produce execution evidence', () => {
  const result = runFixture({ 'pass.test.mjs': pass }, ['--no-skips']);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.equal(result.evidence.passed, 1);
  assert.equal(result.evidence.status, 'PASS');
});
test('empty files cannot pass as implicit file-level tests', () => {
  for (const files of [{}, { 'empty.test.mjs': '' }, { 'empty.test.mjs': '', 'pass.test.mjs': pass }]) {
    const result = runFixture(files);
    assert.notEqual(result.status, 0);
  }
});
test('all-skipped, TODO, assertion failure and process failure cannot pass', () => {
  for (const source of ["import test from 'node:test';test.skip('skip',()=>{});",
    "import test from 'node:test';test.todo('todo');", "import test from 'node:test';test('bad',()=>{throw Error('negative control')});",
    "process.exit(7)"]) {
    const result = runFixture({ 'bad.test.mjs': source });
    assert.notEqual(result.status, 0, result.stdout);
    assert.equal(result.evidence?.status, 'FAIL');
  }
});
test('optional platform skips are counted while required skips fail', () => {
  const files = { 'pass.test.mjs': pass, 'skip.test.mjs': "import test from 'node:test';test.skip('platform case',()=>{});" };
  const optional = runFixture(files);
  assert.equal(optional.status, 0, optional.stderr + optional.stdout);
  assert.equal(optional.evidence.skipped, 1);
  assert.notEqual(runFixture(files, ['--no-skips']).status, 0);
});
