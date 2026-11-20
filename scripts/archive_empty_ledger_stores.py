#!/usr/bin/env python3
"""Offline, reversible removal of proven empty/test schemas from the hot ledger.

Plan first. Apply requires that exact plan, an inactive application and a new
evidence directory. Every source row remains in the original rollback database;
kept tables are copied with hidden rowids and checked before the atomic switch.
Never infer emptiness from one table, a filename, a date or a missing source.
"""
import argparse
import base64
import collections
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time

CATALOG_FILTERS = {"tb_stores", "tb_store_objects", "tb_store_imports", "tb_store_seals"}
EXACT_METADATA = {"schema_meta", "retained_usage_meta", "session_catalog_meta", "usage_ledger_meta"}
TEST_ROOT = re.compile(r"/(?:private/)?var/folders/[^/]+/[^/]+/T/"
                       r"codex-token-bar-session-management-[0-9A-Fa-f-]{36}/(?:sessions|archived_sessions)/")


def quote(name):
    return '"' + name.replace('"', '""') + '"'


def read_only(path):
    con = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True, timeout=10)
    con.execute("PRAGMA query_only=ON")
    return con


def encoded(value):
    if isinstance(value, bytes):
        return {"blob": base64.b64encode(value).decode("ascii")}
    if isinstance(value, float):
        return {"float": value.hex()}
    return value


def digest_rows(rows):
    digest = hashlib.sha256()
    count = 0
    for row in rows:
        digest.update(json.dumps([encoded(v) for v in row], ensure_ascii=True,
                                 separators=(",", ":")).encode())
        digest.update(b"\n")
        count += 1
    return {"count": count, "sha256": digest.hexdigest()}


def schema(con):
    return con.execute("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name").fetchall()


def table_projection(con, name):
    columns = con.execute("PRAGMA table_xinfo(" + quote(name) + ")").fetchall()
    names = [r[1] for r in columns if r[6] == 0]
    declaration = con.execute("SELECT sql FROM sqlite_schema WHERE name=?", (name,)).fetchone()[0]
    if "WITHOUT ROWID" not in declaration.upper():
        alias = next((v for v in ("rowid", "_rowid_", "oid") if v not in names), None)
        if alias is None:
            raise ValueError("Hidden rowid is inaccessible: " + name)
        return [alias] + names, quote(alias)
    key = [r[1] for r in sorted(columns, key=lambda r: r[5]) if r[5] > 0]
    return names, ",".join(map(quote, key))


def table_rows(con, name, exclude=()):
    columns, order = table_projection(con, name)
    where, params = "", []
    if exclude and name in CATALOG_FILTERS:
        where = " WHERE store_id NOT IN (" + ",".join("?" for _ in exclude) + ")"
        params = list(exclude)
    return con.execute("SELECT " + ",".join(map(quote, columns)) + " FROM " + quote(name)
                       + where + " ORDER BY " + order, params)


def eligible_stores(con):
    objects = collections.defaultdict(list)
    for entry in schema(con):
        name = entry[2]
        if re.match(r"^s[0-9a-f]{64}_", name):
            objects[name[:66]].append(entry)
    result = []
    for row in con.execute("SELECT store_id,module,namespace_prefix,logical_path,state FROM tb_stores ORDER BY store_id"):
        store_id, module, prefix, path, state = row
        if module not in ("exact.swift", "body.swift") or state != "ready":
            continue
        owned = objects[prefix]
        tables = [entry[1] for entry in owned if entry[0] == "table"]
        logical = {name[len(prefix):] for name in tables}
        required = {"sources", "events", "schema_meta"} if module == "exact.swift" else {
            "speed_samples", "speed_sample_ids", "speed_5m", "speed_trend_meta"}
        if not required.issubset(logical):
            continue
        nonempty = {}
        allowed = EXACT_METADATA if module == "exact.swift" else {"speed_trend_meta"}
        is_fixture = False
        valid = True
        for name in tables:
            count = con.execute("SELECT count(*) FROM " + quote(name)).fetchone()[0]
            if not count:
                continue
            suffix = name[len(prefix):]
            nonempty[suffix] = count
            if suffix in allowed:
                continue
            if module == "exact.swift" and suffix == "session_catalog_entries":
                paths = con.execute("SELECT path FROM " + quote(name)).fetchall()
                if paths and all(TEST_ROOT.match(p[0]) for p in paths):
                    is_fixture = True
                    continue
            valid = False
            break
        if not valid:
            continue
        # Nonempty schema metadata is preserved in the rollback, including
        # provenance epochs and migration receipts. No populated ledger table
        # is eligible, even if its current raw source has disappeared.
        proof = {
            "schema": digest_rows(owned),
            "tables": {name: digest_rows(table_rows(con, name)) for name in tables},
        }
        result.append({"store_id": store_id, "module": module, "prefix": prefix,
                       "logical_path": path, "nonempty": nonempty,
                       "reason": "verified_test_catalog" if is_fixture else "no_business_rows",
                       "proof": proof})
    return result


def make_plan(database):
    path = Path(database).resolve()
    with read_only(path) as con:
        con.execute("BEGIN")
        if con.execute("SELECT value FROM tb_container_meta WHERE key='activation_state'").fetchone() != ("ready",):
            raise ValueError("Migration is not ready")
        if con.execute("SELECT 1 FROM tb_container_meta WHERE key IN ('migration_pending_sources_v1','published_business_admission_v1')").fetchone():
            raise ValueError("Pending recovery must finish before archival")
        stores = eligible_stores(con)
        plan = {"format": 1, "database": str(path), "inode": path.stat().st_ino,
                "schema": digest_rows(schema(con)), "stores": stores,
                "created_at": time.time()}
        con.rollback()
        return plan


def assert_offline(database):
    lines = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
    if any(Path(line.strip()).name == "CodexTokenBar" for line in lines):
        raise ValueError("Quit Token Bar normally before applying the archive")
    # The app owns this existing writer lock. Holding it keeps a new launch
    # from racing the candidate construction and atomic switch.
    lock = open(str(database) + ".writer.lock", "a+b")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BaseException:
        lock.close()
        raise
    return lock


def copy_selected(source, candidate, excluded):
    entries = schema(source)
    prefixes = {"s" + store_id + "_" for store_id in excluded}
    keep = [entry for entry in entries if not any(entry[2].startswith(p) for p in prefixes)]
    destination = sqlite3.connect(candidate)
    try:
        destination.execute("PRAGMA page_size=" + str(source.execute("PRAGMA page_size").fetchone()[0]))
        destination.execute("PRAGMA auto_vacuum=" + str(source.execute("PRAGMA auto_vacuum").fetchone()[0]))
        destination.execute("PRAGMA journal_mode=DELETE")
        destination.execute("PRAGMA foreign_keys=OFF")
        destination.execute("BEGIN IMMEDIATE")
        tables = [entry for entry in keep if entry[0] == "table" and not entry[1].startswith("sqlite_")]
        for _, name, _, sql in tables:
            if sql is None or "CREATE VIRTUAL TABLE" in sql.upper():
                raise ValueError("Unsupported table definition: " + name)
            destination.execute(sql)
        for _, name, _, _ in tables:
            columns, _ = table_projection(source, name)
            insertion = "INSERT INTO " + quote(name) + "(" + ",".join(map(quote, columns)) + ") VALUES(" + ",".join("?" for _ in columns) + ")"
            cursor = table_rows(source, name, excluded)
            while rows := cursor.fetchmany(1024):
                destination.executemany(insertion, rows)
        if any(entry[1] == "sqlite_sequence" for entry in keep):
            destination.execute("DELETE FROM sqlite_sequence")
            for name, seq in source.execute("SELECT name,seq FROM sqlite_sequence"):
                if not any(name.startswith(p) for p in prefixes):
                    destination.execute("INSERT INTO sqlite_sequence VALUES(?,?)", (name, seq))
        for kind in ("index", "view", "trigger"):
            for actual_kind, name, _, sql in keep:
                if actual_kind == kind and sql is not None:
                    destination.execute(sql)
        for key in ("user_version", "application_id"):
            destination.execute("PRAGMA " + key + "=" + str(source.execute("PRAGMA " + key).fetchone()[0]))
        destination.commit()
        if destination.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise ValueError("Candidate integrity failed")
        if destination.execute("PRAGMA foreign_key_check").fetchone():
            raise ValueError("Candidate foreign keys failed")
        if schema(destination) != keep:
            raise ValueError("Candidate schema differs outside archived namespaces")
        proofs = {}
        for _, name, _, _ in tables:
            expected = digest_rows(table_rows(source, name, excluded))
            actual = digest_rows(table_rows(destination, name))
            if expected != actual:
                raise ValueError("Candidate data or rowid differs: " + name)
            proofs[name] = expected
        if any(entry[1] == "sqlite_sequence" for entry in keep):
            expected = [(n, v) for n, v in source.execute("SELECT name,seq FROM sqlite_sequence ORDER BY name")
                        if not any(n.startswith(p) for p in prefixes)]
            if destination.execute("SELECT name,seq FROM sqlite_sequence ORDER BY name").fetchall() != expected:
                raise ValueError("Autoincrement sequence changed")
        return {"before_objects": len(entries), "after_objects": len(keep), "kept_tables": proofs}
    finally:
        destination.close()


def apply_plan(database, manifest, evidence, enforce_offline=True):
    path = Path(database).resolve()
    expected = json.loads(Path(manifest).read_text())
    if expected["format"] != 1 or expected["database"] != str(path) or expected["inode"] != path.stat().st_ino:
        raise ValueError("Plan targets a different database identity")
    proof_dir = Path(evidence).resolve()
    proof_dir.mkdir(parents=True, exist_ok=False)
    lock = assert_offline(path) if enforce_offline else None
    candidate = path.with_name("." + path.name + ".archive-candidate")
    rollback = proof_dir / path.name
    if candidate.exists() or rollback.exists():
        raise ValueError("Candidate or rollback already exists")
    try:
        # Recheck every selected row and object from the live database.
        actual = make_plan(path)
        actual_by_id = {s["store_id"]: s for s in actual["stores"]}
        if actual["schema"] != expected["schema"] or not expected["stores"]:
            raise ValueError("Schema changed or plan is empty")
        for store in expected["stores"]:
            if actual_by_id.get(store["store_id"]) != store:
                raise ValueError("Archived store proof no longer matches")
        excluded = sorted({s["store_id"] for s in expected["stores"]})
        if len(excluded) != len(expected["stores"]):
            raise ValueError("Duplicate store selection")
        # No app is running and the writer admission lock is held. Finish WAL
        # before preserving the original as one self-contained rollback file.
        checkpoint = sqlite3.connect(path)
        try:
            if checkpoint.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0] != 0:
                raise ValueError("A database reader or writer is still active")
            if checkpoint.execute("PRAGMA journal_mode=DELETE").fetchone()[0] != "delete":
                raise ValueError("Unable to seal original WAL")
        finally:
            checkpoint.close()
        with read_only(path) as source:
            source.execute("BEGIN")
            result = copy_selected(source, candidate, excluded)
            source.rollback()
        os.chmod(candidate, path.stat().st_mode & 0o777)
        with candidate.open("rb") as stream:
            os.fsync(stream.fileno())
        if make_plan(path)["stores"] != actual["stores"]:
            raise ValueError("Source changed while building candidate")
        (proof_dir / "plan.json").write_text(json.dumps(expected, indent=2) + "\n")
        result.update({"archived_store_count": len(excluded), "source_inode": path.stat().st_ino,
                       "rollback": str(rollback), "created_at": time.time()})
        (proof_dir / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
        path.rename(rollback)
        try:
            candidate.rename(path)
        except BaseException:
            rollback.rename(path)
            raise
        for directory in (path.parent, proof_dir):
            fd = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        return result
    finally:
        if lock:
            lock.close()


def restore_stores(database, archive, store_ids):
    """Merge selected archived stores back without rolling back newer history."""
    path, archive = Path(database).resolve(), Path(archive).resolve()
    lock = assert_offline(path)
    try:
        source = read_only(archive)
        destination = sqlite3.connect(path)
        try:
            selected = set(store_ids)
            found = {r[0] for r in source.execute("SELECT store_id FROM tb_stores")}
            if not selected or not selected.issubset(found):
                raise ValueError("Unknown archived store selection")
            if any(destination.execute("SELECT 1 FROM tb_stores WHERE store_id=?", (i,)).fetchone() for i in selected):
                raise ValueError("Restore would replace a current owner")
            prefixes = {"s" + i + "_" for i in selected}
            entries = [e for e in schema(source) if any(e[2].startswith(p) for p in prefixes)]
            destination.execute("PRAGMA foreign_keys=OFF")
            destination.execute("BEGIN IMMEDIATE")
            for kind in ("table", "index", "view", "trigger"):
                for actual_kind, name, _, sql in entries:
                    if actual_kind != kind or sql is None:
                        continue
                    destination.execute(sql)
                    if kind == "table":
                        columns, _ = table_projection(source, name)
                        destination.executemany("INSERT INTO " + quote(name) + "(" + ",".join(map(quote, columns))
                            + ") VALUES(" + ",".join("?" for _ in columns) + ")", table_rows(source, name))
            for table in CATALOG_FILTERS:
                columns = [r[1] for r in source.execute("PRAGMA table_info(" + quote(table) + ")")]
                rows = source.execute("SELECT * FROM " + quote(table) + " WHERE store_id IN ("
                                      + ",".join("?" for _ in selected) + ")", sorted(selected))
                destination.executemany("INSERT INTO " + quote(table) + " VALUES("
                                        + ",".join("?" for _ in columns) + ")", rows)
            if destination.execute("PRAGMA foreign_key_check").fetchone():
                raise ValueError("Restored ownership failed verification")
            for kind, name, _, _ in entries:
                if kind == "table" and digest_rows(table_rows(source, name)) != digest_rows(table_rows(destination, name)):
                    raise ValueError("Restored data differs")
            destination.commit()
        finally:
            source.close()
            destination.close()
    finally:
        lock.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["plan", "apply", "restore"])
    parser.add_argument("--database", required=True)
    parser.add_argument("--manifest")
    parser.add_argument("--evidence")
    parser.add_argument("--archive")
    parser.add_argument("--store-id", action="append")
    args = parser.parse_args()
    if args.mode == "plan":
        plan = make_plan(args.database)
        Path(args.manifest).write_text(json.dumps(plan, indent=2) + "\n")
        print(json.dumps({"eligible": len(plan["stores"]), "reasons": dict(collections.Counter(s["reason"] for s in plan["stores"]))}))
    elif args.mode == "apply":
        result = apply_plan(args.database, args.manifest, args.evidence)
        print(json.dumps({k: v for k, v in result.items() if k != "kept_tables"}, indent=2))
    else:
        restore_stores(args.database, args.archive, args.store_id or [])
        print("Selected archived stores restored; current unrelated history preserved")
