#!/usr/bin/env python3
"""Read historical Rust stage producers; execute their DDL only in memory.

This is a schema audit, not a native parser/migration validation. No repository
source or user database is modified. The JSON includes exact SQLite contracts
and original DDL, avoiding a hand-written optional-column cross product.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SOURCE = "tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs"
OUTPUT = ROOT / "docs/recovery/2026-11-02/rust-historical-stage-contracts.json"


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip("\n")


def extract(ref: str) -> tuple[str, dict[str, str | None]] | None:
    source = git("show", f"{ref}:{SOURCE}")
    match = re.search(r"CREATE (?:\{create_table\}|TABLE(?: IF NOT EXISTS)?|TEMP TABLE) manifest", source)
    if match is None:
        return None
    start = source.rfind('r#"', 0, match.start())
    end = source.index('"#', match.end())
    assert start >= 0
    ddl = source[start + 3 : end].replace("{create_table}", "TABLE")
    constants = {}
    for name in ["STAGING_MANIFEST_SCHEMA_VERSION", "STAGED_FULL_REBUILD_PARSER_REVISION", "EXACT_SESSION_PARSER_REVISION", "STAGING_MANIFEST_INTEGRITY", "EVENT_ENRICHMENT_REVISION"]:
        definition = re.search(r"\bconst\s+" + name + r"\s*:[^=]+?=\s*([^;]+);", source)
        constants[name] = definition.group(1).strip() if definition else None
    return ddl, constants


def describe(ddl: str) -> dict:
    with sqlite3.connect(":memory:") as db:
        db.executescript(ddl)
        objects = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
        tables = {}
        for table in ["manifest", "events", "fingerprints", "chunks"]:
            info = db.execute(f'PRAGMA table_xinfo("{table}")').fetchall()
            indexes = []
            for seq, name, unique, origin, partial in db.execute(f'PRAGMA index_list("{table}")'):
                indexes.append({"name": name, "unique": unique, "origin": origin, "partial": partial,
                    "xinfo": db.execute(f'PRAGMA index_xinfo("{name}")').fetchall()})
            definition = next(row[3] for row in objects if row[0] == "table" and row[1] == table)
            tables[table] = {"columns": [dict(zip(["cid", "name", "type", "notnull", "default", "pk", "hidden"], row)) for row in info],
                "without_rowid": "WITHOUT ROWID" in definition,
                "foreign_keys": db.execute(f'PRAGMA foreign_key_list("{table}")').fetchall(),
                "indexes": indexes, "sql": definition}
        return {"ddl": ddl, "objects": [dict(zip(["type", "name", "table", "sql"], row)) for row in objects], "tables": tables}


def main() -> None:
    tags = [f"v0.9.{number}" for number in range(1, 12)]
    revisions = git("log", "--format=%H", "v0.9.11", "--", SOURCE).splitlines()
    layouts: dict[str, dict] = {}
    for ref in revisions:
        extracted = extract(ref)
        if extracted is None:
            continue
        ddl, constants = extracted
        digest = hashlib.sha256(ddl.encode()).hexdigest()
        if digest not in layouts:
            layouts[digest] = {"ddl_sha256": digest, **describe(ddl), "producer_commits": [], "release_tags": []}
        layouts[digest]["producer_commits"].append({"commit": ref,
            "subject": git("show", "-s", "--format=%s", ref), "constants": constants})
    releases = []
    for tag in tags:
        ddl, constants = extract(tag)
        digest = hashlib.sha256(ddl.encode()).hexdigest()
        commit = git("rev-parse", tag + "^{commit}")
        releases.append({"tag": tag, "commit": commit, "source_blob": git("rev-parse", tag + ":" + SOURCE),
            "ddl_sha256": digest, "constants": constants})
        layouts[digest]["release_tags"].append(tag)
    report = {"scope": "Local v0.9.1-v0.9.11 tags plus all reachable exact-index producer revisions through v0.9.11",
        "source_path": SOURCE, "sqlite_version": sqlite3.sqlite_version,
        "native_executed": False, "producer_revisions_checked": len(revisions),
        "notes": ["ddl_sha256 hashes the extracted SQL after replacing {create_table} with TABLE; it is not Rust StoreProof.schema_digest.",
            "PRAGMA observations were produced with in-memory SQLite, not old Rust binaries.",
            "Do not combine optional columns across distinct producer layouts; order is part of the contract.",
            "Shapes that predate a complete manifest identity are evidence for preservation, not automatic permission to import or seal."],
        "releases": releases, "layouts": list(layouts.values())}
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"output": str(OUTPUT), "releases": len(releases), "producer_revisions": len(revisions), "layouts": len(layouts)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
