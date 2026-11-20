import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("archive", Path(__file__).parents[1] / "archive_empty_ledger_stores.py")
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


class EmptyLedgerArchiveTests(unittest.TestCase):
    def seed(self, root):
        path = root / "ledger.sqlite"
        con = sqlite3.connect(path)
        con.executescript("""
        PRAGMA auto_vacuum=INCREMENTAL;
        PRAGMA user_version=1;
        CREATE TABLE tb_container_meta(key TEXT PRIMARY KEY,value TEXT) WITHOUT ROWID;
        INSERT INTO tb_container_meta VALUES('activation_state','ready');
        CREATE TABLE tb_stores(store_id TEXT PRIMARY KEY,module TEXT,namespace_prefix TEXT,logical_path TEXT,state TEXT) WITHOUT ROWID;
        CREATE TABLE tb_store_objects(store_id TEXT REFERENCES tb_stores,name TEXT);
        CREATE TABLE tb_store_imports(store_id TEXT REFERENCES tb_stores,receipt BLOB);
        CREATE TABLE tb_store_seals(store_id TEXT REFERENCES tb_stores,proof TEXT);
        CREATE TABLE tb_legacy_inputs(store_id TEXT,source_path TEXT);
        CREATE TABLE quota_history(id INTEGER PRIMARY KEY AUTOINCREMENT,value REAL,note BLOB);
        INSERT INTO quota_history VALUES(4,83.125,x'00ff');
        """)
        ids = ["a" * 64, "b" * 64, "c" * 64, "d" * 64]
        for index, store_id in enumerate(ids):
            prefix = "s" + store_id + "_"
            con.execute("INSERT INTO tb_stores VALUES(?,?,?,?,?)",
                        (store_id, "exact.swift", prefix, "/old/" + store_id, "ready"))
            con.execute("INSERT INTO tb_store_imports VALUES(?,?)", (store_id, b"receipt\x00\xff"))
            con.execute("INSERT INTO tb_legacy_inputs VALUES(?,?)", (store_id, "/old/" + store_id))
            for name, definition in [
                ("schema_meta", "(key TEXT PRIMARY KEY,value TEXT)"),
                ("sources", "(source_id INTEGER PRIMARY KEY,path TEXT)"),
                ("events", "(id INTEGER PRIMARY KEY AUTOINCREMENT,tokens INTEGER)"),
                ("retained_usage_events", "(evidence BLOB)"),
                ("session_catalog_entries", "(path TEXT)"),
            ]:
                con.execute("CREATE TABLE " + prefix + name + definition)
                con.execute("INSERT INTO tb_store_objects VALUES(?,?)", (store_id, name))
            con.execute("INSERT INTO " + prefix + "schema_meta(rowid,key,value) VALUES(17,'provenance_epoch',?)", ("epoch-" + str(index),))
            con.execute("CREATE INDEX " + prefix + "event_index ON " + prefix + "events(tokens)")
            con.execute("CREATE VIEW " + prefix + "projection AS SELECT * FROM " + prefix + "events")
        # A is truly empty; B has an original test catalog; C has retained
        # evidence despite an empty sources table; D has a real catalog only.
        con.execute("INSERT INTO s" + ids[0] + "_events VALUES(100,10)")
        con.execute("DELETE FROM s" + ids[0] + "_events")
        con.execute("INSERT INTO s" + ids[1] + "_session_catalog_entries VALUES(?)",
                    ("/var/folders/aa/bb/T/codex-token-bar-session-management-12345678-1234-1234-1234-123456789abc/sessions/test.jsonl",))
        con.execute("INSERT INTO s" + ids[2] + "_retained_usage_events(rowid,evidence) VALUES(37,x'00fe')")
        con.execute("INSERT INTO s" + ids[3] + "_session_catalog_entries VALUES('/Users/person/.codex/sessions/real.jsonl')")
        con.commit()
        con.execute("PRAGMA journal_mode=WAL")
        con.close()
        return path, ids

    def test_archive_preserves_live_rows_hidden_ids_receipts_and_can_restore(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            database, ids = self.seed(root)
            plan = archive.make_plan(database)
            self.assertEqual([s["store_id"] for s in plan["stores"]], ids[:2])
            manifest = root / "plan.json"
            manifest.write_text(json.dumps(plan))
            evidence = root / "archive"
            result = archive.apply_plan(database, manifest, evidence, enforce_offline=False)
            self.assertEqual(result["archived_store_count"], 2)
            self.assertLess(result["after_objects"], result["before_objects"])
            with sqlite3.connect(database) as con:
                self.assertEqual(con.execute("SELECT * FROM quota_history").fetchall(), [(4, 83.125, b"\x00\xff")])
                self.assertEqual(con.execute("SELECT rowid,evidence FROM s" + ids[2] + "_retained_usage_events").fetchall(), [(37, b"\x00\xfe")])
                self.assertEqual(con.execute("SELECT count(*) FROM tb_legacy_inputs").fetchone(), (4,))
                self.assertEqual(con.execute("PRAGMA user_version").fetchone(), (1,))
                con.execute("INSERT INTO quota_history(value,note) VALUES(42.5,x'01')")
                con.commit()
            with patch.object(archive, "assert_offline", return_value=open(root / "lock", "a+b")):
                archive.restore_stores(database, evidence / database.name, ids[:2])
            with sqlite3.connect(database) as con:
                self.assertEqual(con.execute("SELECT id,value FROM quota_history ORDER BY id").fetchall(), [(4, 83.125), (5, 42.5)])
                self.assertEqual(con.execute("SELECT rowid,key,value FROM s" + ids[0] + "_schema_meta").fetchall(), [(17, "provenance_epoch", "epoch-0")])
                self.assertEqual(con.execute("SELECT count(*) FROM tb_store_imports").fetchone(), (4,))
                self.assertEqual(con.execute("PRAGMA foreign_key_check").fetchall(), [])
                con.execute("INSERT INTO s" + ids[0] + "_events(tokens) VALUES(20)")
                self.assertEqual(con.execute("SELECT id FROM s" + ids[0] + "_events").fetchall(), [(101,)])

    def test_new_business_row_invalidates_plan_before_switch(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            database, ids = self.seed(root)
            manifest = root / "plan.json"
            manifest.write_text(json.dumps(archive.make_plan(database)))
            inode = database.stat().st_ino
            with sqlite3.connect(database) as con:
                con.execute("INSERT INTO s" + ids[0] + "_events VALUES(1,99)")
                con.commit()
            with self.assertRaisesRegex(ValueError, "proof no longer matches"):
                archive.apply_plan(database, manifest, root / "archive", enforce_offline=False)
            self.assertEqual(database.stat().st_ino, inode)
            with sqlite3.connect(database) as con:
                self.assertEqual(con.execute("SELECT tokens FROM s" + ids[0] + "_events").fetchall(), [(99,)])

    def test_candidate_failure_cannot_replace_original(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            database, _ = self.seed(root)
            manifest = root / "plan.json"
            manifest.write_text(json.dumps(archive.make_plan(database)))
            inode = database.stat().st_ino
            with patch.object(archive, "copy_selected", side_effect=OSError("injected disk full")):
                with self.assertRaisesRegex(OSError, "disk full"):
                    archive.apply_plan(database, manifest, root / "archive", enforce_offline=False)
            self.assertEqual(database.stat().st_ino, inode)
            with sqlite3.connect(database) as con:
                self.assertEqual(con.execute("PRAGMA quick_check").fetchall(), [("ok",)])
                self.assertEqual(con.execute("SELECT count(*) FROM tb_stores").fetchone(), (4,))


if __name__ == "__main__":
    unittest.main()
