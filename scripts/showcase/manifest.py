#!/usr/bin/env python3
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json

root=Path(__file__).resolve().parents[2]
paths=sorted([p for p in (root/'Assets/showcase').iterdir() if p.is_file()]+[p for p in (root/'docs/showcase/demo').rglob('*') if p.is_file()])
manifest={
    'schemaVersion':1,
    'generatedAt':datetime.now(timezone.utc).isoformat(),
    'featureBaseline':'v0.9.7',
    'featureBaselineCommit':'e0440813d2c5131ad58be272af57951055005c2d',
    'data':'Synthetic public demonstration data; no user logs, credentials, or account readings.',
    'surfaces':'Production React components in an isolated web canvas. README state loops use editorial crossfades, not native window-motion recordings.',
    'cacheFilm':'Independent simulated Codex UI, original SwiftUI warning rendering, original procedural UI sound effects.',
    'license':'AGPL-3.0; repository MIT and Codex++ notices retained.',
    'assets':[{'file':p.relative_to(root).as_posix(),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths],
}
(root/'docs/showcase/asset-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(f'Manifest: {len(paths)} assets, {sum(p.stat().st_size for p in paths)} bytes')
