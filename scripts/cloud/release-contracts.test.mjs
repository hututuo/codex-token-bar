import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root=fileURLToPath(new URL('../../',import.meta.url));
const python=process.platform==='win32'?'python':'python3';
const read=p=>readFileSync(new URL(`../../${p}`,import.meta.url),'utf8');
test('signing key files remain strict Base64, private and create-only',()=>{
  const script=[
    "import sys,base64,pathlib,tempfile,stat",
    "sys.path.insert(0,'scripts/cloud')",
    "from release_packet import write_signing_key",
    "with tempfile.TemporaryDirectory() as directory:",
    " for index,suffix in enumerate(['',chr(10),chr(13)+chr(10)]):",
    "  path=pathlib.Path(directory)/str(index)",
    "  write_signing_key(path,'dGVzdC1rZXk='+suffix)",
    "  assert base64.b64decode(path.read_bytes(),validate=True)==b'test-key'",
    "  assert sys.platform=='win32' or stat.S_IMODE(path.stat().st_mode)==0o600",
    "  try: write_signing_key(path,'cmVwbGFjZWQ=')",
    "  except FileExistsError: pass",
    "  else: raise AssertionError('Existing key was overwritten')",
    "  assert path.read_bytes()==b'dGVzdC1rZXk='",
    " empty=pathlib.Path(directory)/'empty'",
    " try: write_signing_key(empty,chr(10))",
    " except ValueError: pass",
    " else: raise AssertionError('Empty key was accepted')",
    " assert not empty.exists()",
  ].join('\n');
  const result=spawnSync(python,['-c',script],{cwd:root,encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
});
test('privileged workflows are manual/reusable and require protected environments',()=>{
  for(const [file,environment] of [['sign-release.yml','release-signing'],['publish-release.yml','production-release']]) {
    const content=read(`.github/workflows/${file}`);
    assert.ok(content.includes('workflow_dispatch:'));
    assert.ok(content.includes('workflow_call:'));
    assert.ok(content.includes(`environment: ${environment}`));
    assert.ok(!/^\s+(push|pull_request_target|workflow_run):/m.test(content));
  }
});
test('candidate evidence rejects shell-shaped inputs before making network requests',()=>{
  for(const args of [['build','-1','0'.repeat(40)],['build','123','main;echo unsafe']]) {
    const result=spawnSync(python,['scripts/cloud/run-guard.py',...args],{cwd:root,encoding:'utf8'});
    assert.notEqual(result.status,0);
    assert.ok(!result.stderr.includes('GITHUB_REPOSITORY'));
  }
});
test('public publication requires an exact confirmation before reading a packet or calling GitHub',()=>{
  const result=spawnSync(python,['scripts/cloud/publish_packet.py','nonexistent-packet','--source-sha','0'.repeat(40),
    '--version','0.9.2','--confirm','prepare'],{cwd:root,encoding:'utf8'});
  assert.notEqual(result.status,0);
  assert.match(result.stderr,/Exact publish-vVERSION confirmation/);
});
test('release packet keeps exactly nine public assets and excludes signing metadata',()=>{
  const result=spawnSync(python,['-c',"import sys,json;sys.path.insert(0,'scripts/cloud');from release_packet import public_names;print(json.dumps(public_names('0.9.2')))"],{cwd:root,encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
  const names=JSON.parse(result.stdout);
  assert.equal(names.length,9);
  assert.equal(new Set(names).size,9);
  assert.ok(names.includes('CodexTokenBar-v0.9.2-windows-arm64-setup.exe.sig'));
  assert.ok(!names.includes('appcast-baseline.json'));
  assert.ok(!names.some(n=>n.includes('private')||n.endsWith('.key')));
});
