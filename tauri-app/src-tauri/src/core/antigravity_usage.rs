//! Local Antigravity ledger adapter. Field numbers and accounting follow the pinned
//! AgentSpeed METRICS 4.8 parser; shared database fixtures check the native/Rust contract.
use super::{file_identity, modified_ns, persist_source_update, read_checkpoint, UsageEvent};
use rusqlite::{Connection, OpenFlags};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

const MAX_BLOB: usize = 1 << 20;
const MAX_TOKENS: u64 = 10_000_000;
const STORE_NAMES: [&str; 4] = ["antigravity-cli", "antigravity", "antigravity-ide", "antigravity-acp"];

/// Resolve stores before discovery so the ledger sees both standalone and Orca
/// conversations. Explicit selections replace defaults and may name a parent.
pub(super) fn resolve_roots(home: &Path, selected: Option<&Path>) -> Vec<PathBuf> {
    if let Some(root) = selected {
        let name = root.file_name().and_then(|name| name.to_str()).unwrap_or("");
        let mut roots = vec![root.to_path_buf()];
        if name != "conversations" && !STORE_NAMES.contains(&name) && !name.ends_with("-backup") {
            roots.extend(STORE_NAMES.map(|store| root.join(store)));
        }
        return roots;
    }
    let mut roots: Vec<_> = STORE_NAMES.map(|store| home.join(".gemini").join(store)).into();
    if cfg!(target_os = "macos") {
        let orca = home.join("Library/Application Support/orca/antigravity-chat");
        roots.extend(["antigravity-acp", "antigravity-cli", "antigravity"].map(|store| orca.join(store)));
    }
    roots
}

pub(super) fn price_model(raw: &str) -> String {
    static RULES: std::sync::OnceLock<serde_json::Value> = std::sync::OnceLock::new();
    let table = RULES.get_or_init(|| {
        serde_json::from_str(super::BUNDLED_PRICE_TABLE).expect("validated bundled prices")
    });
    let key = raw.trim().to_lowercase();
    let catalog = super::bundled_api_price_catalog();
    let exact = |key: &str| catalog.identifiers.get(key).is_some_and(Option::is_some);
    if exact(&key)
        || table["unknown"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|rule| {
                rule["value"].as_str().is_some_and(|value| {
                    if rule["match"] == "prefix" {
                        key.starts_with(value)
                    } else {
                        key == value
                    }
                })
            })
    {
        return raw.into();
    }
    for rule in table["normalize"]["modifierSuffixes"]
        .as_array()
        .into_iter()
        .flatten()
    {
        if !rule["prefix"]
            .as_str()
            .is_some_and(|prefix| key.starts_with(prefix))
        {
            continue;
        }
        for suffix in rule["suffixes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str())
        {
            if let Some(base) = key.strip_suffix(suffix).filter(|base| exact(base)) {
                return base.into();
            }
        }
    }
    raw.into()
}

pub(super) fn conversations(root: &Path) -> PathBuf {
    if root.file_name().is_some_and(|name| name == "conversations") {
        root.to_path_buf()
    } else {
        root.join("conversations")
    }
}

pub(super) fn is_conversation(path: &Path) -> bool {
    path.file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|name| {
            name.strip_suffix(".db")
                .is_some_and(|stem| stem.len() == 36 && uuid::Uuid::parse_str(stem).is_ok())
        })
}

pub(super) fn discover(root: &Path) -> Result<(Vec<PathBuf>, bool), String> {
    let root = conversations(root);
    if root
        .parent()
        .and_then(Path::file_name)
        .and_then(|n| n.to_str())
        .is_some_and(|n| n.ends_with("-backup"))
        || !root.exists()
    {
        return Ok((Vec::new(), false));
    }
    let mut files = Vec::new();
    let mut truncated = false;
    for (visited, entry) in fs::read_dir(root).map_err(|e| e.to_string())?.enumerate() {
        if visited >= super::MAX_SCANNED_ENTRIES || files.len() >= super::MAX_FILES_PER_CLIENT {
            truncated = true;
            break;
        }
        let entry = entry.map_err(|e| e.to_string())?;
        if entry.file_type().map_err(|e| e.to_string())?.is_file() && is_conversation(&entry.path())
        {
            files.push(entry.path());
        }
    }
    files.sort();
    Ok((files, truncated))
}

pub(super) fn scan(ledger: &mut Connection, path: &Path) -> Result<Vec<String>, String> {
    if !is_conversation(path) {
        return Ok(Vec::new());
    }
    let metadata = fs::metadata(path).map_err(|e| e.to_string())?;
    let wal = fs::metadata(format!("{}-wal", path.display())).ok();
    let fingerprint = format!(
        "antigravity-v1:{}:{}:{}:{}",
        file_identity(&metadata),
        metadata.len(),
        modified_ns(&metadata),
        wal.map(|m| format!("{}:{}:{}", file_identity(&m), m.len(), modified_ns(&m)))
            .unwrap_or_else(|| "no-wal".into())
    );
    let path_key = path.to_string_lossy();
    if read_checkpoint(ledger, "antigravity", &path_key)
        .map_err(|e| e.to_string())?
        .is_some_and(|saved| saved.fingerprint.as_deref() == Some(&fingerprint))
    {
        return Ok(Vec::new());
    }
    // Save the pre-read stamp. A source that changes during the read is revisited;
    // completed records are still committed now and deduplicated on the next pass.
    let (events, malformed) = read(path)?;
    persist_source_update(
        ledger,
        "antigravity",
        &path_key,
        metadata.len().min(i64::MAX as u64) as i64,
        metadata.len(),
        modified_ns(&metadata),
        &fingerprint,
        events,
    )
    .map_err(|e| e.to_string())?;
    Ok(if malformed > 0 {
        vec![format!(
            "Antigravity：{malformed} 条记录字段无效，已保留可识别用量和旧账"
        )]
    } else {
        Vec::new()
    })
}

fn source_connection(path: &Path) -> Result<Connection, String> {
    let has_wal = PathBuf::from(format!("{}-wal", path.display())).exists();
    let file = fs::File::open(path).map_err(|e| e.to_string())?;
    let header =
        crate::core::shared_source_io::read_range(&file, 0, 20).map_err(|e| e.to_string())?;
    let closed_wal = !has_wal && header.len() >= 20 && (header[18] == 2 || header[19] == 2);
    let open = |immutable: bool| -> rusqlite::Result<Connection> {
        let mut uri = reqwest::Url::from_file_path(path)
            .map_err(|_| rusqlite::Error::InvalidPath(path.to_path_buf()))?;
        uri.query_pairs_mut().append_pair("mode", "ro");
        if immutable {
            uri.query_pairs_mut().append_pair("immutable", "1");
        }
        let connection = Connection::open_with_flags(
            uri.as_str(),
            OpenFlags::SQLITE_OPEN_READ_ONLY
                | OpenFlags::SQLITE_OPEN_URI
                | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.busy_timeout(Duration::from_millis(500))?;
        connection.execute_batch("PRAGMA query_only=ON; SELECT 1 FROM sqlite_master LIMIT 1;")?;
        Ok(connection)
    };
    open(closed_wal)
        .or_else(|error| {
            if !has_wal && !closed_wal {
                open(true)
            } else {
                Err(error)
            }
        })
        .map_err(|e| e.to_string())
}

#[derive(Clone, Copy)]
struct Field<'a> {
    number: u64,
    wire: u8,
    value: u64,
    bytes: &'a [u8],
}
struct Message<'a>(Vec<Field<'a>>);
type ParseResult<T> = Result<T, ()>;

fn varint(bytes: &[u8], position: &mut usize) -> ParseResult<u64> {
    let mut value = 0;
    for group in 0..10 {
        let byte = *bytes.get(*position).ok_or(())?;
        *position += 1;
        value |= ((byte & 127) as u64) << (7 * group);
        if byte & 128 == 0 {
            return Ok(value);
        }
    }
    Err(())
}

impl<'a> Message<'a> {
    fn parse(bytes: &'a [u8]) -> ParseResult<Self> {
        let mut position = 0;
        let mut fields = Vec::new();
        while position < bytes.len() {
            let key = varint(bytes, &mut position)?;
            if key >> 3 == 0 {
                return Err(());
            }
            let mut field = Field {
                number: key >> 3,
                wire: (key & 7) as u8,
                value: 0,
                bytes: &[],
            };
            match field.wire {
                0 => field.value = varint(bytes, &mut position)?,
                1 | 2 | 5 => {
                    let count = match field.wire {
                        1 => 8,
                        5 => 4,
                        _ => usize::try_from(varint(bytes, &mut position)?).map_err(|_| ())?,
                    };
                    let end = position.checked_add(count).ok_or(())?;
                    let payload = bytes.get(position..end).ok_or(())?;
                    if field.wire == 2 {
                        field.bytes = payload;
                    }
                    position = end;
                }
                _ => return Err(()),
            }
            fields.push(field);
        }
        Ok(Self(fields))
    }
    fn last(&self, number: u64, wire: u8) -> Option<&Field<'a>> {
        self.0
            .iter()
            .rev()
            .find(|f| f.number == number && f.wire == wire)
    }
    fn uint(&self, number: u64) -> u64 {
        self.last(number, 0).map_or(0, |f| f.value)
    }
    fn string(&self, number: u64) -> Option<String> {
        self.last(number, 2)
            .filter(|f| !f.bytes.is_empty())
            .map(|f| String::from_utf8_lossy(f.bytes).into_owned())
    }
    fn message(&self, number: u64) -> ParseResult<Option<Self>> {
        self.last(number, 2)
            .map(|f| Self::parse(f.bytes))
            .transpose()
    }
    fn timestamp(&self, number: u64) -> ParseResult<Option<i64>> {
        let Some(stamp) = self.message(number)? else {
            return Ok(None);
        };
        let seconds = stamp.uint(1) as i64;
        let nanos = stamp.uint(2) as i64;
        if seconds <= 0 {
            return Ok(None);
        }
        Ok(seconds.checked_mul(1000).and_then(|s| {
            s.checked_add(if (0..1_000_000_000).contains(&nanos) {
                nanos / 1_000_000
            } else {
                0
            })
        }))
    }
    fn repeated(&self, number: u64) -> ParseResult<Vec<u64>> {
        let mut values = Vec::new();
        for field in self.0.iter().filter(|f| f.number == number) {
            if field.wire == 0 {
                values.push(field.value);
            }
            if field.wire == 2 {
                let mut position = 0;
                while position < field.bytes.len() {
                    values.push(varint(field.bytes, &mut position)?);
                }
            }
        }
        Ok(values)
    }
}

fn generation(bytes: &[u8]) -> ParseResult<(Vec<u64>, Option<String>)> {
    let message = Message::parse(bytes)?;
    let model = message
        .message(1)?
        .and_then(|m| m.string(19).or_else(|| m.string(21)));
    Ok((message.repeated(2)?, model))
}
fn executor(bytes: &[u8]) -> ParseResult<(i64, Option<String>)> {
    let message = Message::parse(bytes)?;
    let model = match message.message(10)? {
        Some(config) => config.message(1)?.and_then(|m| m.string(28)),
        None => None,
    };
    Ok((message.uint(3) as i64, model))
}

fn optional_rows(
    source: &Connection,
    table: &str,
    has_size: bool,
) -> rusqlite::Result<Vec<(i64, Option<Vec<u8>>)>> {
    let guard = if has_size {
        format!("typeof(size)='integer' AND size <= {MAX_BLOB} AND ")
    } else {
        String::new()
    };
    let sql = format!("SELECT idx, CASE WHEN {guard}length(data) <= {MAX_BLOB} THEN data END FROM {table} WHERE idx > -1 ORDER BY idx,rowid");
    let Ok(mut statement) = source.prepare(&sql) else {
        return Ok(Vec::new());
    };
    let rows = statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect();
    rows
}

fn event(
    bytes: &[u8],
    session: &str,
    idx: i64,
    step_type: i64,
    status: i64,
    created_ms: Option<i64>,
    model: Option<String>,
) -> ParseResult<Option<UsageEvent>> {
    let message = Message::parse(bytes)?;
    let times = [1, 6, 7, 8, 22, 32]
        .map(|number| message.timestamp(number))
        .into_iter()
        .collect::<ParseResult<Vec<_>>>()?;
    if created_ms
        .zip(times[0])
        .is_some_and(|(created, step)| step < created - 2000)
    {
        return Ok(None);
    }
    let Some(usage) = message.message(9)? else {
        return Ok(None);
    };
    let [input, output, cached, thinking, response] = [2, 3, 5, 9, 10].map(|f| usage.uint(f));
    if [input, output, cached, thinking, response]
        .iter()
        .any(|n| *n > MAX_TOKENS)
    {
        return Err(());
    }
    if step_type != 15
        || [1, 2, 8, 9, 11].contains(&status)
        || input + output + cached + thinking + response == 0
    {
        return Ok(None);
    }
    let Some(timestamp_ms) = times[2]
        .or(times[4])
        .or(times[3])
        .or_else(|| times.iter().flatten().max().copied())
    else {
        return Ok(None);
    };
    let key = usage
        .string(11)
        .or_else(|| usage.string(7))
        .unwrap_or_else(|| format!("antigravity:{session}:{idx}"));
    Ok(Some(UsageEvent {
        client: "antigravity".into(),
        session_id: session.into(),
        event_id: format!("antigravity:{key}"),
        model: model.unwrap_or_else(|| "unknown".into()),
        timestamp_ms,
        input_tokens: input + cached,
        output_tokens: if output > 0 {
            output
        } else {
            thinking + response
        },
        cache_read_tokens: Some(cached),
        cache_write_tokens: Some(0),
        reasoning_tokens: Some(thinking),
        quality: "recorded".into(),
        ..UsageEvent::default()
    }))
}

pub(super) fn read(path: &Path) -> Result<(Vec<UsageEvent>, usize), String> {
    let source = source_connection(path)?;
    source.execute_batch("BEGIN").map_err(|e| e.to_string())?;
    let mut malformed = 0;
    let mut created_ms = None;
    if let Ok(mut statement) = source.prepare(&format!("SELECT CASE WHEN length(data) <= {MAX_BLOB} THEN data END FROM trajectory_metadata_blob ORDER BY rowid LIMIT 1")) {
        let mut rows = statement.query([]).map_err(|e| e.to_string())?;
        if let Some(row) = rows.next().map_err(|e| e.to_string())? {
            if let Some(bytes) = row.get::<_, Option<Vec<u8>>>(0).map_err(|e| e.to_string())? {
                match Message::parse(&bytes).and_then(|m| {
                    if let Some(workspace) = m.0.iter().find(|f| f.number == 1 && f.wire == 2) { Message::parse(workspace.bytes)?; }
                    m.timestamp(2)
                }) { Ok(value) => created_ms = value, Err(()) => malformed += 1 }
            }
        }
    }
    let mut generation_models = BTreeMap::<u64, Option<String>>::new();
    for (_, bytes) in optional_rows(&source, "gen_metadata", true).map_err(|e| e.to_string())? {
        if let Some(bytes) = bytes {
            match generation(&bytes) {
                Ok((steps, model)) => {
                    for step in steps {
                        generation_models
                            .entry(step)
                            .or_insert_with(|| model.clone());
                    }
                }
                Err(()) => malformed += 1,
            }
        }
    }
    let mut executors = Vec::new();
    for (idx, bytes) in
        optional_rows(&source, "executor_metadata", false).map_err(|e| e.to_string())?
    {
        if let Some(bytes) = bytes {
            match executor(&bytes) {
                Ok((last, model)) => executors.push((last, idx, model)),
                Err(()) => malformed += 1,
            }
        }
    }
    executors.sort_by_key(|(last, idx, _)| (*last, *idx));
    let sql = format!("SELECT idx,step_type,status,CASE WHEN length(metadata) <= {MAX_BLOB} THEN metadata END FROM steps WHERE idx > -1 ORDER BY idx,rowid");
    let mut statement = source
        .prepare(&sql)
        .map_err(|_| "Antigravity 数据库缺少可识别的 steps 字段".to_string())?;
    let mut rows = statement.query([]).map_err(|e| e.to_string())?;
    let session = path
        .file_stem()
        .and_then(|n| n.to_str())
        .ok_or("Antigravity 会话文件名无效")?;
    let mut events = BTreeMap::new();
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let idx: i64 = row.get(0).map_err(|e| e.to_string())?;
        let step_type: i64 = row.get(1).map_err(|e| e.to_string())?;
        let status: i64 = row.get(2).map_err(|e| e.to_string())?;
        let Some(bytes) = row
            .get::<_, Option<Vec<u8>>>(3)
            .map_err(|e| e.to_string())?
        else {
            continue;
        };
        let model = generation_models
            .get(&(idx as u64))
            .cloned()
            .flatten()
            .or_else(|| {
                executors
                    .iter()
                    .find(|(last, _, _)| *last >= idx)
                    .and_then(|(_, _, model)| model.clone())
            });
        match event(&bytes, session, idx, step_type, status, created_ms, model) {
            Ok(Some(event)) => {
                events.insert(event.event_id.clone(), event);
            }
            Ok(None) => (),
            Err(()) => malformed += 1,
        }
    }
    drop(rows);
    drop(statement);
    source.execute_batch("COMMIT").map_err(|e| e.to_string())?;
    Ok((events.into_values().collect(), malformed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;
    use serde_json::Value;

    fn fixtures() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Vendor/AgentSpeed/spec/fixtures")
    }
    fn ledger() -> Connection {
        let source = Connection::open_in_memory().unwrap();
        super::super::ensure_schema(&source, Path::new("antigravity-test.sqlite")).unwrap();
        source
    }
    #[test]
    fn resolves_acp_defaults_and_custom_parent_without_unrelated_stores() {
        let home = Path::new("/fixture-home");
        let roots = resolve_roots(home, None);
        assert_eq!(roots.len(), if cfg!(target_os = "macos") { 7 } else { 4 });
        assert!(roots.contains(&home.join(".gemini/antigravity-acp")));
        if cfg!(target_os = "macos") {
            assert!(roots.contains(&home.join("Library/Application Support/orca/antigravity-chat/antigravity-acp")));
        }
        for parent in [home.join(".gemini"), home.join("Library/Application Support/orca/antigravity-chat")] {
            let selected = resolve_roots(home, Some(&parent));
            assert_eq!(selected.len(), 5);
            assert!(selected.iter().all(|path| path.starts_with(&parent)));
            assert!(selected.contains(&parent.join("antigravity-acp")));
            for name in STORE_NAMES {
                let store = parent.join(name);
                assert_eq!(resolve_roots(home, Some(&store)), vec![store.clone()]);
                let folder = store.join("conversations");
                assert_eq!(resolve_roots(home, Some(&folder)), vec![folder]);
            }
            // Exercise the application's real preference resolver as well.
            assert_eq!(super::super::source_roots("antigravity", parent.to_str()), selected);
        }
        assert_eq!(super::super::source_roots("antigravity", Some("  ")),
            resolve_roots(&crate::core::app_paths::home_dir(), None));
    }

    #[test]
    fn standalone_and_orca_discovery_parse_and_ledger_deduplicate_steps() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path();
        let id = "11111111-2222-4333-8444-555555555555";
        let standalone = home.join(".gemini/antigravity");
        let orca = home.join("Library/Application Support/orca/antigravity-chat");
        let acp = orca.join("antigravity-acp");
        for store in [&standalone, &acp] {
            fs::create_dir_all(store.join("conversations")).unwrap();
        }
        let file = standalone.join("conversations").join(format!("{id}.db"));
        let writer = Connection::open(&file).unwrap();
        writer.execute_batch("CREATE TABLE steps(idx INTEGER,step_type INTEGER,status INTEGER,metadata BLOB)").unwrap();
        let metadata = [blob(1, uint(1, 1793000000)), blob(7, uint(1, 1793000003)),
            blob(9, [uint(2, 100), uint(3, 20)].concat())].concat();
        writer.execute("INSERT INTO steps VALUES(1,15,3,?1)", params![metadata]).unwrap();
        drop(writer);
        let copy = acp.join("conversations").join(format!("{id}.db"));
        fs::copy(&file, &copy).unwrap();
        let writer = Connection::open(&copy).unwrap();
        writer.execute("INSERT INTO steps VALUES(2,15,3,?1)", params![metadata]).unwrap();
        drop(writer);
        let mut roots = resolve_roots(home, None);
        if !cfg!(target_os = "macos") { roots.extend(resolve_roots(home, Some(&orca))); }
        let mut files = Vec::new();
        for root in roots {
            let (found, truncated) = discover(&root).unwrap();
            assert!(!truncated);
            files.extend(found);
        }
        files.sort();
        let mut expected = vec![file.clone(), copy.clone()]; expected.sort();
        assert_eq!(files, expected);
        for file in &files { assert_eq!(read(file).unwrap().1, 0); }
        assert_eq!(read(&copy).unwrap().0.iter().map(|event| event.event_id.clone()).collect::<Vec<_>>(),
            vec![format!("antigravity:antigravity:{id}:1"), format!("antigravity:antigravity:{id}:2")]);
        for selected in [&orca, &acp, &acp.join("conversations")] {
            let found = resolve_roots(home, Some(selected)).iter()
                .flat_map(|root| discover(root).unwrap().0).collect::<Vec<_>>();
            assert_eq!(found, vec![copy.clone()]);
        }
        let mut ledger = ledger();
        for _ in 0..2 { for file in &files { assert!(scan(&mut ledger, file).unwrap().is_empty()); } }
        let totals: (i64, i64, i64) = ledger.query_row(
            "SELECT COUNT(*),SUM(input_tokens),SUM(output_tokens) FROM client_usage_events", [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?))).unwrap();
        assert_eq!(totals, (2, 200, 40));
    }

    #[test]
    fn fixture_contract_discovery_ledger_dedupe_and_historical_totals() {
        let root = fixtures();
        let expected: Value =
            serde_json::from_slice(&fs::read(root.join("parser-expected.json")).unwrap()).unwrap();
        let mut known = std::collections::HashSet::new();
        let mut ledger = ledger();
        for relative in expected["antigravity"]["order"].as_array().unwrap() {
            let relative = relative.as_str().unwrap();
            let wanted = &expected["antigravity"]["databases"][relative];
            let file = root.join(relative);
            if wanted["unsupported"].as_bool() == Some(true) {
                assert!(read(&file).is_err());
                continue;
            }
            let (events, _) = read(&file).unwrap();
            let unique = events
                .iter()
                .filter(|event| known.insert(event.event_id.clone()))
                .collect::<Vec<_>>();
            let rows = wanted["responses"].as_array().unwrap();
            assert_eq!(unique.len(), rows.len(), "{relative}");
            for event in unique {
                let row = rows
                    .iter()
                    .find(|row| {
                        event.event_id == format!("antigravity:{}", row["key"].as_str().unwrap())
                    })
                    .unwrap();
                assert_eq!(event.input_tokens, row["input"].as_u64().unwrap());
                assert_eq!(event.output_tokens, row["output"].as_u64().unwrap());
                assert_eq!(event.cache_read_tokens, row["cachedInput"].as_u64());
                assert_eq!(event.reasoning_tokens, row["reasoning"].as_u64());
                assert_eq!(event.model, row["model"].as_str().unwrap_or("unknown"));
            }
            scan(&mut ledger, &file).unwrap();
            let revision: i64 = ledger
                .query_row("SELECT COUNT(*) FROM client_usage_revisions", [], |r| {
                    r.get(0)
                })
                .unwrap();
            scan(&mut ledger, &file).unwrap();
            assert_eq!(
                revision,
                ledger
                    .query_row("SELECT COUNT(*) FROM client_usage_revisions", [], |r| r
                        .get::<_, i64>(0))
                    .unwrap()
            );
        }
        let totals: (i64, i64, i64) = ledger
            .query_row(
                "SELECT COUNT(*),SUM(input_tokens),SUM(output_tokens) FROM client_usage_events",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(totals, (16, 106830, 3357));
        let mut discovered = Vec::new();
        for store in ["antigravity-cli", "antigravity", "antigravity-ide"] {
            discovered.extend(discover(&root.join("antigravity").join(store)).unwrap().0);
        }
        assert_eq!(discovered.len(), 11);
        assert!(discover(&root.join("antigravity/antigravity-backup"))
            .unwrap()
            .0
            .is_empty());
        assert!(discovered
            .iter()
            .all(|p| !p.to_string_lossy().contains("/old/")));
    }

    fn varint(mut value: u64) -> Vec<u8> {
        let mut bytes = Vec::new();
        loop {
            let mut byte = (value & 127) as u8;
            value >>= 7;
            if value > 0 {
                byte |= 128;
            }
            bytes.push(byte);
            if value == 0 {
                return bytes;
            }
        }
    }
    fn uint(key: u64, value: u64) -> Vec<u8> {
        [varint(key << 3), varint(value)].concat()
    }
    fn blob(key: u64, bytes: Vec<u8>) -> Vec<u8> {
        [varint((key << 3) | 2), varint(bytes.len() as u64), bytes].concat()
    }

    #[test]
    fn wal_completion_and_late_model_enrich_same_event_without_duplicate_tokens() {
        let directory =
            std::env::temp_dir().join(format!("tokenbar-antigravity-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&directory).unwrap();
        let file = directory.join("11111111-2222-4333-8444-555555555555.db");
        let writer = Connection::open(&file).unwrap();
        writer.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE steps(idx INTEGER,step_type INTEGER,status INTEGER,metadata BLOB); CREATE TABLE executor_metadata(idx INTEGER,data BLOB);").unwrap();
        let metadata = [
            blob(1, uint(1, 1793000000)),
            blob(7, uint(1, 1793000003)),
            blob(
                9,
                [
                    uint(2, 100),
                    uint(3, 20),
                    uint(5, 40),
                    uint(9, 5),
                    blob(11, b"wal-response".to_vec()),
                ]
                .concat(),
            ),
        ]
        .concat();
        writer
            .execute("INSERT INTO steps VALUES(1,15,8,?1)", params![metadata])
            .unwrap();
        let mut ledger = ledger();
        scan(&mut ledger, &file).unwrap();
        assert_eq!(
            ledger
                .query_row("SELECT COUNT(*) FROM client_usage_events", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            0
        );
        writer.execute_batch("UPDATE steps SET status=3").unwrap();
        scan(&mut ledger, &file).unwrap();
        let read_row = |ledger: &Connection| {
            ledger
                .query_row(
                    "SELECT model,input_tokens,output_tokens FROM client_usage_events",
                    [],
                    |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, i64>(1)?,
                            r.get::<_, i64>(2)?,
                        ))
                    },
                )
                .unwrap()
        };
        assert_eq!(read_row(&ledger), ("unknown".into(), 140, 20));
        let executor = [
            uint(3, 1),
            blob(10, blob(1, blob(28, b"gemini-4-argon".to_vec()))),
        ]
        .concat();
        writer
            .execute(
                "INSERT INTO executor_metadata VALUES(0,?1)",
                params![executor],
            )
            .unwrap();
        scan(&mut ledger, &file).unwrap();
        assert_eq!(read_row(&ledger), ("gemini-4-argon".into(), 140, 20));
        let expected_cost = super::super::api_cost_micro_usd_at(
            "gemini-4-argon",
            140,
            20,
            Some(40),
            Some(0),
            None,
            Some(1793000003.0),
        )
        .unwrap();
        assert!(expected_cost > 0);
        assert_eq!(
            ledger
                .query_row("SELECT COUNT(*) FROM client_usage_events", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
        drop(writer);
        drop(ledger);
        fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn malformed_wire_data_and_excessive_counts_never_become_usage() {
        for bytes in [vec![0], vec![10, 255], vec![15], vec![128; 11]] {
            assert!(Message::parse(&bytes).is_err());
        }
        let bytes = blob(9, uint(2, MAX_TOKENS + 1));
        assert!(event(&bytes, "s", 0, 15, 3, None, None).is_err());
        assert!(!is_conversation(Path::new(
            "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxé.db"
        )));
        for (raw, expected) in [
            ("gemini-4-argon-high", "gemini-4-argon"),
            ("claude-opus-4-6-thinking", "claude-opus-4-6"),
            ("gemini-3.8-flash-n", "gemini-3.8-flash-n"),
            ("gemini-pro-default", "gemini-pro-default"),
            ("private-model-high", "private-model-high"),
        ] {
            assert_eq!(price_model(raw), expected);
        }
    }
}
