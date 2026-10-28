import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("repair", Path(__file__).parents[1] / "quarantine_usage_fixture_rows.py")
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class QuarantineFixtureTests(unittest.TestCase):
    def seed(self, folder):
        db = folder / "usage.sqlite"
        con = sqlite3.connect(db)
        con.executescript("CREATE TABLE client_usage_events(client TEXT,event_id TEXT,payload TEXT,PRIMARY KEY(client,event_id)); CREATE TABLE client_usage_revisions(payload TEXT);")
        rows = [("claudeCode", "demo", '{"inputTokens":10}'), ("claudeCode", "real", '{"inputTokens":20}'), ("other", "demo", '{"inputTokens":30}')]
        con.executemany("INSERT INTO client_usage_events VALUES(?,?,?)", rows)
        con.execute("INSERT INTO client_usage_revisions VALUES('original')")
        con.commit()
        con.close()
        manifest = folder / "proof.json"
        manifest.write_text(json.dumps({"repair_id": "fixture-only", "rows": [{"client": rows[0][0], "event_id": rows[0][1], "row_sha256": repair.row_hash(rows[0])}]}))
        return db, manifest, rows

    def test_dry_run_then_atomic_quarantine_preserves_unrelated_rows_and_revisions(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            db, manifest, rows = self.seed(folder)
            self.assertEqual(repair.quarantine(db, manifest, folder / "dry")['after'], 3)
            self.assertFalse((folder / "dry").exists())
            result = repair.quarantine(db, manifest, folder / "backup", True)
            self.assertEqual(result['after'], 2)
            with sqlite3.connect(db) as con:
                self.assertEqual(con.execute("SELECT * FROM client_usage_events ORDER BY client,event_id").fetchall(), rows[1:])
                archived = json.loads(con.execute("SELECT row_json FROM client_fixture_quarantine").fetchone()[0])
                self.assertEqual(archived, dict(zip(['client', 'event_id', 'payload'], rows[0])))
                self.assertEqual(con.execute("SELECT * FROM client_usage_revisions").fetchall(), [('original',)])
            with sqlite3.connect(folder / "backup" / db.name) as con:
                self.assertEqual(con.execute("SELECT COUNT(*) FROM client_usage_events").fetchone()[0], 3)

    def test_stale_or_wrong_proof_changes_nothing(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            db, manifest, _ = self.seed(folder)
            proof = json.loads(manifest.read_text())
            proof['rows'][0]['row_sha256'] = 'wrong'
            manifest.write_text(json.dumps(proof))
            with self.assertRaisesRegex(ValueError, 'no longer matches'):
                repair.quarantine(db, manifest, folder / "backup", True)
            with sqlite3.connect(db) as con:
                self.assertEqual(con.execute("SELECT COUNT(*) FROM client_usage_events").fetchone()[0], 3)


if __name__ == '__main__':
    unittest.main()
