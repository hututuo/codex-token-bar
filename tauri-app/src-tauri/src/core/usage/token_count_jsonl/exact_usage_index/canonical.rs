//! Reversible numeric projection. Physical rows and their raw bindings survive
//! deduplication; only identical complete observations of the same UUID merge.
use super::*;
use rusqlite::types::Value;

pub(super) fn install(db: &Connection) -> Result<(), String> {
    db.execute_batch(r#"
        CREATE TABLE IF NOT EXISTS usage_ledger_duplicates(
            event_id INTEGER PRIMARY KEY, source_id INTEGER NOT NULL,
            representative_source_id INTEGER NOT NULL);
        CREATE VIEW IF NOT EXISTS canonical_usage_events AS
            SELECT e.* FROM events e WHERE NOT EXISTS(
                SELECT 1 FROM usage_ledger_duplicates d WHERE d.event_id=e.id AND d.source_id=e.source_id);
        DROP VIEW IF EXISTS published_events;
        CREATE VIEW published_events AS
            SELECT e.* FROM canonical_usage_events e JOIN published_files f
              ON f.source_id=e.source_id AND f.generation=e.file_generation WHERE e.tokens>0;
        CREATE TABLE IF NOT EXISTS usage_ledger_attribution_floors(
            source_id TEXT NOT NULL,bucket_start INTEGER NOT NULL,
            tokens INTEGER NOT NULL,calls INTEGER NOT NULL,input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,
            PRIMARY KEY(source_id,bucket_start)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS usage_scan_certificate(
            id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL,
            provenance_epoch TEXT NOT NULL, scan_id TEXT NOT NULL,
            source_count INTEGER NOT NULL, source_witness TEXT NOT NULL, discovery_started_us INTEGER NOT NULL);
    "#).map_err(|e| format!("无法安装可逆账本投影：{e}"))?;
    capture_legacy_floors(db)
}

pub(super) fn refresh(db: &Connection, generation: i64) -> Result<bool, String> {
    let mut old = std::collections::BTreeMap::new();
    let mut statement = db
        .prepare("SELECT event_id,source_id,representative_source_id FROM usage_ledger_duplicates")
        .map_err(|e| e.to_string())?;
    for row in statement
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                (r.get::<_, i64>(1)?, r.get::<_, i64>(2)?),
            ))
        })
        .map_err(|e| e.to_string())?
    {
        let (id, value) = row.map_err(|e| e.to_string())?;
        old.insert(id, value);
    }
    let mut sources = std::collections::BTreeMap::<Uuid, Vec<i64>>::new();
    let mut statement = db
        .prepare("SELECT source_id,session_id FROM sources ORDER BY source_id")
        .map_err(|e| e.to_string())?;
    for row in statement
        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))
        .map_err(|e| e.to_string())?
    {
        let (source, session) = row.map_err(|e| e.to_string())?;
        if let Ok(uuid) = Uuid::parse_str(&session) {
            sources.entry(uuid).or_default().push(source);
        }
    }
    let mut desired = std::collections::BTreeMap::new();
    for group in sources.values().filter(|g| g.len() > 1) {
        // SQLite values keep NULL/type/length boundaries in the exact key.
        let mut representatives = HashMap::<Vec<u8>, i64>::new();
        for source in group {
            let mut statement = db
                .prepare(
                    r#"
                SELECT e.id,COALESCE(p.fingerprint,b.fingerprint),e.timestamp,e.tokens,
                    e.input_tokens,e.cached_input_tokens,e.output_tokens,e.reasoning_output_tokens,
                    e.model,e.accounting_kind,e.reported_total_tokens,e.legacy_tokens
                FROM events e
                LEFT JOIN usage_ledger_pending_bindings p ON p.event_id=e.id
                LEFT JOIN usage_ledger_bindings b ON b.event_id=e.id
                WHERE e.source_id=?1 AND e.file_generation=(
                    SELECT MAX(f.generation) FROM files f WHERE f.source_id=?1 AND f.generation<=?2)
                ORDER BY e.ordinal,e.id
            "#,
                )
                .map_err(|e| e.to_string())?;
            let mut rows = statement
                .query(params![source, generation])
                .map_err(|e| e.to_string())?;
            while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                let id: i64 = row.get(0).map_err(|e| e.to_string())?;
                let Some(fingerprint): Option<Vec<u8>> = row.get(1).map_err(|e| e.to_string())?
                else {
                    continue;
                };
                let values = fingerprint_codec::decode(&fingerprint)
                    .map_err(|e| format!("账本指纹损坏，已停止发布：{e:?}"))?;
                if values[5] != 1 && values[6..].iter().any(|v| *v != 0) {
                    continue;
                }
                let mut key = Vec::new();
                for i in 1..12 {
                    let value: Value = row.get(i).map_err(|e| e.to_string())?;
                    match value {
                        Value::Null => key.push(0),
                        Value::Integer(n) => {
                            key.push(1);
                            key.extend(n.to_le_bytes());
                        }
                        Value::Real(_) => {
                            return Err("账本去重字段出现非精确数字，已停止发布".into())
                        }
                        Value::Text(s) => {
                            key.push(3);
                            key.extend((s.len() as u64).to_le_bytes());
                            key.extend(s.as_bytes());
                        }
                        Value::Blob(b) => {
                            key.push(4);
                            key.extend((b.len() as u64).to_le_bytes());
                            key.extend(b);
                        }
                    }
                }
                if let Some(representative) = representatives.get(&key).filter(|id| **id < *source)
                {
                    desired.insert(id, (*source, *representative));
                } else {
                    representatives.insert(key, *source);
                }
            }
        }
    }
    if old == desired {
        return Ok(false);
    }
    db.execute("DELETE FROM usage_ledger_duplicates", [])
        .map_err(|e| e.to_string())?;
    let mut insert = db
        .prepare("INSERT INTO usage_ledger_duplicates VALUES(?1,?2,?3)")
        .map_err(|e| e.to_string())?;
    for (id, (source, representative)) in desired {
        insert
            .execute(params![id, source, representative])
            .map_err(|e| e.to_string())?;
    }
    Ok(true)
}

pub(super) fn certify(db: &Connection) -> Result<(), String> {
    let generation = metadata_i64(db, "published_generation")?.unwrap_or(0);
    let epoch = metadata_text(db, ATTRIBUTION_PROVENANCE_EPOCH_KEY)?.ok_or("账本谱系缺失")?;
    let mut hasher = Sha256::new();
    let mut count = 0i64;
    let mut statement=db.prepare("SELECT s.source_id,s.path,s.size,s.modified_ns,s.prefix_sha256,COALESCE(l.missing,0) FROM sources s LEFT JOIN usage_ledger_sources l USING(source_id) ORDER BY s.source_id").map_err(|e|e.to_string())?;
    let mut rows = statement.query([]).map_err(|e| e.to_string())?;
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        for i in 0..6 {
            let value: Value = row.get(i).map_err(|e| e.to_string())?;
            let bytes = format!("{value:?}").into_bytes();
            hasher.update((bytes.len() as u64).to_le_bytes());
            hasher.update(bytes);
        }
    }
    count = db
        .query_row("SELECT COUNT(*) FROM exact_seen_files", [], |r| {
            r.get::<_, i64>(0)
        })
        .map_err(|e| e.to_string())?;
    let started =
        metadata_i64(db, "building_discovery_started_us")?.ok_or("扫描发现开始时间缺失")?;
    db.execute(
        "INSERT OR REPLACE INTO usage_scan_certificate VALUES(1,?1,?2,?3,?4,?5,?6)",
        params![
            generation,
            epoch,
            Uuid::new_v4().to_string(),
            count,
            format!("{:x}", hasher.finalize()),
            started
        ],
    )
    .map_err(|e| e.to_string())?;
    set_metadata(db, "canonical_projection_pending", "0")
}

// An attribution-only tombstone cannot be reconstructed from current physical
// events. Keep that pre-existing lower bound separate from canonical sums.
fn capture_legacy_floors(db: &Connection) -> Result<(), String> {
    db.execute_batch("CREATE TEMP TABLE IF NOT EXISTS ledger_known_attribution_sources(source_id TEXT PRIMARY KEY);DELETE FROM ledger_known_attribution_sources;").map_err(|e|e.to_string())?;
    let mut sources = db
        .prepare("SELECT DISTINCT session_id FROM sources")
        .map_err(|e| e.to_string())?;
    for row in sources
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?
    {
        let session = row.map_err(|e| e.to_string())?;
        db.execute(
            "INSERT OR IGNORE INTO ledger_known_attribution_sources VALUES(?1)",
            params![opaque_attribution_source_id(&session)],
        )
        .map_err(|e| e.to_string())?;
    }
    db.execute_batch(r#"
        INSERT INTO usage_ledger_attribution_floors
        SELECT source_id,bucket_start,MAX(tokens),MAX(calls),MAX(input_tokens),MAX(cached_input_tokens),MAX(output_tokens)
        FROM attribution_source_buckets a
        WHERE NOT EXISTS(SELECT 1 FROM ledger_known_attribution_sources s WHERE s.source_id=a.source_id)
        GROUP BY source_id,bucket_start
        ON CONFLICT(source_id,bucket_start) DO UPDATE SET
          tokens=MAX(tokens,excluded.tokens),calls=MAX(calls,excluded.calls),
          input_tokens=MAX(input_tokens,excluded.input_tokens),
          cached_input_tokens=MAX(cached_input_tokens,excluded.cached_input_tokens),
          output_tokens=MAX(output_tokens,excluded.output_tokens);
        DROP TABLE ledger_known_attribution_sources;
    "#).map_err(|e|e.to_string())
}

pub(super) fn restore_legacy_floors(db: &Connection, epoch: &str) -> Result<(), String> {
    db.execute(
        r#"INSERT INTO attribution_source_buckets
        SELECT ?1,source_id,bucket_start,tokens,calls,input_tokens,cached_input_tokens,output_tokens
        FROM usage_ledger_attribution_floors WHERE 1
        ON CONFLICT(provenance_epoch,source_id,bucket_start) DO UPDATE SET
          tokens=MAX(tokens,excluded.tokens),calls=MAX(calls,excluded.calls),
          input_tokens=MAX(input_tokens,excluded.input_tokens),
          cached_input_tokens=MAX(cached_input_tokens,excluded.cached_input_tokens),
          output_tokens=MAX(output_tokens,excluded.output_tokens)"#,
        params![epoch],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}
