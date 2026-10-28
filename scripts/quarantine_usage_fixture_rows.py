#!/usr/bin/env python3
"""Quarantine explicitly proven fixture rows; preserve raw rows and revisions.

The manifest lists exact (client, event_id, row_sha256) keys, never model/date
heuristics. Dry-run is the default. A consistent backup precedes any mutation.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import sqlite3


def row_hash(row):
    return hashlib.sha256(json.dumps(list(row), ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


def quarantine(database, manifest, backup_directory, apply=False):
    database, backup_directory = Path(database).resolve(), Path(backup_directory).resolve()
    proof = json.loads(Path(manifest).read_text())
    keys = proof["rows"]
    if not keys or len({(r["client"], r["event_id"]) for r in keys}) != len(keys):
        raise ValueError("Empty or duplicate repair keys")
    repair_id = proof["repair_id"]
    if not isinstance(repair_id, str) or not repair_id:
        raise ValueError("Missing repair identity")
    con = sqlite3.connect(database.as_uri() + ("?mode=rw" if apply else "?mode=ro"), uri=True)
    try:
        if apply:
            backup_directory.mkdir(parents=True, exist_ok=False, mode=0o700)
            backup = sqlite3.connect(backup_directory / database.name)
            try:
                con.backup(backup)
                # A recovery copy must be a self-contained ordinary SQLite file.
                backup.execute("PRAGMA journal_mode=DELETE")
            finally:
                backup.close()
            (backup_directory / "proof.json").write_text(json.dumps(proof, ensure_ascii=False, indent=2))
        con.execute("BEGIN IMMEDIATE" if apply else "BEGIN")
        columns = [r[1] for r in con.execute("PRAGMA table_info(client_usage_events)")]
        quoted = ",".join('"' + c.replace('"', '""') + '"' for c in columns)
        verified = []
        for key in keys:
            row = con.execute(f"SELECT {quoted} FROM client_usage_events WHERE client=? AND event_id=?", (key["client"], key["event_id"])).fetchone()
            if row is None or row_hash(row) != key["row_sha256"]:
                raise ValueError("Repair proof no longer matches a stored row; nothing changed")
            verified.append(row)
        before = con.execute("SELECT COUNT(*) FROM client_usage_events").fetchone()[0]
        revision_count = con.execute("SELECT COUNT(*) FROM client_usage_revisions").fetchone()[0]
        if apply:
            con.execute("CREATE TABLE IF NOT EXISTS client_fixture_quarantine (repair_id TEXT NOT NULL, client TEXT NOT NULL, event_id TEXT NOT NULL, row_sha256 TEXT NOT NULL, row_json TEXT NOT NULL, quarantined_at TEXT NOT NULL, PRIMARY KEY(repair_id,client,event_id))")
            stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
            for key, row in zip(keys, verified):
                con.execute("INSERT INTO client_fixture_quarantine VALUES(?,?,?,?,?,?)", (repair_id, key["client"], key["event_id"], key["row_sha256"], json.dumps(dict(zip(columns, row)), ensure_ascii=False, separators=(",", ":")), stamp))
                count = con.execute("DELETE FROM client_usage_events WHERE client=? AND event_id=?", (key["client"], key["event_id"])).rowcount
                if count != 1:
                    raise ValueError("Unexpected repair delete count")
            if con.execute("SELECT COUNT(*) FROM client_usage_events").fetchone()[0] != before - len(keys):
                raise ValueError("Unrelated rows changed")
            if con.execute("SELECT COUNT(*) FROM client_usage_revisions").fetchone()[0] != revision_count:
                raise ValueError("Revision ledger changed")
            con.commit()
        else:
            con.rollback()
        result = {"repair_id": repair_id, "applied": apply, "verified_rows": len(keys), "before": before, "after": before - len(keys) if apply else before, "revision_rows_preserved": revision_count, "backup": str(backup_directory) if apply else None}
        if apply:
            (backup_directory / "result.json").write_text(json.dumps(result, indent=2))
        return result
    except BaseException:
        con.rollback()
        raise
    finally:
        con.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--backup-directory", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    print(json.dumps(quarantine(args.database, args.manifest, args.backup_directory, args.apply), indent=2))
