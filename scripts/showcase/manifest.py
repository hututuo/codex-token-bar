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
    'data':'Owner-authorized real local statistics snapshot. No credentials, raw conversations, local paths or auth/routing fields. Instantaneous activity rate is unavailable and its placeholder is disclosed. The separate cache film remains a simulated scenario.',
    'snapshot':{key:json.loads((root/'tauri-app/showcase/real-data.json').read_text())[key] for key in ['capturedAt','usageDataUpdatedAt']},
    'surfaces':'Production cross-platform React rendering subtrees and unchanged production CSS in isolated iframe documents. Complete existing DetailSurface; full default FloatingPanelSurface, not preview mode. Native geometry constants are extracted at build time. README loops are editorial state crossfades, not native window-motion recordings.',
    'renderingSources':{name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in [
        'tauri-app/src/quota-sidebar/QuotaSidebarApp.tsx',
        'tauri-app/src/quota-sidebar/QuotaSidebar.css',
        'tauri-app/src/styles/global.css',
        'tauri-app/src/floating/FloatingPanelPreview.tsx',
        'tauri-app/src/floating/floatingSettings.ts',
        'tauri-app/src-tauri/src/platform/quota_sidebar.rs',
        'tauri-app/src-tauri/src/platform/quota_sidebar/canvas_metrics.rs',
    ]},
    'cacheFilm':'Independent simulated Codex UI, original SwiftUI warning rendering, original procedural UI sound effects.',
    'license':'AGPL-3.0; repository MIT and Codex++ notices retained.',
    'assets':[{'file':p.relative_to(root).as_posix(),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths],
}
(root/'docs/showcase/asset-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(f'Manifest: {len(paths)} assets, {sum(p.stat().st_size for p in paths)} bytes')
