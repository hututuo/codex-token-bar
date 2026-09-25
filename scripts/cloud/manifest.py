#!/usr/bin/env python3
"""Bind candidate artifacts to an immutable source revision; never include secrets."""
import argparse, hashlib, json, os, pathlib, subprocess

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
    args = parser.parse_args()
    root = args.directory.resolve()
    manifest = root / 'candidate-manifest.json'
    if args.mode == 'write':
        if manifest.exists(): raise SystemExit('Refusing to overwrite candidate identity')
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
        data=json.loads(manifest.read_text())
        expected={'candidate-manifest.json'}
        for a in data['assets']:
            name=a['name']
            if pathlib.Path(name).name != name or name in expected: raise SystemExit('Unsafe or duplicate asset name')
            expected.add(name); p=root/name
            if p.is_symlink() or not p.is_file() or p.stat().st_size!=a['bytes'] or digest(p)!=a['sha256']:
                raise SystemExit(f'Candidate integrity failed: {name}')
        if {p.name for p in root.iterdir()}!=expected: raise SystemExit('Unexpected candidate asset set')
        print('Verified candidate',data['source_sha'],data['lane'],len(data['assets']))

if __name__=='__main__': main()
