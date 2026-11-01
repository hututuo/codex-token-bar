//! Semantic recovery proofs for known legacy transitions. Never rewrites a
//! source, invents event identity, or drops protected numeric history.
use super::business_store_container::{BusinessStoreError, BusinessStoreResult};
use super::business_store_sql::SQLiteStoreNamespace;
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashMap;
use std::path::Path;

const OLD: &str = "tb_exact_history_source";
const VERIFIED: &str = "tb_verified_legacy_prefixes";
fn q(name: &str) -> String {
    SQLiteStoreNamespace::quote(name)
}
fn has_table(db: &Connection, schema: &str, name: &str) -> BusinessStoreResult<bool> {
    Ok(db.query_row(
        &format!(
            "SELECT EXISTS(SELECT 1 FROM {schema}.sqlite_master WHERE type='table' AND name=?1)"
        ),
        [name],
        |r| r.get(0),
    )?)
}
fn meta(db: &Connection, table: &str, key: &str) -> BusinessStoreResult<Option<String>> {
    Ok(db
        .query_row(
            &format!("SELECT value FROM {table} WHERE key=?1"),
            [key],
            |r| r.get(0),
        )
        .optional()?)
}

/// Policy 3 keeps every raw observation. Only its maintenance clock may move;
/// row identity, policy, unknown keys, and all other tables remain protected.
pub(crate) fn quota_maintenance_covers(db: &Connection) -> BusinessStoreResult<bool> {
    let columns = |schema: &str| -> BusinessStoreResult<Vec<String>> {
        Ok(db
            .prepare(&format!(
                "PRAGMA {schema}.table_info(quota_history_maintenance)"
            ))?
            .query_map([], |r| r.get(1))?
            .collect::<Result<_, _>>()?)
    };
    if columns("main")? != ["key", "value"] || columns(OLD)? != ["key", "value"] {
        return Ok(false);
    }
    for schema in [OLD, "main"] {
        let info = db
            .prepare(&format!(
                "PRAGMA {schema}.table_info(quota_history_maintenance)"
            ))?
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(5)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        if info.len() != 2
            || info[0].1.to_ascii_uppercase() != "TEXT"
            || info[0].3 != 1
            || info[1].1.to_ascii_uppercase() != "TEXT"
            || info[1].2 != 1
            || info[1].3 != 0
        {
            return Ok(false);
        }
    }
    if db.query_row(&format!("SELECT EXISTS(SELECT 1 FROM {OLD}.quota_history_maintenance WHERE key IS NULL UNION ALL SELECT 1 FROM main.quota_history_maintenance WHERE key IS NULL)"),[],|r|r.get::<_,bool>(0))? { return Ok(false); }
    let mut times = Vec::new();
    for schema in [OLD, "main"] {
        let table = format!("{schema}.quota_history_maintenance");
        if meta(db, &table, "policy_version")?.as_deref() != Some("3") {
            return Ok(false);
        }
        let Some(raw) = meta(db, &table, "last_compacted_at")? else {
            return Ok(false);
        };
        let Ok(time) = raw.parse::<f64>() else {
            return Ok(false);
        };
        if !time.is_finite() || !(0.0..=253_402_300_799.0).contains(&time) {
            return Ok(false);
        }
        times.push(time);
    }
    if times[1] < times[0] {
        return Ok(false);
    }
    // No new/removed maintenance keys or silently recreated rowids. Unknown
    // existing values remain strict; a future policy is not auto-recognized.
    let identity = "typeof(rowid),rowid,typeof(key),key,typeof(value)";
    for (left, right) in [(OLD, "main"), ("main", OLD)] {
        let changed: bool = db.query_row(&format!("SELECT EXISTS(SELECT {identity} FROM {left}.quota_history_maintenance EXCEPT SELECT {identity} FROM {right}.quota_history_maintenance)"),[],|r|r.get(0))?;
        if changed {
            return Ok(false);
        }
    }
    Ok(!db.query_row(&format!("SELECT EXISTS(SELECT typeof(rowid),rowid,typeof(key),key,typeof(value),value FROM {OLD}.quota_history_maintenance WHERE key IS NULL OR key<>'last_compacted_at' EXCEPT SELECT typeof(rowid),rowid,typeof(key),key,typeof(value),value FROM main.quota_history_maintenance WHERE key IS NULL OR key<>'last_compacted_at')"),[],|r|r.get::<_,bool>(0))?)
}

/// State-file signatures are an optional paired cache identity, not usage.
/// Maintenance clocks are canonical bounded seconds and may only progress.
pub(crate) fn exact_operational_metadata_covers(
    db: &Connection,
    prefix: &str,
    old: &Connection,
) -> BusinessStoreResult<bool> {
    let table = q(&format!("{prefix}metadata"));
    for (connection, name) in [(old, "metadata"), (db, table.as_str())] {
        let size = meta(connection, name, "state_size")?;
        let stamp = meta(connection, name, "state_modified_ns")?;
        match (size, stamp) {
            (None, None) => {}
            (Some(size), Some(stamp)) => {
                if size
                    .parse::<u64>()
                    .ok()
                    .is_none_or(|v| v.to_string() != size)
                    || stamp
                        .parse::<u128>()
                        .ok()
                        .is_none_or(|v| v.to_string() != stamp)
                {
                    return Ok(false);
                }
            }
            _ => return Ok(false),
        }
    }
    for key in [
        "storage_maintenance_last_checked_unix",
        "storage_maintenance_last_compacted_unix",
    ] {
        let mut parsed = Vec::new();
        for (connection, name) in [(old, "metadata"), (db, table.as_str())] {
            let value = meta(connection, name, key)?;
            let parsed_value = match value {
                None => None,
                Some(raw) => {
                    let Ok(value) = raw.parse::<u64>() else {
                        return Ok(false);
                    };
                    if value > 253_402_300_799 || value.to_string() != raw {
                        return Ok(false);
                    }
                    Some(value)
                }
            };
            parsed.push(parsed_value);
        }
        if let Some(before) = parsed[0] {
            if parsed[1].is_none_or(|after| after < before) {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

/// This temporary proof set is local to one comparison, never a business DB.
/// Prefix checks run once per affected source, not once per event.
pub(crate) struct VerifiedLegacySources<'a> {
    db: &'a Connection,
    prefix: String,
    prefixes: HashMap<i64, bool>,
}
impl<'a> VerifiedLegacySources<'a> {
    pub(crate) fn prepare(db: &'a Connection, prefix: &str) -> BusinessStoreResult<Self> {
        db.execute_batch(&format!("DROP TABLE IF EXISTS temp.{VERIFIED}; CREATE TEMP TABLE {VERIFIED}(source_id INTEGER PRIMARY KEY)"))?;
        let mut result = Self {
            db,
            prefix: prefix.into(),
            prefixes: HashMap::new(),
        };
        if has_table(db, OLD, "usage_ledger_bindings")?
            && has_table(db, "main", &format!("{prefix}usage_ledger_bindings"))?
        {
            let table = q(&format!("{prefix}usage_ledger_bindings"));
            let ids=db.prepare(&format!("SELECT DISTINCT old.source_id FROM {OLD}.usage_ledger_bindings old JOIN main.{table} current ON current.event_id=old.event_id AND current.source_id=old.source_id WHERE old.fingerprint IS NULL AND current.fingerprint IS NOT NULL"))?
                .query_map([],|r|r.get::<_,i64>(0))?.collect::<Result<Vec<_>,_>>()?;
            for id in ids {
                if result.prefix_unchanged(id)? {
                    db.execute(&format!("INSERT INTO temp.{VERIFIED} VALUES(?1)"), [id])?;
                }
            }
        }
        let fields="source_id,timestamp,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,accounting_kind";
        for (name, events) in [
            ("tb_legacy_old_observations", format!("{OLD}.event_rows")),
            (
                "tb_legacy_new_observations",
                format!("main.{}", q(&format!("{prefix}event_rows"))),
            ),
        ] {
            db.execute_batch(&format!("DROP TABLE IF EXISTS temp.{name}; CREATE TEMP TABLE {name}(source_id INTEGER,timestamp INTEGER,input_tokens INTEGER,cached_input_tokens INTEGER,output_tokens INTEGER,reasoning_output_tokens INTEGER,accounting_kind INTEGER,n INTEGER); CREATE INDEX temp.{name}_key ON {name}({fields})"))?;
            if has_table(db, OLD, "event_rows")?
                && has_table(db, "main", &format!("{prefix}event_rows"))?
            {
                db.execute_batch(&format!("INSERT INTO temp.{name} SELECT {fields},COUNT(*) FROM {events} WHERE source_id IN(SELECT source_id FROM temp.{VERIFIED}) GROUP BY {fields}"))?;
            }
        }
        db.execute_batch("DROP TABLE IF EXISTS temp.tb_legacy_current_fp_counts; CREATE TEMP TABLE tb_legacy_current_fp_counts(source_id INTEGER,fingerprint BLOB,n INTEGER); CREATE INDEX temp.tb_legacy_fp_key ON tb_legacy_current_fp_counts(source_id,fingerprint)")?;
        if has_table(db, "main", &format!("{prefix}usage_ledger_bindings"))? {
            db.execute_batch(&format!("INSERT INTO temp.tb_legacy_current_fp_counts SELECT source_id,fingerprint,COUNT(*) FROM main.{} WHERE source_id IN(SELECT source_id FROM temp.{VERIFIED}) GROUP BY source_id,fingerprint",q(&format!("{prefix}usage_ledger_bindings"))))?;
        }
        Ok(result)
    }
    fn prefix_unchanged(&mut self, source: i64) -> BusinessStoreResult<bool> {
        if let Some(value) = self.prefixes.get(&source) {
            return Ok(*value);
        }
        let value = self.check_prefix(source)?;
        self.prefixes.insert(source, value);
        Ok(value)
    }
    fn check_prefix(&self, source: i64) -> BusinessStoreResult<bool> {
        let db = self.db;
        for name in ["sources", "source_chunks"] {
            if !has_table(db, OLD, name)?
                || !has_table(db, "main", &format!("{}{name}", self.prefix))?
            {
                return Ok(false);
            }
        }
        let sources = q(&format!("{}sources", self.prefix));
        let path:Option<String>=db.query_row(&format!("SELECT current.path FROM {OLD}.sources old JOIN main.{sources} current ON current.source_id=old.source_id AND current.path IS old.path AND current.session_id IS old.session_id WHERE old.source_id=?1"),[source],|r|r.get(0)).optional()?;
        let Some(path) = path else {
            return Ok(false);
        };
        let chunks=db.prepare(&format!("SELECT chunk_index,byte_count,sha256 FROM {OLD}.source_chunks WHERE source_id=?1 ORDER BY chunk_index"))?
            .query_map([source],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,i64>(1)?,r.get::<_,Vec<u8>>(2)?)))?.collect::<Result<Vec<_>,_>>()?;
        if chunks.is_empty() {
            return Ok(false);
        }
        let target = q(&format!("{}source_chunks", self.prefix));
        let mut offset = 0u64;
        for (position, (index, count, hash)) in chunks.iter().enumerate() {
            if *index != position as i64
                || *count <= 0
                || *count > 4 * 1024 * 1024
                || hash.len() != 32
            {
                return Ok(false);
            }
            let current:Option<(i64,Vec<u8>)>=db.query_row(&format!("SELECT byte_count,sha256 FROM main.{target} WHERE source_id=?1 AND chunk_index=?2"),params![source,index],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
            match current {
                Some((size,value)) if size==*count && value==*hash=>{},
                Some((size,_)) if position+1==chunks.len() && size>*count && size<=4*1024*1024=>{
                    if !crate::core::usage::token_count_jsonl::recovery_source::prefix_fragment_matches(Path::new(&path),offset,*count as u64,hash) { return Ok(false); }
                },
                _=>return Ok(false),
            }
            offset = offset
                .checked_add(*count as u64)
                .ok_or(BusinessStoreError::ProofMismatch)?;
        }
        Ok(true)
    }
    pub(crate) fn sources_cover(&mut self) -> BusinessStoreResult<bool> {
        let table = q(&format!("{}sources", self.prefix));
        let missing:bool=self.db.query_row(&format!("SELECT EXISTS(SELECT 1 FROM {OLD}.sources old LEFT JOIN main.{table} current ON current.source_id=old.source_id WHERE current.source_id IS NULL OR typeof(old.source_id)<>typeof(current.source_id) OR typeof(old.path)<>typeof(current.path) OR old.path IS NOT current.path OR typeof(old.session_id)<>typeof(current.session_id) OR old.session_id IS NOT current.session_id)"),[],|r|r.get(0))?;
        if missing {
            return Ok(false);
        }
        let changed=self.db.prepare(&format!("SELECT old.source_id,old.is_explicit_subagent_fork,current.is_explicit_subagent_fork,current.path,current.session_id FROM {OLD}.sources old JOIN main.{table} current USING(source_id) WHERE typeof(old.is_explicit_subagent_fork)<>typeof(current.is_explicit_subagent_fork) OR old.is_explicit_subagent_fork IS NOT current.is_explicit_subagent_fork"))?
            .query_map([],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,i64>(1)?,r.get::<_,i64>(2)?,r.get::<_,String>(3)?,r.get::<_,String>(4)?)))?.collect::<Result<Vec<_>,_>>()?;
        if changed.is_empty() {
            return Ok(true);
        }
        let metadata = q(&format!("{}metadata", self.prefix));
        if meta(
            self.db,
            &format!("{OLD}.metadata"),
            "parser_repair_verify_pending",
        )?
        .as_deref()
            != Some("paginated-owned-turn-v6")
            || meta(self.db, &metadata, "parser_repair_verify_pending")?.is_some()
            || meta(
                self.db,
                &format!("{OLD}.metadata"),
                "fork_replay_boundary_revision",
            )?
            .as_deref()
                != Some("paginated-owned-turn-v6")
            || meta(self.db, &metadata, "fork_replay_boundary_revision")?.as_deref()
                != Some("paginated-owned-turn-v6")
        {
            return Ok(false);
        }
        for (id, old, current, path, session) in changed {
            if old!=1 || current!=0 || !self.prefix_unchanged(id)?
                || !crate::core::usage::token_count_jsonl::recovery_source::is_paginated_without_parent(Path::new(&path),&session) { return Ok(false); }
        }
        Ok(true)
    }
    pub(crate) fn bindings_cover(&self) -> BusinessStoreResult<bool> {
        let bindings = q(&format!("{}usage_ledger_bindings", self.prefix));
        let known_positions=["raw_offset","user_prompt_start","user_prompt_end","assistant_response_start","assistant_response_end"].iter()
            .map(|c|format!("(old.{c} IS NOT NULL AND (typeof(old.{c})<>typeof(current.{c}) OR old.{c} IS NOT current.{c}))")).collect::<Vec<_>>().join(" OR ");
        let observation = [
            "timestamp",
            "input_tokens",
            "cached_input_tokens",
            "output_tokens",
            "reasoning_output_tokens",
            "accounting_kind",
        ]
        .iter()
        .map(|c| format!("candidate.{c} IS event.{c}"))
        .collect::<Vec<_>>()
        .join(" AND ");
        let enrichment = format!(
            r#"typeof(old.raw_generation)='integer' AND typeof(current.raw_generation)='integer'
          AND old.raw_generation>=0 AND current.raw_generation>=old.raw_generation
          AND old.fingerprint IS NULL AND typeof(current.fingerprint)='blob' AND length(current.fingerprint)>0
          AND event.id IS NOT NULL AND NOT ({known_positions})
          AND EXISTS(SELECT 1 FROM temp.{VERIFIED} v WHERE v.source_id=old.source_id)
          AND EXISTS(SELECT 1 FROM {OLD}.source_fingerprints f WHERE f.source_id=old.source_id AND f.fingerprint=current.fingerprint)
          AND EXISTS(SELECT 1 FROM temp.tb_legacy_current_fp_counts f WHERE f.source_id=old.source_id AND f.fingerprint=current.fingerprint AND f.n=1)
          AND (old.raw_offset IS NOT NULL OR (
              EXISTS(SELECT 1 FROM temp.tb_legacy_old_observations candidate WHERE candidate.source_id=old.source_id AND {observation} AND candidate.n=1)
              AND EXISTS(SELECT 1 FROM temp.tb_legacy_new_observations candidate WHERE candidate.source_id=old.source_id AND {observation} AND candidate.n=1)
          ))"#
        );
        let sql = format!(
            r#"SELECT EXISTS(
          SELECT 1 FROM {OLD}.usage_ledger_bindings old
          LEFT JOIN main.{bindings} current ON current.event_id=old.event_id AND current.source_id=old.source_id
          LEFT JOIN {OLD}.event_rows event ON event.id=old.event_id AND event.source_id=old.source_id
          WHERE current.event_id IS NULL
             OR (old.fingerprint IS NOT NULL AND (typeof(old.fingerprint)<>typeof(current.fingerprint) OR old.fingerprint IS NOT current.fingerprint))
             OR (old.raw_generation IS current.raw_generation AND ({known_positions}))
             OR (old.fingerprint IS NULL AND current.fingerprint IS NOT NULL AND NOT ({enrichment}))
             OR (old.raw_generation IS NOT current.raw_generation AND NOT (
                typeof(old.raw_generation)='integer' AND typeof(current.raw_generation)='integer'
                AND old.raw_generation>=0 AND current.raw_generation>old.raw_generation
                AND (old.fingerprint IS NOT NULL AND old.fingerprint IS current.fingerprint OR ({enrichment}))
             ))
        )"#
        );
        Ok(!self.db.query_row(&sql, [], |r| r.get::<_, bool>(0))?)
    }
}
impl Drop for VerifiedLegacySources<'_> {
    fn drop(&mut self) {
        let _ = self
            .db
            .execute_batch(&format!("DROP TABLE IF EXISTS temp.{VERIFIED}; DROP TABLE IF EXISTS temp.tb_legacy_old_observations; DROP TABLE IF EXISTS temp.tb_legacy_new_observations; DROP TABLE IF EXISTS temp.tb_legacy_current_fp_counts"));
    }
}

#[cfg(test)]
#[path = "business_store_recovery_tests.rs"]
mod tests;
