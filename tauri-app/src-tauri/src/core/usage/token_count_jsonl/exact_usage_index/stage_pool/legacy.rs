//! Admission of old per-source stages. An empty manifest is absence only for
//! the complete known empty producer. Schema evidence can follow SQLite's
//! schema version; payload presence must be read anew in the same snapshot.

use super::*;

#[derive(Clone)]
struct Object {
    name: String,
    kind: String,
    contract: Option<[u8; 32]>,
}

pub(super) struct Catalog {
    schema_version: i64,
    prefix_len: usize,
    objects: HashMap<String, Vec<Object>>,
}

#[derive(PartialEq)]
struct Column {
    position: i64,
    name: String,
    declared_type: String,
    not_null: i64,
    default: Option<String>,
    primary_key: i64,
    hidden: i64,
}

struct Layout {
    tables: Vec<(String, [u8; 32], Vec<Column>)>,
}

fn schema_contract(prefix: &str, sql: &str) -> Result<[u8; 32]> {
    let namespace = SQLiteStoreNamespace::new(prefix, TABLES.iter().map(|(name, _, _)| (*name).to_owned()));
    let logical = namespace.unbind(sql).map_err(|e| format!("{e:?}"))?;
    let canonical = SQLiteStoreNamespace::canonical_sql(&logical).map_err(|e| format!("{e:?}"))?;
    Ok(Sha256::digest(canonical.as_bytes()).into())
}

fn columns(raw: &Connection, name: &str) -> Result<Vec<Column>> {
    let mut statement = raw.prepare(&format!("PRAGMA main.table_xinfo({})", quote(name)))
        .map_err(|e| e.to_string())?;
    let rows = statement.query_map([], |row| Ok(Column {
        position: row.get(0)?, name: row.get(1)?, declared_type: row.get(2)?,
        not_null: row.get(3)?, default: row.get(4)?, primary_key: row.get(5)?, hidden: row.get(6)?,
    })).map_err(|e| e.to_string())?;
    rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|e| e.to_string())
}

fn layout(sql: &str) -> Result<Layout> {
    let expected = Connection::open_in_memory().map_err(|e| e.to_string())?;
    expected.execute_batch(sql).map_err(|e| e.to_string())?;
    let tables = TABLES.iter().map(|(name, _, _)| {
        let ddl: String = expected.query_row("SELECT sql FROM sqlite_master WHERE name=?1", [name], |row| row.get(0))
            .map_err(|e| e.to_string())?;
        Ok(((*name).to_owned(), schema_contract("", &ddl)?, columns(&expected, name)?))
    }).collect::<Result<Vec<_>>>()?;
    Ok(Layout { tables })
}

fn known_layouts() -> Result<&'static [Layout; 2]> {
    static LAYOUTS: OnceLock<Result<[Layout; 2]>> = OnceLock::new();
    LAYOUTS.get_or_init(|| Ok([
        layout(&super::super::staging_schema_sql(false))?,
        layout("CREATE TABLE manifest(manifest_schema_version INTEGER NOT NULL,parser_revision TEXT NOT NULL,complete INTEGER NOT NULL,staging_mode TEXT NOT NULL,accounting_state TEXT);
            CREATE TABLE events(ordinal INTEGER PRIMARY KEY);
            CREATE TABLE fingerprints(fingerprint BLOB PRIMARY KEY);
            CREATE TABLE chunks(chunk_index INTEGER PRIMARY KEY);")?,
    ])).as_ref().map_err(Clone::clone)
}

fn objects(pool: &Pool, raw: &Connection, prefix: &str) -> Result<Vec<Object>> {
    let version = raw.query_row("PRAGMA schema_version", [], |row| row.get::<_, i64>(0)).map_err(|e| e.to_string())?;
    let mut cache = pool.legacy_catalog.lock().map_err(|_| "旧暂存目录锁失败")?;
    if let Some(catalog) = cache.as_ref().filter(|value| value.schema_version == version && value.prefix_len == prefix.len()) {
        return Ok(catalog.objects.get(prefix).cloned().unwrap_or_default());
    }
    // One bounded catalog pass avoids a sqlite_master scan for each of the
    // thousands of historical stages. Retain a fixed-size DDL digest, not SQL
    // text or facts. Other owners' unsupported SQL must not poison this owner.
    let mut catalog = HashMap::<String, Vec<Object>>::new();
    let mut selected = Vec::new();
    let mut bytes = 0usize;
    let mut keep = true;
    let mut record = |owner: &str, object: Object| {
        if owner == prefix && selected.len() < 5 { selected.push(object.clone()); }
        bytes = bytes.saturating_add(owner.len() + object.name.len() + object.kind.len() + 160);
        if bytes > 16 * 1024 * 1024 { keep = false; catalog.clear(); }
        if keep {
            let values = catalog.entry(owner.to_owned()).or_default();
            if values.len() < 5 { values.push(object); }
        }
    };
    // The internal prefix is literal: LIKE's underscore would also hide a
    // foreign sqliteX index/trigger that depends on a selected stage table.
    let mut statement = raw.prepare("SELECT name,type,tbl_name,CASE WHEN length(CAST(sql AS BLOB))<=1048576 THEN sql END FROM main.sqlite_master WHERE lower(substr(name,1,7)) <> 'sqlite_'")
        .map_err(|e| e.to_string())?;
    let mut rows = statement.query([]).map_err(|e| e.to_string())?;
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let name: String = row.get(0).map_err(|e| e.to_string())?;
        let kind: String = row.get(1).map_err(|e| e.to_string())?;
        let table: String = row.get(2).map_err(|e| e.to_string())?;
        let owner = name.get(..prefix.len());
        if let Some(owner) = owner {
            let logical = &name[prefix.len()..];
            let contract = if kind == "table" && table == name && TABLES.iter().any(|(known, _, _)| *known == logical) {
                let sql: Option<String> = row.get(3).map_err(|e| e.to_string())?;
                sql.filter(|sql| sql.len() <= 1024 * 1024).and_then(|sql| schema_contract(owner, &sql).ok())
            } else { None };
            record(owner, Object { name: logical.to_owned(), kind: kind.clone(), contract });
        }
        // A name outside the namespace can still be an index/trigger ON one
        // of its tables. It must invalidate the producer contract as well.
        if matches!(kind.as_str(), "index" | "trigger") {
            if let Some(dependent_owner) = table.get(..prefix.len()).filter(|value| Some(*value) != owner) {
                record(dependent_owner, Object { name: format!("@dependent:{name}"), kind, contract: None });
            }
        }
    }
    *cache = keep.then_some(Catalog { schema_version: version, prefix_len: prefix.len(), objects: catalog });
    Ok(selected)
}

pub(super) fn presence(pool: &Pool, path: &Path) -> Result<Option<bool>> {
    if !is_legacy_path(path) { return Ok(None); }
    let spec = crate::core::business_store_route::exact_store_spec(path)?;
    pool.with(|container| {
        // Registration, schema/hidden columns and row absence are one fact.
        // Never combine a pre-DDL catalog with post-DDL or post-write rows.
        let snapshot = container.connection().unchecked_transaction().map_err(|e| e.to_string())?;
        let registered: Option<(String, String, String, String, String)> = snapshot.query_row(
            "SELECT module,source_identity,logical_path,namespace_prefix,state FROM tb_stores WHERE store_id=?1",
            [&spec.id], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        ).optional().map_err(|e| e.to_string())?;
        let Some((module, source, logical, prefix, state)) = registered else { return Ok(Some(false)); };
        if module != "exact" || source != spec.source_identity || logical != spec.logical_path
            || prefix != spec.prefix || !matches!(state.as_str(), "ready" | "sealed") {
            return Err("旧暂存owner或状态不匹配，已保留任务".into());
        }
        let objects = objects(pool, &snapshot, &prefix)?;
        if objects.is_empty() { return Ok(Some(false)); }
        let mut names = objects.iter().map(|object| object.name.as_str()).collect::<Vec<_>>();
        names.sort_unstable();
        if names != ["chunks", "events", "fingerprints", "manifest"] || objects.iter().any(|object| object.kind != "table") {
            return Err("旧暂存结构不可识别，已保留任务".into());
        }
        let occupied = |name: &str| snapshot.query_row(
            &format!("SELECT EXISTS(SELECT 1 FROM {})", quote(&format!("{prefix}{name}"))), [], |row| row.get::<_, bool>(0),
        ).map_err(|e| e.to_string());
        if occupied("manifest")? { return Ok(Some(true)); }

        let layouts = known_layouts()?;
        let actual = TABLES.iter().map(|(name, _, _)| Ok((
            *name, objects.iter().find(|object| object.name == *name).and_then(|object| object.contract),
            columns(&snapshot, &format!("{prefix}{name}"))?,
        ))).collect::<Result<Vec<_>>>()?;
        let matched = layouts.iter().position(|layout| layout.tables.iter().zip(&actual).all(|(expected, actual)| {
            expected.0 == actual.0 && Some(expected.1) == actual.1 && expected.2 == actual.2
        }));
        let Some(matched) = matched else { return Err("空暂存并非受支持的producer布局，已保留".into()); };
        for name in ["events", "fingerprints", "chunks"] {
            if occupied(name)? { return Err("未封存暂存含有事实行，已保留并停止复用".into()); }
        }
        // Keep the known partial producer on the original restart/preservation
        // path. Only a complete, empty producer may be skipped as absent.
        Ok(Some(matched == 1))
    })
}
