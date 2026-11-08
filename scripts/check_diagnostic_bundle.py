#!/usr/bin/env python3
"""Exercise a built standalone collector against isolated, locked private bait."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import uuid
import zipfile


def inventory(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--helper',type=Path,required=True)
    parser.add_argument('--platform',choices=['macos','windows'],required=True)
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tokenbar-diagnostic-gate-') as directory:
        root=Path(directory).resolve();home=root/'private-home';home.mkdir()
        if args.platform=='macos':
            support=home/'Library/Application Support/CodexTokenBar'
            journal=support/'diagnostics/v1'
        else:
            support=home/'AppData/Roaming/CodexTokenBarTauri'
            journal=home/'AppData/Local/CodexTokenBar/diagnostics/v1'
        support.mkdir(parents=True,exist_ok=True);journal.mkdir(parents=True,exist_ok=True)
        secret='sk-diagnostic-secret-'+str(uuid.uuid4())
        (home/'auth.json').write_text(json.dumps({'api_key':secret,'conversation':'PRIVATE_CHAT_BODY'}))
        event={'schema':1,'session':str(uuid.uuid4()),'sequence':1,'at':1000,'area':'refresh','phase':'failed',
            'version':'0.9.11','build':'997','metrics':{'code':5,'password':123},
            'path':str(home),'authorization':secret,'message':'PRIVATE_CHAT_BODY'}
        (journal/'events-fixture.jsonl').write_text(json.dumps(event)+'\n')
        connection=sqlite3.connect(support/'codex-ledger.sqlite')
        connection.execute('CREATE TABLE private_chat(body TEXT)')
        connection.execute('INSERT INTO private_chat VALUES(?)',(secret,));connection.commit()
        connection.execute('BEGIN EXCLUSIVE')
        try:
            before=inventory(home);output=root/'diagnostics.zip';started=time.monotonic()
            run=subprocess.run([str(args.helper.resolve()),'--export-diagnostics','--diagnostics-home',str(home),
                '--output',str(output)],capture_output=True,text=True,timeout=35)
            assert run.returncode==0, 'Standalone export failed (details intentionally omitted)'
            assert inventory(home)==before,'Collector changed source files or created product state'
            with zipfile.ZipFile(output) as archive:
                assert archive.testzip() is None
                assert {'SUMMARY.md','manifest.json','state/storage.json','events/events.jsonl'}<=set(archive.namelist())
                for name in archive.namelist():
                    assert '..' not in Path(name).parts and not name.startswith(('/', '\\'))
                    text=archive.read(name).decode('utf8')
                    assert secret not in text and str(home) not in text and 'PRIVATE_CHAT_BODY' not in text
                    assert '"password"' not in text
                events=[json.loads(line) for line in archive.read('events/events.jsonl').splitlines()]
                assert any(row.get('metrics',{}).get('code')==5 for row in events),'Safe error evidence was lost'
                assert json.loads(archive.read('state/storage.json'))['databaseQueriesPerformed'] is False
            previous=output.read_bytes()
            refused=subprocess.run([str(args.helper.resolve()),'--export-diagnostics','--diagnostics-home',str(home),
                '--output',str(output)],capture_output=True,timeout=35)
            assert refused.returncode!=0 and output.read_bytes()==previous,'Existing archive was overwritten'
            print(json.dumps({'status':'PASS','platform':args.platform,'sourceUnchanged':True,
                'exclusiveSQLiteLockHeld':True,'secretBaitsAbsent':True,'safeErrorRetained':True,
                'existingOutputPreserved':True,'seconds':round(time.monotonic()-started,3)}))
        finally:
            connection.rollback();connection.close()


if __name__=='__main__':main()
