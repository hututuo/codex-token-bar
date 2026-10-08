"""Observe actual packaged app indexes; never manufacture a schema13 database."""
import datetime, hashlib, json, os, pathlib, sqlite3, sys, time
support = pathlib.Path(os.environ['APPDATA'])
evidence = pathlib.Path('upgrade-evidence')
mode = sys.argv[1]
if mode == 'fixture':
    settings = support / 'CodexTokenBar' / 'settings.json'
    if settings.exists():
        raise SystemExit('Fresh hosted runner unexpectedly contains application settings')
    home = pathlib.Path(os.environ['TOKENBAR_UPGRADE_HOME'])
    sessions = home / 'sessions'
    sessions.mkdir(parents=True)
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    ident = '019ff8b9-09e7-75c1-b9a5-14fe7b60065a'
    usage = {'input_tokens':80, 'cached_input_tokens':0, 'output_tokens':20, 'reasoning_output_tokens':0, 'total_tokens':100}
    lines = [
        {'timestamp': timestamp, 'type': 'session_meta', 'payload': {'id':ident,'timestamp':timestamp,'cwd':str(home),'model_provider':'openai'}},
        {'timestamp': timestamp, 'type': 'turn_context', 'payload': {'model':'gpt-6.1-sol'}},
        {'timestamp': timestamp, 'type':'event_msg', 'payload':{'type':'token_count','info':{'total_token_usage':usage,'last_token_usage':usage}}},
    ]
    (sessions / f'rollout-{ident}.jsonl').write_text('\n'.join(json.dumps(x) for x in lines)+'\n', encoding='utf-8')
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text(json.dumps({'codex_home':str(home),'floating_enabled':False}), encoding='utf-8')
    print('Prepared synthetic JSONL and normal production settings; no index copied or synthesized')
    raise SystemExit(0)
expected = '13' if mode == 'before' else '14'
deadline = time.monotonic() + 75
last = ''
while time.monotonic() < deadline:
    try:
        paths = list((support / 'CodexTokenBarTauri' / 'exact-token-index').glob('*.sqlite3'))
        if len(paths) != 1:
            raise RuntimeError(f'Expected one actual index, got {len(paths)}')
        with sqlite3.connect(paths[0].as_uri()+'?mode=ro', uri=True) as db:
            schema = db.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()[0]
            if schema != expected:
                raise RuntimeError(f'Index schema {schema}, expected {expected}')
            columns = [x[1] for x in db.execute('PRAGMA table_info(events)')]
            rows = db.execute('SELECT * FROM events ORDER BY id').fetchall()
            total = db.execute('SELECT SUM(tokens) FROM events').fetchone()[0]
            if total != 100 or not rows:
                raise RuntimeError(f'Synthetic token total {total}, expected 100')
            # Serialize only generated numeric/index rows, never real user bodies.
            snapshot = {'schema':schema,'columns':columns,'rows':rows,'tokens':total,'path':str(paths[0])}
            if mode == 'after':
                before = json.loads((evidence/'index-before.json').read_text(encoding='utf-8'))
                if columns != before['columns'] or [list(r) for r in rows] != before['rows']:
                    raise RuntimeError('Migration changed existing event columns or values')
                if str(paths[0]) != before['path']:
                    raise RuntimeError('Migration moved the active index')
                backup = db.execute("SELECT value FROM metadata WHERE key='representation_upgrade_backup'").fetchone()
                if not backup:
                    raise RuntimeError('Representation upgrade has no backup receipt')
                with sqlite3.connect(pathlib.Path(backup[0]).as_uri()+'?mode=ro',uri=True) as saved:
                    if saved.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()[0] != '13':
                        raise RuntimeError('Backup is not original schema13')
                    if saved.execute('SELECT * FROM events ORDER BY id').fetchall() != rows:
                        raise RuntimeError('Backup does not preserve original event rows')
                snapshot['backup_schema13_preserved'] = True
            (evidence/f'index-{mode}.json').write_text(json.dumps(snapshot,indent=2)+'\n',encoding='utf-8')
            print(f'PASS actual packaged schema{schema}, synthetic total100, {len(rows)} event rows')
            break
    except (sqlite3.Error, RuntimeError, TypeError) as error:
        last = str(error)
        time.sleep(2)
else:
    raise SystemExit('Actual packaged index validation failed: '+last)
