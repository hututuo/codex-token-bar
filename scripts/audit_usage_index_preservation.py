#!/usr/bin/env python3
"""Read-only comparison of SQLite backup snapshots; emits counts, never log text."""
import argparse
import json
import pathlib
import sqlite3


def compare(before: pathlib.Path, after: pathlib.Path) -> dict:
    with sqlite3.connect(after.resolve().as_uri() + '?mode=ro', uri=True) as db:
        db.execute('ATTACH DATABASE ? AS baseline', (before.resolve().as_uri() + '?mode=ro',))
        db.execute('PRAGMA query_only=ON')
        columns = [row[1] for row in db.execute('PRAGMA baseline.table_info(events)')]
        current = {row[1] for row in db.execute('PRAGMA main.table_info(events)')}
        missing_columns = sorted(set(columns) - current)
        if missing_columns:
            raise ValueError(f'Missing historical event columns: {missing_columns}')
        # Column names come from the SQLite catalog, not caller-supplied SQL.
        quote = lambda name: '"' + name.replace('"', '""') + '"'
        join = 'n.source_id=b.source_id AND n.source_offset=b.source_offset'
        missing = db.execute(f'SELECT COUNT(*) FROM baseline.events b LEFT JOIN main.events n ON {join} WHERE n.source_id IS NULL').fetchone()[0]
        changed = {}
        for column in columns:
            if column in ('source_id', 'source_offset'):
                continue
            count = db.execute(f'SELECT COUNT(*) FROM baseline.events b JOIN main.events n ON {join} WHERE b.{quote(column)} IS NOT n.{quote(column)}').fetchone()[0]
            if count:
                changed[column] = count
        owners = db.execute('''
            SELECT COUNT(*) FROM baseline.sources b JOIN main.sources n USING(source_id)
            WHERE lower(b.session_id) IS NOT lower(n.session_id)
              AND EXISTS(SELECT 1 FROM baseline.events e WHERE e.source_id=b.source_id)
        ''').fetchone()[0]
        counts = lambda schema: db.execute(f'SELECT COUNT(*),COALESCE(SUM(tokens),0) FROM {schema}.events').fetchone()
        old_count, old_tokens = counts('baseline')
        new_count, new_tokens = counts('main')
        quick_check = db.execute('PRAGMA main.quick_check').fetchone()[0]
        return dict(status='PASS' if not (missing or changed or owners) and quick_check == 'ok' else 'FAIL',
                    before_events=old_count, after_events=new_count,
                    before_tokens=old_tokens, after_tokens=new_tokens,
                    missing_events=missing, changed_event_columns=changed,
                    changed_source_owners=owners, quick_check=quick_check)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=pathlib.Path)
    parser.add_argument('after', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    report = compare(args.before, args.after)
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(text + '\n')
        args.output.chmod(0o600)
    print(text)
    raise SystemExit(report['status'] != 'PASS')


if __name__ == '__main__':
    main()
