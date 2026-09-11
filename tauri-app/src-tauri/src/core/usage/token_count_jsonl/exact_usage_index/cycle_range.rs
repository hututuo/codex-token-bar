//! Published SQLite-only period summaries; never starts the JSONL owner.
use super::*;

pub(crate) fn read(codex_home: &Path, ranges: &[(i64,i64)]) -> Result<Vec<Vec<ModelTokenBreakdown>>, String> {
    let path = database_path(codex_home)?;
    let connection = sqlite::open_read_only(&path, StdDuration::from_secs(3))
        .map_err(|e|format!("周期明细索引待读取：{e}"))?;
    connection.execute_batch("BEGIN DEFERRED").map_err(|e|e.to_string())?;
    let canonical = fs::canonicalize(codex_home).map_err(|e|e.to_string())?;
    if metadata_text(&connection,"codex_home_identity")?.as_deref() != canonical.to_str()
        || !metadata_i64(&connection,"schema_version")?.is_some_and(|v| (INDEX_SCHEMA_VERSION..=CURRENT_SCHEMA_VERSION).contains(&v)) {
        return Err("周期明细索引身份或版本不匹配".into());
    }
    if metadata_text(&connection, PARSER_REPAIR_VERIFY_KEY)?.is_some() {
        return Err("周期明细资料正在更新，请等待精准统计更新".into());
    }
    let published = metadata_i64(&connection,"published_generation")?;
    if published.is_none()
        || metadata_i64(&connection,DASHBOARD_AGGREGATE_EXACT_GENERATION_KEY)? != published
        || metadata_i64(&connection,DASHBOARD_AGGREGATE_PUBLISHED_GENERATION_KEY)? != published
        || metadata_i64(&connection,DASHBOARD_AGGREGATE_SCHEMA_VERSION_KEY)? != Some(DASHBOARD_AGGREGATE_SCHEMA_VERSION)
        || metadata_text(&connection,DASHBOARD_AGGREGATE_PRICING_REVISION_KEY)?.as_deref() != Some(DASHBOARD_AGGREGATE_PRICING_REVISION) {
        return Err("周期明细等待精准聚合更新".into());
    }
    ensure_safe_source(&connection, published.unwrap() as u64)?;
    let settled = metadata_i64(&connection,DASHBOARD_AGGREGATE_SETTLED_THROUGH_KEY)?
        .ok_or("周期明细等待完整聚合发布")?;
    ranges.iter().map(|&(start,end)| query(&connection,start,end,settled)).collect()
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

fn query(connection: &Connection, start:i64, end:i64, settled:i64) -> Result<Vec<ModelTokenBreakdown>,String> {
    if end <= start { return Ok(Vec::new()); }
    let interior_start = ((start + 299).div_euclid(300))*300;
    let interior_end = end.min(settled).div_euclid(300)*300;
    // Whole buckets and exact-event edges are a disjoint partition, including
    // sub-bucket ranges. The entire unsettled tail uses published events; no
    // event is prorated or counted twice.
    let mut statement=connection.prepare(r#"
        WITH parts AS (
            SELECT model,input_tokens,cached_input_tokens,output_tokens,total_tokens,calls,bucket_start AS at
            FROM dashboard_5m
            WHERE file_generation=(SELECT CAST(value AS INTEGER) FROM metadata WHERE key='published_generation')
              AND bucket_start>=?3 AND bucket_start<?4
            UNION ALL
            SELECT model,input_tokens,MIN(cached_input_tokens,input_tokens),output_tokens,tokens,1,timestamp
            FROM published_events WHERE timestamp>=?1 AND timestamp<?2
              AND (?3>=?4 OR timestamp<?3 OR timestamp>=?4)
        )
        SELECT model,SUM(input_tokens),SUM(cached_input_tokens),SUM(output_tokens),SUM(total_tokens),SUM(calls),MIN(at)
        FROM parts GROUP BY model,at/86400 ORDER BY SUM(total_tokens) DESC
    "#).map_err(|e|format!("无法准备周期明细：{e}"))?;
    let rows=statement.query_map(params![start,end,interior_start,interior_end],|r| Ok(ModelTokenBreakdown{
        model:r.get(0)?,event_start_unix:r.get(6)?,breakdown:TokenCacheBreakdown{
            input_tokens:nonnegative_u64(r.get(1)?),cached_input_tokens:nonnegative_u64(r.get(2)?),
            output_tokens:nonnegative_u64(r.get(3)?),total_tokens:nonnegative_u64(r.get(4)?),calls:saturating_u32(r.get(5)?),
        }
    })).map_err(|e|e.to_string())?;
    rows.map(|r|r.map_err(|e|e.to_string())).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn complete_buckets_and_edges_partition_without_loss_or_duplicates() {
        let c=Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE metadata(key TEXT,value TEXT); INSERT INTO metadata VALUES('published_generation','7');
        CREATE TABLE dashboard_5m(file_generation INTEGER,bucket_start INTEGER,model TEXT,input_tokens INTEGER,cached_input_tokens INTEGER,output_tokens INTEGER,total_tokens INTEGER,calls INTEGER);
        CREATE TABLE published_events(timestamp INTEGER,model TEXT,input_tokens INTEGER,cached_input_tokens INTEGER,output_tokens INTEGER,tokens INTEGER);
        INSERT INTO dashboard_5m VALUES(7,300,'gpt-6-astra',30,0,0,30,3),(7,600,'gpt-6-astra',30,0,0,30,3),(8,300,'wrong',999,0,0,999,1);").unwrap();
        for t in [299,300,301,599,600,601,899,900] { c.execute("INSERT INTO published_events VALUES(?1,'gpt-6-astra',10,0,0,10)",[t]).unwrap(); }
        let tokens=|a,b|query(&c,a,b,900).unwrap().iter().map(|r|r.breakdown.total_tokens).sum::<u64>();
        assert_eq!(tokens(299,901),80); assert_eq!(tokens(300,900),60);
        assert_eq!(tokens(301,599),10); assert_eq!(tokens(300,300),0);
        assert_eq!(tokens(299,601)+tokens(601,901),tokens(299,901));
        // Simulate a materialized layer whose settled watermark is behind the
        // request: the whole tail must come from events, not absent buckets.
        c.execute("DELETE FROM dashboard_5m WHERE bucket_start=600",[]).unwrap();
        let tail=query(&c,299,901,600).unwrap().iter().map(|r|r.breakdown.total_tokens).sum::<u64>();
        assert_eq!(tail,80);
    }
    #[test] fn missing_provenance_unsafe_and_incomplete_sources_fail_closed() {
        let c=Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)").unwrap();
        assert!(ensure_safe_source(&c,7).is_err());
        set_metadata(&c,ATTRIBUTION_PROVENANCE_EPOCH_KEY,"00000000-0000-4000-8000-000000000000").unwrap();
        assert!(ensure_safe_source(&c,7).is_ok());
        for key in [ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY,ATTRIBUTION_CURRENT_SCAN_INCOMPLETE_KEY] {
            set_metadata(&c,key,"1").unwrap();
            let error=ensure_safe_source(&c,7).unwrap_err();
            if key == ATTRIBUTION_CURRENT_SCAN_UNSAFE_KEY {
                assert!(error.contains("未解决的校验异常")); assert!(!error.contains("等待"));
            } else { assert!(error.contains("等待精准统计更新")); }
            set_metadata(&c,key,"0").unwrap(); assert!(ensure_safe_source(&c,7).is_ok());
        }
        set_metadata(&c,ATTRIBUTION_UNSAFE_EPOCH_KEY,"11111111-1111-4111-8111-111111111111").unwrap();
        assert!(ensure_safe_source(&c,7).is_err());
    }

}
