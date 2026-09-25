#!/usr/bin/env python3
"""Sign verified hosted candidates, or verify a sealed publication packet.

No build takes place here. Private keys are only materialized in a temporary
directory outside the checkout and are never included in packet contents.
"""
import argparse, base64, hashlib, json, os, pathlib, re, shutil, subprocess, tempfile
from manifest import digest, load_verified

ROOT = pathlib.Path(__file__).resolve().parents[2]
REPO = 'hututuo/codex-token-bar'

def run(*args, capture=False, env=None):
    return subprocess.run([str(a) for a in args], cwd=ROOT, check=True,
                          text=True, capture_output=capture, env=env).stdout

def api(path):
    return json.loads(run('gh','api',f'repos/{REPO}/{path}',capture=True))

def public_names(version):
    prefix=f'CodexTokenBar-v{version}'
    return [f'{prefix}-macos-arm64.dmg',f'{prefix}-macos-arm64.app.zip','CodexTokenBar.app.zip',
            f'{prefix}-windows-x64-setup.exe',f'{prefix}-windows-x64-setup.exe.sig',
            f'{prefix}-windows-arm64-setup.exe',f'{prefix}-windows-arm64-setup.exe.sig',
            'latest-windows.json',f'SHA256SUMS-v{version}.txt']

SUPPORT = ['appcast.xml','appcast-baseline.json','release-notes.md','windows-build-manifest.json']

def source_public_key(source):
    match=re.search(r'SPARKLE_PUBLIC_ED_KEY:-([^}]+)',source)
    if not match: raise ValueError('Expected Sparkle public key was not found')
    return match.group(1)

def verify_sparkle(packet, version, public_key):
    import xml.etree.ElementTree as ET
    ns={'sparkle':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
    tree=ET.parse(packet/'appcast.xml')
    items=[i for i in tree.findall('./channel/item')
           if i.findtext('sparkle:shortVersionString',namespaces=ns)==version]
    if len(items)!=1: raise ValueError('Appcast must contain exactly one candidate version')
    enclosure=items[0].find('enclosure')
    if enclosure is None: raise ValueError('Appcast enclosure is missing')
    asset=f'CodexTokenBar-v{version}-macos-arm64.app.zip'
    if enclosure.get('url')!=f'https://github.com/{REPO}/releases/download/v{version}/{asset}':
        raise ValueError('Unexpected Sparkle download target')
    if enclosure.get('length')!=str((packet/asset).stat().st_size): raise ValueError('Sparkle size mismatch')
    signature=enclosure.get('{'+ns['sparkle']+'}edSignature','')
    # Public verification is deliberately independent of the private signing key.
    verifier="""const c=require('crypto'),fs=require('fs');
const key=c.createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),Buffer.from(process.argv[1],'base64')]),format:'der',type:'spki'});
if(!c.verify(null,fs.readFileSync(process.argv[2]),key,Buffer.from(process.argv[3],'base64')))process.exit(1);"""
    run('node','-e',verifier,public_key,packet/asset,signature,capture=True)

def verify_packet(packet, source_sha=None):
    packet=pathlib.Path(packet).resolve()
    if (packet/'release-manifest.json').is_symlink(): raise ValueError('Manifest cannot be a symlink')
    data=json.loads((packet/'release-manifest.json').read_text())
    version=data.get('version','')
    if data.get('schema')!=1 or not re.fullmatch(r'\d+\.\d+\.\d+',version): raise ValueError('Invalid release manifest')
    if not re.fullmatch(r'[0-9a-f]{40}',data.get('source_sha','')): raise ValueError('Invalid source SHA')
    if source_sha and data['source_sha']!=source_sha: raise ValueError('Release source SHA mismatch')
    if data.get('update_signed') is not True or data.get('public_release') is not False:
        raise ValueError('Not a signed, unpublished candidate packet')
    names=public_names(version)
    if data.get('public_assets')!=names: raise ValueError('Unexpected public release asset list')
    expected=set(names+SUPPORT)
    observed=set()
    for f in data['files']:
        name=f['name']
        if name not in expected or name in observed: raise ValueError('Unexpected or duplicate packet file')
        observed.add(name); path=packet/name
        if path.is_symlink() or not path.is_file() or path.stat().st_size!=f['bytes'] or digest(path)!=f['sha256']:
            raise ValueError(f'Packet integrity failure: {name}')
    if observed!=expected or {p.name for p in packet.iterdir()}!=expected|{'release-manifest.json'}:
        raise ValueError('Incomplete or extra packet contents')
    # Verify both updater schemes again before permitting publication.
    baseline=json.loads((packet/'appcast-baseline.json').read_text())
    current_sparkle=source_public_key((ROOT/'scripts/package_app.sh').read_text())
    current_tauri=json.loads((ROOT/'tauri-app/src-tauri/tauri.conf.json').read_text())['plugins']['updater']['pubkey']
    if current_sparkle!=baseline['sparkle_public_key'] or current_tauri!=baseline['tauri_public_key']:
        raise ValueError('Unexpected update-key rotation; an explicit key-transition release is required')
    verify_sparkle(packet,version,current_sparkle)
    windows=json.loads((packet/'windows-build-manifest.json').read_text())
    if windows.get('version')!=version or windows.get('windowsArch')!='both': raise ValueError('Windows architecture/version mismatch')
    with tempfile.TemporaryDirectory(prefix='ctb-public-verify-') as temp:
        assets=pathlib.Path(temp)/'assets.json'
        assets.write_text(json.dumps(windows['assets']))
        run('node','scripts/tauri_windows_release_helper.mjs','verify-signatures',assets,packet,
            ROOT/'tauri-app/src-tauri/tauri.conf.json',capture=True)
    checksums={}
    for line in (packet/f'SHA256SUMS-v{version}.txt').read_text().splitlines():
        value,name=line.split('  ',1)
        if name in checksums or name not in names[:-1]: raise ValueError('Unexpected checksum entry')
        checksums[name]=value
    if set(checksums)!=set(names[:-1]) or any(digest(packet/n)!=v for n,v in checksums.items()):
        raise ValueError('Unified checksum verification failed')
    return data

def sign(args):
    sha=args.source_sha
    if not re.fullmatch(r'[0-9a-f]{40}',sha): raise ValueError('Exact source SHA is required')
    if run('git','rev-parse','HEAD',capture=True).strip()!=sha: raise ValueError('Signer checkout is not the approved source')
    mac=load_verified(args.macos,source_sha=sha,run_id=args.build_run,lane='macos-arm64')
    win=load_verified(args.windows,source_sha=sha,run_id=args.build_run,lane='windows')
    version=mac['version']
    if win['version']!=version: raise ValueError('Candidate versions differ')
    if json.loads((ROOT/'tauri-app/package.json').read_text())['version']!=version: raise ValueError('Source version differs')
    evidence=json.loads(args.ci_evidence.read_text())
    if evidence!={'source_sha':sha,'run_id':str(args.ci_run),'passed':True}: raise ValueError('CI evidence is not for this source/run')
    keys=[os.environ.get('SPARKLE_PRIVATE_KEY',''),os.environ.get('TAURI_UPDATER_PRIVATE_KEY','')]
    if not all(keys): raise ValueError('Both existing update keys must be configured in the protected signing environment')
    if args.output.exists(): raise ValueError('Refusing to overwrite a signed release packet')
    baseline=api('contents/appcast.xml?ref=main')
    base_xml=base64.b64decode(baseline['content'])
    spark_source=base64.b64decode(api('contents/scripts/package_app.sh?ref=main')['content']).decode()
    tauri_source=json.loads(base64.b64decode(api('contents/tauri-app/src-tauri/tauri.conf.json?ref=main')['content']))
    baseline_info={'blob_sha':baseline['sha'],'sha256':hashlib.sha256(base_xml).hexdigest(),
      'sparkle_public_key':source_public_key(spark_source),'tauri_public_key':tauri_source['plugins']['updater']['pubkey']}
    if source_public_key((ROOT/'scripts/package_app.sh').read_text())!=baseline_info['sparkle_public_key']:
        raise ValueError('Refusing an unplanned Sparkle public-key change')
    if json.loads((ROOT/'tauri-app/src-tauri/tauri.conf.json').read_text())['plugins']['updater']['pubkey']!=baseline_info['tauri_public_key']:
        raise ValueError('Refusing an unplanned Tauri public-key change')
    with tempfile.TemporaryDirectory(prefix='ctb-sign-',dir=os.environ.get('RUNNER_TEMP')) as tmp:
        temp=pathlib.Path(tmp); os.chmod(temp,0o700)
        keypaths=[]
        for i,value in enumerate(keys):
            key=temp/f'private-{i}.key'
            with os.fdopen(os.open(key,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as f: f.write(value.rstrip()+'\n')
            keypaths.append(key)
        # Child tools receive paths; do not propagate both private key values.
        child_env=os.environ.copy()
        for name in ['SPARKLE_PRIVATE_KEY','TAURI_UPDATER_PRIVATE_KEY']: child_env.pop(name,None)
        windows=temp/'windows'; windows.mkdir()
        for a in win['assets']: shutil.copy2(args.windows/a['name'],windows/a['name'])
        signed_windows=temp/'signed-windows'
        run('bash','scripts/sign_tauri_windows_release.sh','--version',version,'--repo',REPO,
            '--build-dir',windows,'--release-dir',signed_windows,'--key-path',keypaths[1],env=child_env)
        assembled=temp/'assembled'; assembled.mkdir()
        for a in mac['assets']: shutil.copy2(args.macos/a['name'],assembled/a['name'])
        for path in signed_windows.iterdir(): shutil.copy2(path,assembled/path.name)
        source=temp/'appcast-source'; source.mkdir()
        asset=f'CodexTokenBar-v{version}-macos-arm64.app.zip'
        shutil.copy2(assembled/asset,source/asset)
        notes=ROOT/f'release-notes/v{version}.md'
        shutil.copy2(notes,source/(asset[:-4]+'.md'))
        existing=temp/'appcast-existing.xml'; existing.write_bytes(base_xml)
        generated=temp/'appcast-generated.xml'
        tools=ROOT/'.build/artifacts/sparkle/Sparkle/bin'
        run(tools/'generate_appcast','--ed-key-file',keypaths[0],
            '--download-url-prefix',f'https://github.com/{REPO}/releases/download/v{version}/',
            '--embed-release-notes','--maximum-versions','5','-o',generated,source,env=child_env)
        run('python3','scripts/merge_appcast.py',version,generated,existing,assembled/'appcast.xml')
        run('node','scripts/merge_release_checksums.mjs','--version',version,'--release-dir',assembled,'--windows-arch','both')
        packet=temp/'packet'; packet.mkdir()
        for name in public_names(version)+['appcast.xml']: shutil.copy2(assembled/name,packet/name)
        shutil.copy2(windows/'build-manifest.json',packet/'windows-build-manifest.json')
        shutil.copy2(notes,packet/'release-notes.md')
        (packet/'appcast-baseline.json').write_text(json.dumps(baseline_info,indent=2)+'\n')
        manifest={'schema':1,'source_sha':sha,'version':version,'build_run_id':str(args.build_run),
          'ci_run_id':str(args.ci_run),'signing_run_id':os.environ['GITHUB_RUN_ID'],
          'update_signed':True,'public_release':False,'public_assets':public_names(version),
          'files':[{'name':p.name,'bytes':p.stat().st_size,'sha256':digest(p)} for p in sorted(packet.iterdir())]}
        (packet/'release-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        verify_packet(packet,sha)
        shutil.copytree(packet,args.output)
    print('Verified signed packet:',args.output,sha)

def main():
    parser=argparse.ArgumentParser()
    sub=parser.add_subparsers(dest='mode',required=True)
    p=sub.add_parser('sign')
    for name in ['macos','windows','ci-evidence','output']: p.add_argument('--'+name,type=pathlib.Path,required=True)
    for name in ['source-sha','build-run','ci-run']: p.add_argument('--'+name,required=True)
    p=sub.add_parser('verify'); p.add_argument('directory',type=pathlib.Path); p.add_argument('--source-sha')
    args=parser.parse_args()
    if args.mode=='sign': sign(args)
    else:
        data=verify_packet(args.directory,args.source_sha)
        print('Verified signed release packet',data['source_sha'],data['version'])

if __name__=='__main__': main()
