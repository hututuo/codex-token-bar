#!/usr/bin/env python3
"""Publish a previously signed packet after explicit environment approval.

Resume is create-only: existing tags, assets and release notes must match.
The public updater feed is changed only after all release assets are live.
"""
import argparse, base64, json, os, pathlib, re, subprocess, tempfile
from release_packet import REPO, api, digest, run, verify_packet

def put(path, body):
    result=subprocess.run(['gh','api','--method','PUT',f'repos/{REPO}/{path}','--input','-'],
                          input=json.dumps(body),text=True,capture_output=True)
    if result.returncode: raise RuntimeError('GitHub write failed: '+result.stderr[-500:])
    return json.loads(result.stdout)

def main():
    p=argparse.ArgumentParser()
    p.add_argument('packet',type=pathlib.Path)
    p.add_argument('--source-sha',required=True)
    p.add_argument('--version',required=True)
    p.add_argument('--confirm',required=True)
    a=p.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+',a.version) or a.confirm!=f'publish-v{a.version}':
        raise SystemExit('Exact publish-vVERSION confirmation is required')
    data=verify_packet(a.packet,a.source_sha)
    if data['version']!=a.version: raise SystemExit('Approved version does not match the sealed packet')
    if os.environ.get('GITHUB_REPOSITORY')!=REPO: raise SystemExit('Unexpected publication repository')
    notes=(a.packet/'release-notes.md').read_text()
    if '## English' not in notes: raise SystemExit('Chinese-first and English release notes are required before public publication')
    tag=f'v{a.version}'
    existing_tag=subprocess.run(['gh','api',f'repos/{REPO}/commits/{tag}','--jq','.sha'],text=True,capture_output=True)
    if existing_tag.returncode==0 and existing_tag.stdout.strip()!=a.source_sha:
        raise SystemExit('Version tag already identifies different source code; no draft created')
    if existing_tag.returncode!=0 and '404' not in existing_tag.stderr:
        raise SystemExit('Unable to determine the current tag identity')
    latest=subprocess.run(['gh','api',f'repos/{REPO}/releases/latest','--jq','.tag_name'],text=True,capture_output=True)
    if latest.returncode==0:
        last=latest.stdout.strip().removeprefix('v')
        if not re.fullmatch(r'\d+\.\d+\.\d+',last): raise SystemExit('Unknown current release version scheme')
        if tuple(map(int,a.version.split('.'))) < tuple(map(int,last.split('.'))):
            raise SystemExit('Refusing to make an older version the latest public release')
    elif '404' not in latest.stderr:
        raise SystemExit('Unable to determine current public version')
    baseline=json.loads((a.packet/'appcast-baseline.json').read_text())
    current_feed=api('contents/appcast.xml?ref=main')
    wanted_feed=(a.packet/'appcast.xml').read_bytes()
    feed_already_equal=base64.b64decode(current_feed['content'])==wanted_feed
    if current_feed['sha']!=baseline['blob_sha'] and not feed_already_equal:
        raise SystemExit('Live appcast changed after signing; regenerate a candidate rather than overwrite history')
    existing=subprocess.run(['gh','api',f'repos/{REPO}/releases/tags/{tag}'],text=True,capture_output=True)
    if existing.returncode:
        if '404' not in existing.stderr: raise SystemExit('Unable to determine current release state')
        run('gh','release','create',tag,'--repo',REPO,'--draft','--target',a.source_sha,
            '--title',f'Codex Token Bar {tag}','--notes-file',a.packet/'release-notes.md')
        release=api(f'releases/tags/{tag}')
    else:
        release=json.loads(existing.stdout)
        if release.get('body','').strip()!=notes.strip(): raise SystemExit('Existing release notes differ; no overwrite performed')
    # A draft can already have a tag. Never move a published or conflicting tag.
    target=subprocess.run(['gh','api',f'repos/{REPO}/commits/{tag}','--jq','.sha'],text=True,capture_output=True)
    if target.returncode==0 and target.stdout.strip()!=a.source_sha:
        raise SystemExit('Version tag already identifies different source code')
    if target.returncode!=0 and not release['draft']: raise SystemExit('Published release tag could not be verified')
    metadata={f['name']:f for f in data['files']}
    expected=set(data['public_assets'])
    assets={r['name']:r for r in release['assets']}
    if not set(assets).issubset(expected): raise SystemExit('Existing release contains unexpected assets')
    for name,item in assets.items():
        if item['size']!=metadata[name]['bytes']: raise SystemExit('Existing release asset size mismatch')
    missing=sorted(expected-set(assets))
    if missing:
        if not release['draft']: raise SystemExit('Published release is incomplete; refusing automatic mutation')
        run('gh','release','upload',tag,'--repo',REPO,*[a.packet/n for n in missing])
    # Re-download even pre-existing assets; filename/size alone is not identity.
    with tempfile.TemporaryDirectory(prefix='ctb-release-readback-') as temp:
        run('gh','release','download',tag,'--repo',REPO,'--dir',temp)
        paths={p.name:p for p in pathlib.Path(temp).iterdir()}
        if set(paths)!=expected: raise SystemExit('Remote release asset set differs from approved packet')
        for name,path in paths.items():
            if digest(path)!=metadata[name]['sha256']: raise SystemExit('Remote release checksum mismatch: '+name)
    if release['draft']: run('gh','release','edit',tag,'--repo',REPO,'--draft=false','--latest')
    final=api(f'releases/tags/{tag}')
    if final['draft']: raise SystemExit('Release is still a draft; live feed will not be changed')
    if api(f'commits/{tag}')['sha']!=a.source_sha: raise SystemExit('Final tag/source mismatch')
    feed=api('contents/appcast.xml?ref=main')
    if base64.b64decode(feed['content'])!=wanted_feed:
        if feed['sha']!=baseline['blob_sha']: raise SystemExit('Release is live but feed changed concurrently; feed left intact')
        put('contents/appcast.xml',{'message':f'release: enable verified {tag} Sparkle feed',
            'content':base64.b64encode(wanted_feed).decode(),'sha':feed['sha'],'branch':'main'})
    if base64.b64decode(api('contents/appcast.xml?ref=main')['content'])!=wanted_feed:
        raise SystemExit('Published feed readback mismatch')
    locator={'version':a.version,'source_sha':a.source_sha,'tag':tag,'release_url':final['html_url'],
      'build_run_id':data['build_run_id'],'ci_run_id':data['ci_run_id'],
      'signing_run_id':data['signing_run_id'],'publish_run_id':os.environ['GITHUB_RUN_ID'],
      'assets':[metadata[n] for n in data['public_assets']]}
    path=f'contents/docs/releases/{tag}-cloud-locator.json'
    check=subprocess.run(['gh','api',f'repos/{REPO}/{path}?ref=main'],text=True,capture_output=True)
    body={'message':f'docs: locate cloud release {tag}',
      'content':base64.b64encode((json.dumps(locator,indent=2)+'\n').encode()).decode(),'branch':'main'}
    if check.returncode==0:
        previous=json.loads(check.stdout)
        previous_locator=json.loads(base64.b64decode(previous['content']))
        if previous_locator['source_sha']!=a.source_sha or previous_locator['assets']!=locator['assets']:
            raise SystemExit('Existing release locator differs; no overwrite performed')
    else:
        if '404' not in check.stderr: raise SystemExit('Unable to inspect release locator')
        put(path,body)
    print('Published and verified:',final['html_url'])

if __name__=='__main__': main()
