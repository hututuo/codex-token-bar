-- A's container contract is shared by the Swift and Rust implementations.
-- Original stores are isolated by immutable store identity. Their original
-- schema/row IDs remain intact; table names alone receive a private prefix.
CREATE TABLE IF NOT EXISTS tb_container_meta (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
) WITHOUT ROWID;
INSERT OR IGNORE INTO tb_container_meta VALUES ('schema_version', '1');
CREATE TABLE IF NOT EXISTS tb_stores (
    store_id TEXT PRIMARY KEY NOT NULL,
    module TEXT NOT NULL,
    source_identity TEXT NOT NULL,
    logical_path TEXT NOT NULL UNIQUE,
    namespace_prefix TEXT NOT NULL UNIQUE,
    user_version INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL CHECK(state IN ('ready','staging','sealed')),
    revision INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS tb_store_imports (
    store_id TEXT NOT NULL REFERENCES tb_stores(store_id),
    source_digest TEXT NOT NULL,
    schema_digest TEXT NOT NULL,
    row_count INTEGER NOT NULL,
    rows_digest TEXT NOT NULL,
    backup_path TEXT NOT NULL,
    imported_at REAL NOT NULL,
    PRIMARY KEY(store_id,source_digest)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS tb_store_objects (
    store_id TEXT NOT NULL REFERENCES tb_stores(store_id),
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    original_sql TEXT,
    PRIMARY KEY(store_id,name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS tb_store_seals (
    store_id TEXT PRIMARY KEY NOT NULL REFERENCES tb_stores(store_id),
    byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
    row_count INTEGER NOT NULL CHECK(row_count >= 0),
    rows_digest TEXT NOT NULL,
    sealed_at REAL NOT NULL
) WITHOUT ROWID;
-- A legacy input receipt outlives an ephemeral job's tables. A completed job
-- must never be resurrected from its retained original file on the next boot.
CREATE TABLE IF NOT EXISTS tb_legacy_inputs (
    source_path TEXT PRIMARY KEY NOT NULL,
    logical_path TEXT NOT NULL,
    store_id TEXT NOT NULL,
    module TEXT NOT NULL,
    source_digest TEXT NOT NULL,
    backup_path TEXT NOT NULL,
    retired INTEGER NOT NULL DEFAULT 0 CHECK(retired IN (0,1))
) WITHOUT ROWID;
