//! Published SQLite-only period summaries; never starts the JSONL owner.
use super::*;

use crate::core::quota_history::cycles::ConsumptionEvidence;

/// Exact local event evidence for adjacent quota observations. A positive
/// canonical event is enough to keep a drop. An empty interval is proven only
/// by a matching scan receipt that began after the interval endpoint.
pub(crate) fn read_consumption_evidence(
    codex_home: &Path,
    ranges: &[(f64, f64)],
) -> Vec<ConsumptionEvidence> {
    if ranges.is_empty() {
        return Vec::new();
    }
    let Ok(path) = database_path(codex_home) else {
        return vec![ConsumptionEvidence::Unknown; ranges.len()];
    };
    let Ok(connection) = open_read_only_index(&path, StdDuration::from_secs(3)) else {
        return vec![ConsumptionEvidence::Unknown; ranges.len()];
    };
    if connection.execute_batch("BEGIN DEFERRED").is_err() {
        return vec![ConsumptionEvidence::Unknown; ranges.len()];
    }
    let canonical_home = fs::canonicalize(codex_home)
        .ok()
        .and_then(|home| home.to_str().map(str::to_string));
    let home_matches = canonical_home.as_deref().is_some_and(|home| {
        metadata_text(&connection, "codex_home_identity")
            .ok()
            .flatten()
            .as_deref()
            == Some(home)
    });
    let schema_matches = metadata_i64(&connection, "schema_version")
        .ok()
        .flatten()
        .is_some_and(|version| (INDEX_SCHEMA_VERSION..=CURRENT_SCHEMA_VERSION).contains(&version));
    let published = metadata_i64(&connection, "published_generation")
        .ok()
        .flatten();
    let ledger_is_canonical = table_exists_checked(&connection, "usage_ledger_meta")
        .unwrap_or(false)
        && connection
            .query_row(
                "SELECT value FROM usage_ledger_meta WHERE key='revision'",
                [],
                |row| row.get::<_, String>(0),
            )
            .ok()
            .as_deref()
            == Some("2");
    if !home_matches || !schema_matches || published.is_none() || !ledger_is_canonical {
        return vec![ConsumptionEvidence::Unknown; ranges.len()];
    }

    let safety = published.and_then(|generation| {
        startup_attribution_safety_state(&connection, u64::try_from(generation).ok()?).ok()
    });
    let canonical_projection_ready = metadata_i64(&connection, "canonical_projection_pending")
        .ok()
        .flatten()
        == Some(0);
    let parser_repair_complete = metadata_text(&connection, PARSER_REPAIR_VERIFY_KEY)
        .ok()
        .flatten()
        .is_none();
    let absence_safe = canonical_projection_ready
        && parser_repair_complete
        && safety.as_ref().is_some_and(|state| {
            !state.current_scan_unsafe_cause_detected
                && !state.current_scan_incomplete
                && state.unsafe_since_generation.is_none()
        });
    let receipt = connection
        .query_row(
            "SELECT generation,provenance_epoch,discovery_started_us FROM usage_scan_certificate WHERE id=1",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        )
        .ok();
    let receipt_matches = published
        .zip(safety.as_ref())
        .zip(receipt.as_ref())
        .is_some_and(|((generation, state), (receipt_generation, epoch, _))| {
            *receipt_generation == generation && epoch == &state.provenance_epoch
        });

    let mut cache = HashMap::<(u64, u64), ConsumptionEvidence>::new();
    ranges
        .iter()
        .map(|&(from, through)| {
            let key = (from.to_bits(), through.to_bits());
            if let Some(evidence) = cache.get(&key) {
                return *evidence;
            }
            let evidence = if !from.is_finite() || !through.is_finite() || through <= from {
                ConsumptionEvidence::Unknown
            } else {
                match interval_has_consumption(&connection, from, through) {
                    // Home-local event presence cannot be assigned to an
                    // account, but it always vetoes withdrawing the drop.
                    Ok(true) => ConsumptionEvidence::Present,
                    Ok(false) if absence_safe && receipt_matches => {
                        let covered = receipt.as_ref().is_some_and(|(_, _, started_us)| {
                            let through_us = through * 1_000_000.0;
                            through_us.is_finite() && (*started_us as f64) >= through_us
                        });
                        if !covered {
                            ConsumptionEvidence::Unknown
                        } else {
                            match connection.query_row(
                                "SELECT EXISTS(SELECT 1 FROM usage_ledger_unresolved WHERE timestamp>?1 AND timestamp<=?2)",
                                params![from, through],
                                |row| row.get::<_, bool>(0),
                            ) {
                                Ok(false) => ConsumptionEvidence::Absent,
                                _ => ConsumptionEvidence::Unknown,
                            }
                        }
                    }
                    _ => ConsumptionEvidence::Unknown,
                }
            };
            cache.insert(key, evidence);
            evidence
        })
        .collect()
}

fn interval_has_consumption(
    connection: &Connection,
    from: f64,
    through: f64,
) -> rusqlite::Result<bool> {
    connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM published_events WHERE timestamp>?1 AND timestamp<=?2 AND tokens>0)",
        params![from, through],
        |row| row.get(0),
    )
}

pub(crate) fn read(
    codex_home: &Path,
    ranges: &[(f64, f64)],
) -> Result<Vec<Vec<ModelTokenBreakdown>>, String> {
    let path = database_path(codex_home)?;
    let connection = open_read_only_index(&path, StdDuration::from_secs(3))
        .map_err(|e| format!("周期明细索引待读取：{e}"))?;
    connection
        .execute_batch("BEGIN DEFERRED")
        .map_err(|e| e.to_string())?;
    let canonical = fs::canonicalize(codex_home).map_err(|e| e.to_string())?;
    if metadata_text(&connection, "codex_home_identity")?.as_deref() != canonical.to_str()
        || !metadata_i64(&connection, "schema_version")?
            .is_some_and(|v| (INDEX_SCHEMA_VERSION..=CURRENT_SCHEMA_VERSION).contains(&v))
    {
        return Err("周期明细索引身份或版本不匹配".into());
    }
    if metadata_text(&connection, PARSER_REPAIR_VERIFY_KEY)?.is_some() {
        return Err("周期明细资料正在更新，请等待精准统计更新".into());
    }
    let published = metadata_i64(&connection, "published_generation")?;
    if published.is_none() || metadata_i64(&connection, "canonical_projection_pending")? != Some(0)
    {
        return Err("周期明细等待完整 canonical 事件发布".into());
    }
    ensure_safe_source(&connection, published.unwrap() as u64)?;
    let revision: Option<String> = connection
        .query_row(
            "SELECT value FROM usage_ledger_meta WHERE key='revision'",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| error.to_string())?;
    if revision.as_deref() != Some("2") {
        return Err("周期明细等待 canonical 事件账本".into());
    }
    ranges
        .iter()
        .map(|&(start, end)| query(&connection, start, end))
        .collect()
}

fn ensure_safe_source(connection: &Connection, published: u64) -> Result<(), String> {
    let safety = startup_attribution_safety_state(connection, published)?;
    if safety.current_scan_unsafe_cause_detected {
        return Err("来源记录存在未解决的校验异常，暂不能确认周期明细".into());
    }
    if safety.current_scan_incomplete {
        return Err("周期明细资料正在更新，请等待精准统计更新".into());
    }
    Ok(())
}

fn query(
    connection: &Connection,
    start: f64,
    end: f64,
) -> Result<Vec<ModelTokenBreakdown>, String> {
    if end <= start {
        return Ok(Vec::new());
    }
    let mut statement = connection
        .prepare(
            r#"
        SELECT model,SUM(input_tokens),SUM(MIN(cached_input_tokens,input_tokens)),
               SUM(output_tokens),SUM(tokens),COUNT(*),MIN(timestamp)
        FROM published_events WHERE timestamp>=?1 AND timestamp<?2
        GROUP BY model,timestamp/86400 ORDER BY SUM(tokens) DESC
    "#,
        )
        .map_err(|e| format!("无法准备周期明细：{e}"))?;
    let rows = statement
        .query_map(params![start, end], |r| {
            Ok(ModelTokenBreakdown {
                model: r.get(0)?,
                event_start_unix: r.get(6)?,
                breakdown: TokenCacheBreakdown {
                    input_tokens: nonnegative_u64(r.get(1)?),
                    cached_input_tokens: nonnegative_u64(r.get(2)?),
                    output_tokens: nonnegative_u64(r.get(3)?),
                    total_tokens: nonnegative_u64(r.get(4)?),
                    calls: saturating_u32(r.get(5)?),
                },
            })
        })
        .map_err(|e| e.to_string())?;
    rows.map(|r| r.map_err(|e| e.to_string())).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_fractional_ranges_aggregate_canonical_events_once() {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE published_events(timestamp INTEGER,model TEXT,input_tokens INTEGER,cached_input_tokens INTEGER,output_tokens INTEGER,tokens INTEGER);").unwrap();
        for (time, model, tokens) in [
            (100, "gpt-6-astra", 5),
            (200, "gpt-6-astra", 10),
            (300, "gpt-6-astra", 15),
            (400, "gpt-6-luna", 20),
        ] {
            c.execute(
                "INSERT INTO published_events VALUES(?1,?2,?3,?4,?5,?3)",
                params![time, model, tokens, tokens / 2, 0],
            )
            .unwrap();
        }
        let details = query(&c, 100.5, 300.5).unwrap();
        assert_eq!(details.len(), 1);
        assert_eq!(details[0].model.as_deref(), Some("gpt-6-astra"));
        assert_eq!(details[0].event_start_unix, Some(200));
        assert_eq!(details[0].breakdown.total_tokens, 25);
        assert_eq!(details[0].breakdown.input_tokens, 25);
        assert_eq!(details[0].breakdown.cached_input_tokens, 12);
        assert_eq!(details[0].breakdown.calls, 2);
        let partitioned = query(&c, 100.5, 200.0)
            .unwrap()
            .iter()
            .map(|r| r.breakdown.total_tokens)
            .sum::<u64>()
            + query(&c, 200.0, 300.5)
                .unwrap()
                .iter()
                .map(|r| r.breakdown.total_tokens)
                .sum::<u64>();
        assert_eq!(partitioned, 25);
        assert!(query(&c, 300.5, 300.5).unwrap().is_empty());
    }

    #[test]
    fn consumption_interval_excludes_from_and_includes_through() {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(
            "CREATE TABLE published_events(timestamp INTEGER,tokens INTEGER);
             INSERT INTO published_events VALUES(10,9),(20,0),(21,7),(30,4);",
        )
        .unwrap();

        assert!(!interval_has_consumption(&c, 10.0, 20.0).unwrap());
        assert!(interval_has_consumption(&c, 20.0, 21.0).unwrap());
        assert!(interval_has_consumption(&c, 21.0, 30.0).unwrap());
        assert!(!interval_has_consumption(&c, 30.0, 30.5).unwrap());
    }

    #[test]
    fn missing_provenance_unsafe_and_incomplete_sources_fail_closed() {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)")
            .unwrap();
        assert!(ensure_safe_source(&c, 7).is_err());
        set_metadata(
            &c,
            ATTRIBUTION_PROVENANCE_EPOCH_KEY,
            "00000000-0000-4000-8000-000000000000",
        )
        .unwrap();
        assert!(ensure_safe_source(&c, 7).is_ok());
        for key in [
            ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY,
            ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY,
        ] {
            set_metadata(&c, key, "1").unwrap();
            let error = ensure_safe_source(&c, 7).unwrap_err();
            if key == ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY {
                assert!(error.contains("未解决的校验异常"));
                assert!(!error.contains("等待"));
            } else {
                assert!(error.contains("等待精准统计更新"));
            }
            set_metadata(&c, key, "0").unwrap();
            assert!(ensure_safe_source(&c, 7).is_ok());
        }
        set_metadata(
            &c,
            ATTRIBUTION_UNSAFE_EPOCH_KEY,
            "11111111-1111-4111-8111-111111111111",
        )
        .unwrap();
        assert!(ensure_safe_source(&c, 7).is_err());
    }
}
