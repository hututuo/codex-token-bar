#!/usr/bin/env python3
"""Bind candidate artifacts to an immutable source revision; never include secrets."""
import argparse, hashlib, json, os, pathlib, re, subprocess

def load_verified(root, *, source_sha=None, run_id=None, lane=None):
    root = pathlib.Path(root).resolve()
    manifest = root / 'candidate-manifest.json'
    if manifest.is_symlink() or not manifest.is_file(): raise ValueError('Missing regular candidate manifest')
    data = json.loads(manifest.read_text())
    if data.get('schema') != 1 or not re.fullmatch(r'[0-9a-f]{40}', data.get('source_sha', '')):
        raise ValueError('Invalid candidate source identity')
    if not re.fullmatch(r'\d+\.\d+\.\d+', data.get('version', '')): raise ValueError('Invalid candidate version')
    if data.get('lane') not in ('macos-arm64','windows','combined'): raise ValueError('Invalid candidate lane')
    if data.get('update_signed') is not False or data.get('public_release') is not False:
        raise ValueError('Unsigned candidate manifest cannot assert publication or update signing')
    for key, expected in [('source_sha',source_sha),('workflow_run_id',run_id),('lane',lane)]:
        if expected is not None and str(data.get(key)) != str(expected): raise ValueError(f'Candidate {key} mismatch')
    expected_names = {'candidate-manifest.json'}
    if not isinstance(data.get('assets'),list) or not data['assets']: raise ValueError('Empty candidate assets')
    for a in data['assets']:
        name = a['name']
        if not isinstance(name,str) or name in ('','.', '..') or '/' in name or '\\' in name or name in expected_names:
            raise ValueError('Unsafe or duplicate candidate asset name')
        expected_names.add(name); p=root/name
        if p.is_symlink() or not p.is_file() or p.stat().st_size!=a['bytes'] or digest(p)!=a['sha256']:
            raise ValueError(f'Candidate integrity failed: {name}')
    if {p.name for p in root.iterdir()} != expected_names: raise ValueError('Unexpected candidate asset set')
    return data

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['write', 'verify'])
    parser.add_argument('directory', type=pathlib.Path)
    parser.add_argument('--lane', choices=['macos-arm64', 'windows', 'combined'])
    parser.add_argument('--source-sha')
    parser.add_argument('--run-id')
    args = parser.parse_args()
    root = args.directory.resolve()
    manifest = root / 'candidate-manifest.json'
    if args.mode == 'write':
        if manifest.exists(): raise SystemExit('Refusing to overwrite candidate identity')
        if not args.lane: raise SystemExit('Candidate lane is required')
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        version = json.loads(pathlib.Path('tauri-app/package.json').read_text())['version']
        assets=[]
        for p in sorted(root.iterdir()):
            if p.is_symlink() or not p.is_file(): raise SystemExit(f'Unexpected candidate entry: {p.name}')
            assets.append({'name':p.name, 'bytes':p.stat().st_size, 'sha256':digest(p)})
        if not assets: raise SystemExit('Empty candidate')
        data={'schema':1, 'source_sha':sha, 'version':version, 'lane':args.lane,
              'workflow_run_id':os.environ.get('GITHUB_RUN_ID'),
              'update_signed':False, 'public_release':False, 'assets':assets}
        manifest.write_text(json.dumps(data,indent=2)+'\n')
    else:
        data=load_verified(root, source_sha=args.source_sha, run_id=args.run_id, lane=args.lane)
        print('Verified candidate',data['source_sha'],data['lane'],len(data['assets']))

if __name__=='__main__': main()
