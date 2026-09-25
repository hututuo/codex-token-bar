#!/usr/bin/env python3
"""Validate hosted evidence metadata before requesting any signing secrets."""
import argparse, json, os, re, subprocess

def main():
    p=argparse.ArgumentParser()
    p.add_argument('kind',choices=['build','ci','sign'])
    p.add_argument('run_id')
    p.add_argument('source_sha')
    a=p.parse_args()
    if not re.fullmatch(r'[1-9][0-9]*',a.run_id) or not re.fullmatch(r'[0-9a-f]{40}',a.source_sha):
        raise SystemExit('Invalid evidence run ID or source SHA')
    repo=os.environ['GITHUB_REPOSITORY']
    raw=subprocess.check_output(['gh','api',f'repos/{repo}/actions/runs/{a.run_id}'],text=True)
    run=json.loads(raw)
    paths={'build':'.github/workflows/prepare-release.yml','ci':'.github/workflows/ci.yml','sign':'.github/workflows/sign-release.yml'}
    if run['head_repository']['full_name']!=repo or run['status']!='completed' or run['conclusion']!='success':
        raise SystemExit('Evidence run is not a successful same-repository run')
    if run['path'].split('@')[0] not in (paths[a.kind],'.github/workflows/cloud-console.yml'):
        raise SystemExit('Evidence run comes from an unexpected workflow')
    if run['event'] not in ('push','workflow_dispatch'):
        raise SystemExit('PR or automatic privileged chaining is not accepted for signing')
    subprocess.run(['gh','api',f'repos/{repo}/commits/{a.source_sha}','--jq','.sha'],check=True,stdout=subprocess.DEVNULL)
    print('Validated',a.kind,'run',a.run_id,'for manifest-bound source',a.source_sha)

if __name__=='__main__': main()
