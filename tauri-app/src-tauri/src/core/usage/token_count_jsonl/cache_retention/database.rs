//! Independent, durable cache-retention evidence store.
//!
//! This sidecar never writes the exact token ledger. Checkpoints, current
//! pairs, and own-turn identities publish atomically; replacing a source
//! generation archives its previous evidence before updating the current
//! projection.

use super::super::session_parser::cache_retention_parser::{Pair, Parser, Point};
use super::{Checkpoint, Snapshot};
use rusqlite::types::Value;
use rusqlite::{
    params, params_from_iter, Connection, OpenFlags, OptionalExtension, Transaction,
    TransactionBehavior,
};
use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

const SCHEMA_VERSION: i64 = 2;
const MAXIMUM_SNAPSHOT_POINTS: i64 = 100_001;
const DAY_MICROSECONDS: i64 = 86_400_000_000;

const REQUIRED_SCHEMA_OBJECTS: &[&str] = &[
    "retention_meta",
    "retention_sources",
    "retention_pairs",
    "retention_own_turns",
    "retention_generation_history",
    "retention_pair_history",
    "retention_own_turn_history",
    "retention_all_pairs",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct SourceSummary {
    pub(crate) fingerprint: String,
    pub(crate) session: String,
    pub(crate) is_child: bool,
    pub(crate) explicit_child: bool,
}

pub(crate) struct Database {
    path: PathBuf,
    connection: Connection,
}

impl Database {
    pub(crate) fn open_read_only(path: &Path) -> Result<Self, String> {
        let connection = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
        )
        .map_err(sqlite_error)?;
        connection
            .busy_timeout(Duration::from_millis(150))
            .map_err(sqlite_error)?;
        let version: i64 = connection
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(sqlite_error)?;
        if version != SCHEMA_VERSION {
            return Err(unsupported_version());
        }
        validate_v2_schema(&connection)?;
        Ok(Self {
            path: path.to_path_buf(),
            connection,
        })
    }

    pub(crate) fn open(path: impl AsRef<Path>) -> Result<Self, String> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("create retention directory: {error}"))?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
                    .map_err(|error| format!("secure retention directory: {error}"))?;
            }
        }

        // Validate before opening a writable connection. Unknown future files
        // and damaged v2 stores must remain untouched rather than being
        // partially recreated by `CREATE TABLE IF NOT EXISTS`.
        let version = if path.exists() {
            let read_only = Connection::open_with_flags(
                &path,
                OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
            )
            .map_err(sqlite_error)?;
            read_only
                .busy_timeout(Duration::from_millis(150))
                .map_err(sqlite_error)?;
            let version: i64 = read_only
                .pragma_query_value(None, "user_version", |row| row.get(0))
                .map_err(sqlite_error)?;
            if version > SCHEMA_VERSION {
                return Err(unsupported_version());
            }
            if version == SCHEMA_VERSION {
                validate_v2_schema(&read_only)?;
            }
            version
        } else {
            0
        };

        // Use an owner-only file from its creation on Unix. SQLite then opens
        // the already-created empty file and initializes its page header.
        if !path.exists() {
            create_private_file(&path)?;
        }

        let mut connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
        )
        .map_err(sqlite_error)?;
        connection
            .busy_timeout(Duration::from_millis(150))
            .map_err(sqlite_error)?;
        connection
            .execute_batch(
                "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;",
            )
            .map_err(sqlite_error)?;

        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sqlite_error)?;
        install_schema(&transaction, version)?;
        transaction
            .pragma_update(None, "user_version", SCHEMA_VERSION)
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        set_private_file_permissions(&path)?;

        Ok(Self { path, connection })
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn summaries(&self) -> Result<HashMap<String, SourceSummary>, String> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT source_key,fingerprint,session_key,is_child,explicit_child,present FROM retention_sources;",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([], |row| {
                let source_key: String = row.get(0)?;
                let fingerprint: String = row.get(1)?;
                let present: i64 = row.get(5)?;
                Ok((
                    source_key,
                    SourceSummary {
                        fingerprint: if present == 1 {
                            fingerprint
                        } else {
                            String::new()
                        },
                        session: row.get(2)?,
                        is_child: row.get::<_, i64>(3)? == 1,
                        explicit_child: row.get::<_, i64>(4)? == 1,
                    },
                ))
            })
            .map_err(sqlite_error)?;
        rows.collect::<rusqlite::Result<HashMap<_, _>>>()
            .map_err(sqlite_error)
    }

    pub(crate) fn checkpoint(&self, key: &str) -> Result<Option<Checkpoint>, String> {
        let bytes: Option<Vec<u8>> = self
            .connection
            .query_row(
                "SELECT checkpoint FROM retention_sources WHERE source_key=?1;",
                [key],
                |row| row.get(0),
            )
            .optional()
            .map_err(sqlite_error)?;
        bytes
            .map(|bytes| serde_json::from_slice(&bytes).map_err(json_error))
            .transpose()
    }

    pub(crate) fn publish(
        &self,
        key: &str,
        fingerprint: &str,
        checkpoint: &Checkpoint,
    ) -> Result<(), String> {
        let parser = &checkpoint.parser;
        let pairs = parser.pairs(key, &checkpoint.generation);
        let encoded_checkpoint = serde_json::to_vec(checkpoint).map_err(json_error)?;
        let own_rounds = i64::try_from(parser.own_turn_count())
            .map_err(|_| "cache-retention own-turn count overflow".to_owned())?;
        let own_projection = own_turn_projection(parser, own_rounds)?;

        // Prepare every JSON value before opening the transaction so that a
        // serialization failure cannot leave any part of a publication behind.
        let encoded_pairs = pairs
            .iter()
            .map(encode_pair)
            .collect::<Result<Vec<_>, _>>()?;

        let transaction =
            Transaction::new_unchecked(&self.connection, TransactionBehavior::Immediate)
                .map_err(sqlite_error)?;
        let previous_generation: Option<String> = transaction
            .query_row(
                "SELECT generation FROM retention_sources WHERE source_key=?1;",
                [key],
                |row| row.get(0),
            )
            .optional()
            .map_err(sqlite_error)?;

        if previous_generation
            .as_deref()
            .is_some_and(|generation| generation != checkpoint.generation)
        {
            archive_current_generation(&transaction, key)?;
        }

        transaction
            .execute(
                "INSERT INTO retention_sources(
                    source_key,fingerprint,session_key,is_child,explicit_child,own_rounds,generation,checkpoint,present,fallback_own_rounds
                 ) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,1,?9)
                 ON CONFLICT(source_key) DO UPDATE SET
                    fingerprint=excluded.fingerprint,
                    session_key=excluded.session_key,
                    is_child=excluded.is_child,
                    explicit_child=excluded.explicit_child,
                    own_rounds=excluded.own_rounds,
                    generation=excluded.generation,
                    checkpoint=excluded.checkpoint,
                    present=1,
                    fallback_own_rounds=excluded.fallback_own_rounds;",
                params![
                    key,
                    fingerprint,
                    parser.session_key,
                    if parser.excluded_subagent { 1_i64 } else { 0_i64 },
                    if parser.explicit_subagent { 1_i64 } else { 0_i64 },
                    own_rounds,
                    checkpoint.generation,
                    encoded_checkpoint,
                    own_projection.fallback_count,
                ],
            )
            .map_err(sqlite_error)?;

        transaction
            .execute(
                "DELETE FROM retention_own_turns WHERE source_key=?1;",
                [key],
            )
            .map_err(sqlite_error)?;
        if let Some(session_key) = own_projection.session_key.as_deref() {
            for turn_id in &own_projection.stable_turn_ids {
                transaction
                    .execute(
                        "INSERT OR IGNORE INTO retention_own_turns(source_key,session_key,turn_id) VALUES(?1,?2,?3);",
                        params![key, session_key, turn_id],
                    )
                    .map_err(sqlite_error)?;
            }
        }

        transaction
            .execute("DELETE FROM retention_pairs WHERE source_key=?1;", [key])
            .map_err(sqlite_error)?;
        {
            let mut statement = transaction
                .prepare(
                    "INSERT INTO retention_pairs(
                        pair_key,source_key,stable_key,evidence_signature,eligible,model,started_us,point,reasons
                     ) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9);",
                )
                .map_err(sqlite_error)?;
            for encoded in &encoded_pairs {
                statement
                    .execute(params![
                        encoded.pair.id,
                        key,
                        encoded.stable_key,
                        encoded.pair.evidence_signature,
                        if encoded.pair.eligible() {
                            1_i64
                        } else {
                            0_i64
                        },
                        encoded.point.as_ref().map(|point| point.model.as_str()),
                        encoded
                            .point
                            .as_ref()
                            .map(|point| point.started_at_microseconds),
                        encoded.point_bytes,
                        encoded.reasons_bytes,
                    ])
                    .map_err(sqlite_error)?;
            }
        }

        transaction
            .execute(
                "UPDATE retention_meta SET revision=revision+1 WHERE id=1;",
                [],
            )
            .map_err(sqlite_error)?;
        set_private_sidecar_permissions(&self.path)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    pub(crate) fn remove_missing(&self, keys: &HashSet<String>) -> Result<(), String> {
        let currently_present: HashSet<String> = {
            let mut statement = self
                .connection
                .prepare("SELECT source_key FROM retention_sources WHERE present=1;")
                .map_err(sqlite_error)?;
            let rows = statement
                .query_map([], |row| row.get(0))
                .map_err(sqlite_error)?;
            rows.collect::<rusqlite::Result<HashSet<_>>>()
                .map_err(sqlite_error)?
        };
        let missing: Vec<String> = currently_present.difference(keys).cloned().collect();
        if missing.is_empty() {
            return Ok(());
        }

        let transaction =
            Transaction::new_unchecked(&self.connection, TransactionBehavior::Immediate)
                .map_err(sqlite_error)?;
        for key in &missing {
            // Missing is only a presence transition. Keep pair facts,
            // checkpoints, and own-turn identities for the snapshot and a
            // later restoration.
            transaction
                .execute(
                    "UPDATE retention_sources SET present=0 WHERE source_key=?1 AND present=1;",
                    [key],
                )
                .map_err(sqlite_error)?;
        }
        transaction
            .execute(
                "UPDATE retention_meta SET revision=revision+1 WHERE id=1;",
                [],
            )
            .map_err(sqlite_error)?;
        set_private_sidecar_permissions(&self.path)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    pub(crate) fn snapshot(
        &self,
        days: Option<u32>,
        model: Option<&str>,
        now: i64,
    ) -> Result<Snapshot, String> {
        // Match Swift's single read transaction so a concurrent publish cannot
        // mix points from one revision with counts or model values from another.
        let transaction =
            Transaction::new_unchecked(&self.connection, TransactionBehavior::Deferred)
                .map_err(sqlite_error)?;
        let mut conditions = vec!["p.eligible=1".to_owned()];
        let mut bindings = Vec::<Value>::new();
        if let Some(model) = model {
            conditions.push("p.model=?".to_owned());
            bindings.push(Value::Text(model.to_owned()));
        }
        if let Some(days) = days {
            let duration = i64::from(days).saturating_mul(DAY_MICROSECONDS);
            conditions.push("p.started_us>=?".to_owned());
            bindings.push(Value::Integer(now.saturating_sub(duration)));
        }
        // Stable UUID evidence conflicts invalidate every copy. Identical
        // copies retain the deterministic minimum pair key as representative.
        conditions.push(
            "(p.stable_key IS NULL OR (
                NOT EXISTS(
                    SELECT 1 FROM retention_all_pairs q
                    WHERE q.stable_key=p.stable_key AND q.evidence_signature<>p.evidence_signature
                )
                AND p.pair_key=(
                    SELECT MIN(q.pair_key) FROM retention_all_pairs q
                    WHERE q.stable_key=p.stable_key AND q.eligible=1
                )
            ))"
            .to_owned(),
        );
        let sql = format!(
            "SELECT p.point FROM retention_all_pairs p WHERE {} ORDER BY p.started_us,p.pair_key LIMIT {};",
            conditions.join(" AND "),
            MAXIMUM_SNAPSHOT_POINTS,
        );
        let point_bytes = {
            let mut statement = transaction.prepare(&sql).map_err(sqlite_error)?;
            let rows = statement
                .query_map(params_from_iter(bindings), |row| row.get::<_, Vec<u8>>(0))
                .map_err(sqlite_error)?;
            rows.collect::<rusqlite::Result<Vec<_>>>()
                .map_err(sqlite_error)?
        };
        let points = point_bytes
            .iter()
            .map(|bytes| serde_json::from_slice::<Point>(bytes).map_err(json_error))
            .collect::<Result<Vec<_>, _>>()?;

        let models = {
            let mut statement = transaction
                .prepare(
                    "SELECT DISTINCT model FROM retention_all_pairs WHERE eligible=1 AND model IS NOT NULL ORDER BY model;",
                )
                .map_err(sqlite_error)?;
            let rows = statement
                .query_map([], |row| row.get(0))
                .map_err(sqlite_error)?;
            rows.collect::<rusqlite::Result<Vec<String>>>()
                .map_err(sqlite_error)?
        };

        let revision: i64 = transaction
            .query_row(
                "SELECT revision FROM retention_meta WHERE id=1;",
                [],
                |row| row.get(0),
            )
            .map_err(sqlite_error)?;
        let own_round_count: i64 = transaction
            .query_row(OWN_ROUND_COUNT_SQL, [], |row| row.get(0))
            .map_err(sqlite_error)?;
        let source_count = points
            .iter()
            .map(|point| point.source_key.as_str())
            .collect::<HashSet<_>>()
            .len();

        let snapshot = Snapshot {
            points,
            models,
            source_count,
            own_round_count,
            revision,
            failures: 0,
            updated_at_microseconds: now,
        };
        transaction.commit().map_err(sqlite_error)?;
        Ok(snapshot)
    }
}

const OWN_ROUND_COUNT_SQL: &str = r#"
    SELECT
      (SELECT COALESCE(SUM(s.fallback_own_rounds),0)
       FROM retention_sources s WHERE s.is_child=0)
      + (SELECT COALESCE(SUM(g.fallback_own_rounds),0)
         FROM retention_generation_history g
         JOIN retention_sources s ON s.source_key=g.source_key
         WHERE s.is_child=0 AND g.is_child=0 AND g.generation<>s.generation)
      + (SELECT COUNT(*) FROM (
           SELECT DISTINCT session_key,turn_id FROM (
             SELECT o.session_key,o.turn_id
             FROM retention_own_turns o
             JOIN retention_sources s ON s.source_key=o.source_key
             WHERE s.is_child=0
             UNION ALL
             SELECT h.session_key,h.turn_id
             FROM retention_own_turn_history h
             JOIN retention_generation_history g
               ON g.source_key=h.source_key AND g.generation=h.generation
             JOIN retention_sources s ON s.source_key=h.source_key
             WHERE s.is_child=0 AND g.is_child=0 AND g.generation<>s.generation
           ) AS all_turns
         ));
"#;

struct OwnTurnProjection {
    session_key: Option<String>,
    stable_turn_ids: Vec<String>,
    fallback_count: i64,
}

struct EncodedPair<'a> {
    pair: &'a Pair,
    stable_key: Option<String>,
    point: Option<&'a Point>,
    point_bytes: Option<Vec<u8>>,
    reasons_bytes: Vec<u8>,
}

fn encode_pair(pair: &Pair) -> Result<EncodedPair<'_>, String> {
    Ok(EncodedPair {
        pair,
        stable_key: pair.stable_key(),
        point: pair.point.as_ref(),
        point_bytes: pair
            .point
            .as_ref()
            .map(serde_json::to_vec)
            .transpose()
            .map_err(json_error)?,
        reasons_bytes: serde_json::to_vec(&pair.reasons).map_err(json_error)?,
    })
}

fn own_turn_projection(
    parser: &Parser,
    fallback_if_ambiguous: i64,
) -> Result<OwnTurnProjection, String> {
    if parser.excluded_subagent {
        return Ok(OwnTurnProjection {
            session_key: None,
            stable_turn_ids: Vec::new(),
            fallback_count: 0,
        });
    }
    let session_identity_is_unambiguous = parser.metadata_seen
        && !parser.session_key.is_empty()
        && !parser.source_flags.contains("missing_session_identity")
        && !parser.source_flags.contains("multiple_session_metadata");
    if !session_identity_is_unambiguous {
        return Ok(OwnTurnProjection {
            session_key: None,
            stable_turn_ids: Vec::new(),
            fallback_count: fallback_if_ambiguous,
        });
    }

    let (stable_turn_ids, fallback_turn_ordinals) = parser.own_turn_identities();
    let mut stable_turn_ids = stable_turn_ids
        .into_iter()
        .collect::<HashSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    stable_turn_ids.sort();
    let fallback_count = i64::try_from(fallback_turn_ordinals.len())
        .map_err(|_| "cache-retention fallback own-turn count overflow".to_owned())?;
    Ok(OwnTurnProjection {
        session_key: Some(parser.session_key.clone()),
        stable_turn_ids,
        fallback_count,
    })
}

fn archive_current_generation(transaction: &Transaction<'_>, key: &str) -> Result<(), String> {
    transaction
        .execute(
            "INSERT OR IGNORE INTO retention_generation_history(
                source_key,generation,checkpoint,own_rounds,fallback_own_rounds,is_child
             ) SELECT source_key,generation,checkpoint,own_rounds,fallback_own_rounds,is_child
               FROM retention_sources WHERE source_key=?1;",
            [key],
        )
        .map_err(sqlite_error)?;
    transaction
        .execute(
            "INSERT OR IGNORE INTO retention_pair_history(
                pair_key,source_key,generation,stable_key,evidence_signature,eligible,model,started_us,point,reasons
             ) SELECT p.pair_key,p.source_key,s.generation,p.stable_key,p.evidence_signature,
                      p.eligible,p.model,p.started_us,p.point,p.reasons
               FROM retention_pairs p
               JOIN retention_sources s ON s.source_key=p.source_key
               WHERE p.source_key=?1;",
            [key],
        )
        .map_err(sqlite_error)?;
    transaction
        .execute(
            "INSERT OR IGNORE INTO retention_own_turn_history(source_key,generation,session_key,turn_id)
             SELECT o.source_key,s.generation,o.session_key,o.turn_id
             FROM retention_own_turns o
             JOIN retention_sources s ON s.source_key=o.source_key
             WHERE o.source_key=?1;",
            [key],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

fn install_schema(transaction: &Transaction<'_>, version: i64) -> Result<(), String> {
    transaction
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS retention_meta(id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL);
             INSERT INTO retention_meta(id,revision) VALUES(1,0) ON CONFLICT(id) DO NOTHING;
             CREATE TABLE IF NOT EXISTS retention_sources(
               source_key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, session_key TEXT NOT NULL,
               is_child INTEGER NOT NULL, explicit_child INTEGER NOT NULL, own_rounds INTEGER NOT NULL, generation TEXT NOT NULL,
               checkpoint BLOB NOT NULL, present INTEGER NOT NULL DEFAULT 1,
               fallback_own_rounds INTEGER NOT NULL DEFAULT 0);",
        )
        .map_err(sqlite_error)?;

    let source_columns = table_columns(transaction, "retention_sources").map_err(sqlite_error)?;
    if !source_columns.contains("present") {
        if version >= SCHEMA_VERSION {
            return Err(unsupported_version());
        }
        transaction
            .execute_batch(
                "ALTER TABLE retention_sources ADD COLUMN present INTEGER NOT NULL DEFAULT 1;",
            )
            .map_err(sqlite_error)?;
    }
    if !source_columns.contains("fallback_own_rounds") {
        if version >= SCHEMA_VERSION {
            return Err(unsupported_version());
        }
        transaction
            .execute_batch(
                "ALTER TABLE retention_sources ADD COLUMN fallback_own_rounds INTEGER NOT NULL DEFAULT 0;",
            )
            .map_err(sqlite_error)?;
    }

    transaction
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS retention_pairs(
               pair_key TEXT PRIMARY KEY, source_key TEXT NOT NULL REFERENCES retention_sources(source_key) ON DELETE CASCADE,
               stable_key TEXT, evidence_signature TEXT NOT NULL, eligible INTEGER NOT NULL,
               model TEXT, started_us INTEGER, point BLOB, reasons BLOB NOT NULL);
             CREATE INDEX IF NOT EXISTS retention_pair_identity ON retention_pairs(stable_key,evidence_signature,eligible,pair_key);
             CREATE INDEX IF NOT EXISTS retention_pair_time ON retention_pairs(started_us,pair_key) WHERE eligible=1;
             CREATE INDEX IF NOT EXISTS retention_pair_model ON retention_pairs(model,started_us,pair_key) WHERE eligible=1;
             CREATE TABLE IF NOT EXISTS retention_own_turns(
               source_key TEXT NOT NULL REFERENCES retention_sources(source_key) ON DELETE CASCADE,
               session_key TEXT NOT NULL, turn_id TEXT NOT NULL,
               PRIMARY KEY(source_key,session_key,turn_id));
             CREATE INDEX IF NOT EXISTS retention_own_turn_identity ON retention_own_turns(session_key,turn_id);
             CREATE TABLE IF NOT EXISTS retention_generation_history(
               source_key TEXT NOT NULL REFERENCES retention_sources(source_key), generation TEXT NOT NULL,
               checkpoint BLOB NOT NULL, own_rounds INTEGER NOT NULL, fallback_own_rounds INTEGER NOT NULL,
               is_child INTEGER NOT NULL, PRIMARY KEY(source_key,generation));
             CREATE TABLE IF NOT EXISTS retention_pair_history(
               pair_key TEXT PRIMARY KEY, source_key TEXT NOT NULL, generation TEXT NOT NULL,
               stable_key TEXT, evidence_signature TEXT NOT NULL, eligible INTEGER NOT NULL,
               model TEXT, started_us INTEGER, point BLOB, reasons BLOB NOT NULL);
             CREATE INDEX IF NOT EXISTS retention_pair_history_source ON retention_pair_history(source_key,generation);
             CREATE INDEX IF NOT EXISTS retention_pair_history_identity ON retention_pair_history(stable_key,evidence_signature,eligible,pair_key);
             CREATE INDEX IF NOT EXISTS retention_pair_history_time ON retention_pair_history(started_us,pair_key) WHERE eligible=1;
             CREATE INDEX IF NOT EXISTS retention_pair_history_model ON retention_pair_history(model,started_us,pair_key) WHERE eligible=1;
             CREATE TABLE IF NOT EXISTS retention_own_turn_history(
               source_key TEXT NOT NULL, generation TEXT NOT NULL,
               session_key TEXT NOT NULL, turn_id TEXT NOT NULL,
               PRIMARY KEY(source_key,generation,session_key,turn_id));
             CREATE INDEX IF NOT EXISTS retention_own_turn_history_identity ON retention_own_turn_history(session_key,turn_id);
             CREATE VIEW IF NOT EXISTS retention_all_pairs AS
               SELECT p.pair_key,p.source_key,s.generation,p.stable_key,p.evidence_signature,
                      p.eligible,p.model,p.started_us,p.point,p.reasons
               FROM retention_pairs p
               JOIN retention_sources s ON s.source_key=p.source_key
               WHERE s.is_child=0
               UNION ALL
               SELECT h.pair_key,h.source_key,h.generation,h.stable_key,h.evidence_signature,
                      h.eligible,h.model,h.started_us,h.point,h.reasons
               FROM retention_pair_history h
               JOIN retention_generation_history g
                 ON g.source_key=h.source_key AND g.generation=h.generation
               JOIN retention_sources s ON s.source_key=h.source_key
               WHERE s.is_child=0 AND g.is_child=0 AND g.generation<>s.generation;",
        )
        .map_err(sqlite_error)?;

    if version < SCHEMA_VERSION {
        backfill_own_turn_projection(transaction)?;
    }
    Ok(())
}

fn backfill_own_turn_projection(transaction: &Transaction<'_>) -> Result<(), String> {
    let rows = {
        let mut statement = transaction
            .prepare("SELECT source_key,is_child,own_rounds,checkpoint FROM retention_sources;")
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)? == 1,
                    row.get::<_, i64>(2)?,
                    row.get::<_, Vec<u8>>(3)?,
                ))
            })
            .map_err(sqlite_error)?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(sqlite_error)?
    };

    for (source_key, is_child, stored_count, checkpoint_bytes) in rows {
        let projection = if is_child {
            OwnTurnProjection {
                session_key: None,
                stable_turn_ids: Vec::new(),
                fallback_count: 0,
            }
        } else if let Ok(checkpoint) = serde_json::from_slice::<Checkpoint>(&checkpoint_bytes) {
            own_turn_projection(&checkpoint.parser, stored_count)?
        } else {
            OwnTurnProjection {
                session_key: None,
                stable_turn_ids: Vec::new(),
                fallback_count: stored_count,
            }
        };

        transaction
            .execute(
                "UPDATE retention_sources SET fallback_own_rounds=?1 WHERE source_key=?2;",
                params![projection.fallback_count, source_key],
            )
            .map_err(sqlite_error)?;
        if let Some(session_key) = projection.session_key.as_deref() {
            for turn_id in projection.stable_turn_ids {
                transaction
                    .execute(
                        "INSERT OR IGNORE INTO retention_own_turns(source_key,session_key,turn_id) VALUES(?1,?2,?3);",
                        params![source_key, session_key, turn_id],
                    )
                    .map_err(sqlite_error)?;
            }
        }
    }
    Ok(())
}

fn table_columns(connection: &Connection, table: &str) -> rusqlite::Result<HashSet<String>> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table});"))?;
    let columns = statement
        .query_map([], |row| row.get(1))?
        .collect::<rusqlite::Result<HashSet<_>>>()?;
    Ok(columns)
}

fn validate_v2_schema(connection: &Connection) -> Result<(), String> {
    let mut statement = connection
        .prepare("SELECT name FROM sqlite_master WHERE type IN ('table','view');")
        .map_err(sqlite_error)?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(sqlite_error)?
        .collect::<rusqlite::Result<HashSet<_>>>()
        .map_err(sqlite_error)?;
    if REQUIRED_SCHEMA_OBJECTS
        .iter()
        .all(|name| names.contains(*name))
    {
        Ok(())
    } else {
        Err(unsupported_version())
    }
}

fn create_private_file(path: &Path) -> Result<(), String> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    match options.open(path) {
        Ok(file) => {
            drop(file);
            Ok(())
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(()),
        Err(error) => Err(format!("create retention database: {error}")),
    }
}

fn set_private_file_permissions(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("secure retention database: {error}"))?;
    }
    set_private_sidecar_permissions(path)
}

fn set_private_sidecar_permissions(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for suffix in ["-wal", "-shm"] {
            let sidecar = PathBuf::from(format!("{}{suffix}", path.display()));
            if sidecar.exists() {
                fs::set_permissions(sidecar, fs::Permissions::from_mode(0o600))
                    .map_err(|error| format!("secure retention sidecar: {error}"))?;
            }
        }
    }
    Ok(())
}

fn unsupported_version() -> String {
    "续问建议数据库版本暂不支持，原有用量统计不受影响。".to_owned()
}

fn sqlite_error(error: rusqlite::Error) -> String {
    format!("cache-retention database error: {error}")
}

fn json_error(error: serde_json::Error) -> String {
    format!("cache-retention JSON error: {error}")
}

#[cfg(test)]
mod tests {
    use super::super::super::session_parser::cache_retention_parser::REVISION as PARSER_REVISION;
    use super::*;
    use rusqlite::Connection;
    use serde_json::{json, Value as JsonValue};
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TEMP_ID: AtomicU64 = AtomicU64::new(1);

    const SESSION_ID: &str = "019ff8b9-1111-7000-8000-000000000099";
    const TURN_A: &str = "019ff8b9-0ace-7c02-9f89-4358b15cceda";
    const TURN_B: &str = "019ff8b9-0acf-7c02-9f89-4358b15cceda";
    const TURN_C: &str = "019ff8b9-0ad0-7c02-9f89-4358b15cceda";

    struct TemporaryDatabase {
        root: PathBuf,
        path: PathBuf,
    }

    impl TemporaryDatabase {
        fn new(label: &str) -> Self {
            let id = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "cache-retention-{label}-{}-{id}",
                std::process::id()
            ));
            fs::create_dir_all(&root).unwrap();
            Self {
                path: root.join("retention.sqlite"),
                root,
            }
        }
    }

    impl Drop for TemporaryDatabase {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn make_checkpoint(
        generation: &str,
        next_first_cached: i64,
        include_third: bool,
    ) -> Checkpoint {
        let mut parser = Parser::new(None);
        let known_subagents = HashSet::new();
        parser.consume(
            &serde_json::to_vec(&json!({
                "type":"session_meta",
                "payload":{"id":SESSION_ID}
            }))
            .unwrap(),
            &known_subagents,
        );
        let mut records = turn_records(TURN_A, 1_700_000_000, (100, 80), (100, 95));
        records.extend(turn_records(
            TURN_B,
            1_700_000_220,
            (100, next_first_cached),
            (100, 99),
        ));
        if include_third {
            records.extend(turn_records(TURN_C, 1_700_000_440, (100, 85), (100, 98)));
        }
        for record in records {
            parser.consume(&serde_json::to_vec(&record).unwrap(), &known_subagents);
        }
        Checkpoint {
            generation: generation.to_owned(),
            offset: 123,
            prefix_digest: format!("digest-{generation}"),
            parser,
            parser_revision: PARSER_REVISION.to_owned(),
        }
    }

    fn turn_records(id: &str, start: i64, first: (i64, i64), last: (i64, i64)) -> Vec<JsonValue> {
        let usage = |input, cached| json!({"input_tokens":input,"cached_input_tokens":cached});
        vec![
            json!({"ordinal":start,"timestamp":start,"type":"event_msg","payload":{"type":"task_started","turn_id":id,"started_at":start}}),
            json!({"ordinal":start+1,"timestamp":start+1,"type":"response_item","payload":{"type":"message","role":"user"}}),
            json!({"ordinal":start+2,"timestamp":start+2,"type":"turn_context","payload":{"turn_id":id,"model":"gpt-6.1-sol"}}),
            json!({"ordinal":start+3,"timestamp":start+3,"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":usage(first.0,first.1),"total_token_usage":{"total_tokens":1000+start}}}}),
            json!({"ordinal":start+4,"timestamp":start+4,"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":usage(last.0,last.1),"total_token_usage":{"total_tokens":1001+start}}}}),
            json!({"ordinal":start+5,"timestamp":start+6,"type":"event_msg","payload":{"type":"task_complete","turn_id":id,"completed_at":start+6}}),
        ]
    }

    fn scalar(connection: &Connection, sql: &str) -> i64 {
        connection.query_row(sql, [], |row| row.get(0)).unwrap()
    }

    #[test]
    fn creates_schema_v2_and_fails_closed_for_damaged_or_future_databases() {
        let fixture = TemporaryDatabase::new("schema");
        let database = Database::open(&fixture.path).unwrap();
        assert_eq!(
            database
                .connection
                .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
                .unwrap(),
            2
        );
        drop(database);

        let damaged = Connection::open(&fixture.path).unwrap();
        damaged
            .execute_batch("DROP TABLE retention_pair_history;")
            .unwrap();
        drop(damaged);
        assert!(Database::open(&fixture.path).is_err());
        let still_damaged = Connection::open(&fixture.path).unwrap();
        assert_eq!(
            scalar(
                &still_damaged,
                "SELECT COUNT(*) FROM sqlite_master WHERE name='retention_pair_history';",
            ),
            0,
        );
        drop(still_damaged);

        let future = TemporaryDatabase::new("future");
        let newer = Connection::open(&future.path).unwrap();
        newer.pragma_update(None, "user_version", 3).unwrap();
        drop(newer);
        assert!(Database::open(&future.path).is_err());
        let unchanged = Connection::open(&future.path).unwrap();
        assert_eq!(scalar(&unchanged, "PRAGMA user_version;"), 3);
    }

    #[test]
    fn publication_snapshot_missing_transition_and_restore_keep_checkpoint_and_facts() {
        let fixture = TemporaryDatabase::new("publish");
        let database = Database::open(&fixture.path).unwrap();
        let checkpoint = make_checkpoint("generation-a", 90, false);
        database
            .publish("source-a", "fingerprint-a", &checkpoint)
            .unwrap();

        let stored = database.checkpoint("source-a").unwrap().unwrap();
        assert_eq!(stored.generation, "generation-a");
        assert_eq!(stored.offset, 123);
        assert_eq!(stored.prefix_digest, "digest-generation-a");
        let summary = database.summaries().unwrap().remove("source-a").unwrap();
        assert_eq!(summary.fingerprint, "fingerprint-a");
        assert_eq!(summary.session, checkpoint.parser.session_key);
        assert!(!summary.is_child);
        assert!(!summary.explicit_child);

        let before = database
            .snapshot(None, None, 1_700_001_000_000_000)
            .unwrap();
        assert_eq!(before.points.len(), 1);
        assert_eq!(before.models, vec!["gpt-6.1-sol"]);
        assert_eq!(before.source_count, 1);
        assert_eq!(before.own_round_count, 2);
        assert_eq!(before.revision, 1);

        database.remove_missing(&HashSet::new()).unwrap();
        let removed_summary = database.summaries().unwrap().remove("source-a").unwrap();
        assert!(removed_summary.fingerprint.is_empty());
        let after_removal = database
            .snapshot(None, None, 1_700_001_000_000_000)
            .unwrap();
        assert_eq!(after_removal.points, before.points);
        assert_eq!(after_removal.own_round_count, before.own_round_count);
        assert_eq!(
            database.checkpoint("source-a").unwrap().unwrap().generation,
            "generation-a"
        );

        database
            .publish("source-a", "fingerprint-restored", &checkpoint)
            .unwrap();
        let restored = database
            .snapshot(None, None, 1_700_001_000_000_000)
            .unwrap();
        assert_eq!(restored.points, before.points);
        assert_eq!(restored.own_round_count, 2);
        assert_eq!(restored.revision, 3);
        assert_eq!(
            database.summaries().unwrap()["source-a"].fingerprint,
            "fingerprint-restored"
        );
    }

    #[test]
    fn generation_replacement_archives_checkpoint_pairs_and_own_turns_atomically() {
        let fixture = TemporaryDatabase::new("history");
        let database = Database::open(&fixture.path).unwrap();
        let first = make_checkpoint("generation-a", 90, false);
        database
            .publish("source-a", "fingerprint-a", &first)
            .unwrap();
        let second = make_checkpoint("generation-b", 90, true);
        database
            .publish("source-a", "fingerprint-b", &second)
            .unwrap();

        assert_eq!(
            database.checkpoint("source-a").unwrap().unwrap().generation,
            "generation-b"
        );
        assert_eq!(
            database
                .connection
                .query_row(
                    "SELECT COUNT(*) FROM retention_generation_history;",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            1
        );
        assert_eq!(
            database
                .connection
                .query_row("SELECT COUNT(*) FROM retention_pair_history;", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            1
        );
        assert_eq!(
            database
                .connection
                .query_row(
                    "SELECT COUNT(*) FROM retention_own_turn_history;",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            2
        );
        let snapshot = database
            .snapshot(None, None, 1_700_001_000_000_000)
            .unwrap();
        assert_eq!(snapshot.points.len(), 2);
        assert_eq!(snapshot.own_round_count, 3);
        assert_eq!(snapshot.revision, 2);
    }

    #[test]
    fn stable_pair_copies_deduplicate_and_evidence_conflicts_invalidate_them_all() {
        let fixture = TemporaryDatabase::new("identity");
        let database = Database::open(&fixture.path).unwrap();
        let first = make_checkpoint("generation-a", 90, false);
        let second = make_checkpoint("generation-b", 90, false);
        database.publish("source-a", "a", &first).unwrap();
        database.publish("source-b", "b", &second).unwrap();
        let identical = database
            .snapshot(None, None, 1_700_001_000_000_000)
            .unwrap();
        assert_eq!(identical.points.len(), 1);
        assert_eq!(identical.own_round_count, 2);

        let conflicting = make_checkpoint("generation-c", 85, false);
        database
            .publish("source-b", "b-conflict", &conflicting)
            .unwrap();
        let conflict = database
            .snapshot(None, None, 1_700_001_000_000_000)
            .unwrap();
        assert!(conflict.points.is_empty());
        assert_eq!(conflict.own_round_count, 2);
    }

    #[test]
    fn v1_migration_backfills_stable_own_turns_and_preserves_legacy_rows() {
        let fixture = TemporaryDatabase::new("v1-migration");
        let checkpoint = make_checkpoint("legacy-generation", 90, false);
        let pair = checkpoint
            .parser
            .pairs("source-legacy", &checkpoint.generation)
            .into_iter()
            .find(Pair::eligible)
            .unwrap();
        let pair = encode_pair(&pair).unwrap();
        let encoded_checkpoint = serde_json::to_vec(&checkpoint).unwrap();
        let connection = Connection::open(&fixture.path).unwrap();
        connection.execute_batch("PRAGMA foreign_keys=ON;").unwrap();
        connection.execute_batch(
            "CREATE TABLE retention_meta(id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL);
             INSERT INTO retention_meta(id,revision) VALUES(1,7);
             CREATE TABLE retention_sources(
               source_key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, session_key TEXT NOT NULL,
               is_child INTEGER NOT NULL, explicit_child INTEGER NOT NULL, own_rounds INTEGER NOT NULL,
               generation TEXT NOT NULL, checkpoint BLOB NOT NULL);
             CREATE TABLE retention_pairs(
               pair_key TEXT PRIMARY KEY, source_key TEXT NOT NULL REFERENCES retention_sources(source_key) ON DELETE CASCADE,
               stable_key TEXT, evidence_signature TEXT NOT NULL, eligible INTEGER NOT NULL,
               model TEXT, started_us INTEGER, point BLOB, reasons BLOB NOT NULL);
             CREATE INDEX retention_pair_identity ON retention_pairs(stable_key,evidence_signature,eligible,pair_key);
             CREATE INDEX retention_pair_time ON retention_pairs(started_us,pair_key) WHERE eligible=1;
             CREATE INDEX retention_pair_model ON retention_pairs(model,started_us,pair_key) WHERE eligible=1;
             PRAGMA user_version=1;",
        )
        .unwrap();
        connection
            .execute(
                "INSERT INTO retention_sources(source_key,fingerprint,session_key,is_child,explicit_child,own_rounds,generation,checkpoint)
                 VALUES(?1,?2,?3,0,0,2,?4,?5);",
                params!["source-legacy", "legacy-fingerprint", checkpoint.parser.session_key, checkpoint.generation, encoded_checkpoint],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO retention_pairs(pair_key,source_key,stable_key,evidence_signature,eligible,model,started_us,point,reasons)
                 VALUES(?1,?2,?3,?4,1,?5,?6,?7,?8);",
                params![
                    pair.pair.id,
                    "source-legacy",
                    pair.stable_key,
                    pair.pair.evidence_signature,
                    pair.point.map(|point| point.model.as_str()),
                    pair.point.map(|point| point.started_at_microseconds),
                    pair.point_bytes,
                    pair.reasons_bytes,
                ],
            )
            .unwrap();
        drop(connection);

        let migrated = Database::open(&fixture.path).unwrap();
        assert_eq!(scalar(&migrated.connection, "PRAGMA user_version;"), 2);
        assert_eq!(
            migrated
                .connection
                .query_row(
                    "SELECT present FROM retention_sources WHERE source_key='source-legacy';",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            1
        );
        assert_eq!(
            migrated
                .connection
                .query_row("SELECT fallback_own_rounds FROM retention_sources WHERE source_key='source-legacy';", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            scalar(
                &migrated.connection,
                "SELECT COUNT(*) FROM retention_own_turns;"
            ),
            2
        );
        assert_eq!(
            migrated
                .checkpoint("source-legacy")
                .unwrap()
                .unwrap()
                .offset,
            123
        );
        let snapshot = migrated
            .snapshot(None, None, 1_700_001_000_000_000)
            .unwrap();
        assert_eq!(snapshot.points.len(), 1);
        assert_eq!(snapshot.own_round_count, 2);
        assert_eq!(snapshot.revision, 7);
    }

    #[test]
    fn failed_generation_publish_rolls_back_history_and_current_projection() {
        let fixture = TemporaryDatabase::new("rollback");
        let database = Database::open(&fixture.path).unwrap();
        let first = make_checkpoint("generation-a", 90, false);
        database
            .publish("source-a", "fingerprint-a", &first)
            .unwrap();
        database
            .connection
            .execute_batch(
                "CREATE TRIGGER fail_retention_pair BEFORE INSERT ON retention_pairs
                 BEGIN SELECT RAISE(ABORT,'synthetic insert failure'); END;",
            )
            .unwrap();

        let second = make_checkpoint("generation-b", 90, true);
        assert!(database
            .publish("source-a", "fingerprint-b", &second)
            .is_err());
        assert_eq!(
            database.checkpoint("source-a").unwrap().unwrap().generation,
            "generation-a"
        );
        assert_eq!(
            scalar(
                &database.connection,
                "SELECT COUNT(*) FROM retention_generation_history;"
            ),
            0
        );
        assert_eq!(
            scalar(
                &database.connection,
                "SELECT COUNT(*) FROM retention_pair_history;"
            ),
            0
        );
        assert_eq!(
            scalar(
                &database.connection,
                "SELECT COUNT(*) FROM retention_pairs;"
            ),
            1
        );
        assert_eq!(
            scalar(&database.connection, "SELECT revision FROM retention_meta;"),
            1
        );
    }
}
