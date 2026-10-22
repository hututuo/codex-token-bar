#!/usr/bin/env python3
"""Validate local documentation links, public media, and the checked-in manifest."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote
import hashlib
import json
import re
import subprocess

ROOT=Path(__file__).resolve().parents[2]
errors=[]
files=[ROOT/p for p in ['README.md','README.en.md','README.zh-CN.md','docs/DEVELOPMENT.md','docs/showcase/README.md','docs/showcase/index.html','docs/showcase/demo/index.html']]
class Links(HTMLParser):
    def __init__(self):super().__init__();self.links=[]
    def handle_starttag(self,tag,attrs):
        self.links.extend(value for key,value in attrs if key in ['href','src'] and value)
for path in files:
    parser=Links();source=path.read_text();parser.feed(source)
    links=parser.links+re.findall(r'!?\[[^\]]*\]\(([^\s)]+)\)',source)
    for link in links:
        url=urlsplit(link)
        if url.scheme or url.netloc or not url.path:continue
        target=(path.parent/unquote(url.path)).resolve()
        if not target.exists():errors.append(f'{path.relative_to(ROOT)}: missing {link}')
media=[]
for path in sorted((ROOT/'Assets/showcase').glob('*')):
    if path.suffix not in ['.gif','.mp4']:continue
    probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_format','-show_streams','-of','json',str(path)]))
    video=next((s for s in probe['streams'] if s['codec_type']=='video'),None)
    if not video or int(video.get('nb_frames','2'))<2:errors.append(f'{path.name}: not animated')
    decode=subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(path),'-f','null','-'],capture_output=True,text=True)
    if decode.returncode:errors.append(f'{path.name}: decode failed {decode.stderr[:200]}')
    media.append({'file':path.relative_to(ROOT).as_posix(),'bytes':path.stat().st_size,'duration':probe['format'].get('duration'),'frames':video.get('nb_frames') if video else None,'decode':'PASS' if not decode.returncode else 'FAIL'})
manifest_path=ROOT/'docs/showcase/asset-manifest.json'
manifest=json.loads(manifest_path.read_text())
data=json.loads((ROOT/'tauri-app/showcase/real-data.json').read_text())
forbidden=re.compile(r'^(?:access_token|refresh_token|id_token|api_key|apiKey|password|authorization|client_secret|backendOrigin|canonicalHome|rollout_path|first_user_message|cwd)$',re.I)
def inspect(value,path='snapshot'):
    if isinstance(value,dict):
        for key,entry in value.items():
            if forbidden.fullmatch(key):errors.append(f'private field: {path}.{key}')
            inspect(entry,f'{path}.{key}')
    elif isinstance(value,list):
        for i,entry in enumerate(value):inspect(entry,f'{path}[{i}]')
    elif isinstance(value,str) and ('/Users/' in value or re.search(r'sk-[A-Za-z0-9_-]{24,}',value)):
        errors.append(f'private string: {path}')
inspect(data)
if data['days'][-1]['tokens']!=data['today']['totalTokens']:errors.append('daily total does not reconcile')
if sum(row['breakdown']['totalTokens'] for row in data['models'])!=data['today']['totalTokens']:errors.append('model totals do not reconcile')
if [len(data['recent'][key]) for key in ['recentUsage24h','recentUsage7d','recentUsage30d']]!=[288,168,120]:errors.append('incorrect history bucket counts')
if manifest['snapshot']['capturedAt']!=data['capturedAt']:errors.append('manifest snapshot time mismatch')
if "import './capture-clock';" not in (ROOT/'tauri-app/showcase/App.tsx').read_text() or "import './capture-clock';" not in (ROOT/'tauri-app/showcase/ProductSurface.tsx').read_text():errors.append('snapshot clock must anchor sample ages')
for name,digest in manifest.get('renderingSources',{}).items():
    if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=digest:errors.append(f'production rendering source changed: {name}')
host_css=(ROOT/'tauri-app/showcase/demo.css').read_text()
if re.search(r'\.qs-|\.floating-|--qs-|--floating-',host_css):
    errors.append('showcase host CSS must not override product selectors or appearance variables')
surface_source=(ROOT/'tauri-app/showcase/ProductSurface.tsx').read_text()
if './demo.css' in surface_source or 'previewMode' in surface_source:
    errors.append('product documents must use original styles and the complete non-preview floating surface')
for item in manifest['assets']:
    path=ROOT/item['file']
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=item['sha256']:errors.append(f'manifest mismatch: {item["file"]}')
print(json.dumps({'status':'FAIL' if errors else 'PASS','documents':len(files),'media':media,'errors':errors},ensure_ascii=False,indent=2))
raise SystemExit(bool(errors))
