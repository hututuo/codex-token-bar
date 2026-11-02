//! Fixed, owner-scoped numeric staging in A. No transcript or credential is
//! copied here; the existing Exact parser and final publication stay owners
//! of accounting semantics. New jobs are rows, never per-source stores.

use super::stage_row_codec::{decode_row, encode_row};
use crate::core::business_store_container::{Container, StoreSpec};
use crate::core::business_store_sql::SQLiteStoreNamespace;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, String>;
type Registry = Mutex<HashMap<PathBuf, Arc<Pool>>>;
fn registry() -> &'static Registry {
    static POOLS: OnceLock<Registry> = OnceLock::new();
    POOLS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn release_idle(pools: &mut HashMap<PathBuf, Arc<Pool>>) -> Result<()> {
    if pools.values().any(|p| Arc::strong_count(p) != 1) {
        return Err("暂存任务仍在使用A，不能进行离线维护".into());
    }
    pools.clear();
    Ok(())
}

/// An offline container operation must first quiesce business owners. Windows
/// SQLite holds A without FILE_SHARE_DELETE; do not rename a still-live file.
pub(super) fn with_idle_handles<T>(operation: impl FnOnce() -> Result<T>) -> Result<T> {
    let mut pools = registry().lock().map_err(|_| "暂存池注册锁失败")?;
    release_idle(&mut pools)?;
    // Retain the registry lease through the offline operation. Another worker
    // cannot reopen A in the gap between closing idle handles and renaming it.
    let result = operation();
    drop(pools);
    result
}
const TABLES: [(&str, usize, &str); 4] = [
    ("manifest", 35, "complete"),
    ("fingerprints", 1, "fingerprint"),
    ("events", 16, "ordinal"),
    ("chunks", 3, "chunk_index"),
];

pub(super) struct Pool {
    container: Mutex<Container>,
    path: PathBuf,
    identity: String,
    pub(super) store: StoreSpec,
}
#[derive(Clone)]
pub(super) struct Job {
    pub(super) id: String,
    pub(super) owner: String,
    source: String,
    base: String,
    contract: String,
    pub(super) path: PathBuf,
}
pub(super) struct Seal {
    pub(super) digest: String,
    pub(super) bytes: u64,
    rows: i64,
    pub(super) time: f64,
}

fn hash(fields: &[&[u8]]) -> String {
    let mut h = Sha256::new();
    for field in fields {
        update(&mut h, field);
    }
    format!("{:x}", h.finalize())
}
fn update(h: &mut Sha256, bytes: &[u8]) {
    h.update((bytes.len() as u64).to_be_bytes());
    h.update(bytes);
}
fn quote(s: &str) -> String {
    SQLiteStoreNamespace::quote(s)
}
fn identity(path: &Path) -> Result<String> {
    if std::fs::symlink_metadata(path)
        .map_err(|e| e.to_string())?
        .file_type()
        .is_symlink()
    {
        return Err("暂存池拒绝符号链接A".into());
    }
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let metadata = file.metadata().map_err(|e| e.to_string())?;
    if !metadata.is_file() {
        return Err("暂存池A不是普通文件".into());
    }
    super::physical_file_stamp(&file, &metadata)?
        .map(|s| format!("{}:{}", s.volume, s.file_id))
        .ok_or_else(|| "暂存池无法确认A物理身份".into())
}
fn pool_spec() -> Result<StoreSpec> {
    StoreSpec::new(
        "exact.rust.pool",
        "exact-stage-pool-v1",
        "exact/stage-pool-v1",
    )
    .map_err(|e| e.to_string())
}
pub(super) fn is_path(path: &Path) -> bool {
    path.extension().and_then(|s| s.to_str()) == Some("stage")
        && path
            .parent()
            .and_then(Path::parent)
            .and_then(Path::file_name)
            .and_then(|s| s.to_str())
            == Some(".exact-stage-pool-rust-v1")
}

impl Pool {
    /// Retain one schema-loaded connection. Growing the old catalog must not
    /// make every manifest/count query reopen and reparse A.
    pub(super) fn current() -> Result<Arc<Self>> {
        let path = crate::core::business_store_route::container_path()?;
        crate::core::business_store_route::validate_exact_stage_container(&path)?;
        let mut pools = registry().lock().map_err(|_| "暂存池注册锁失败")?;
        if let Some(pool) = pools.get(&path) {
            if identity(&path)? == pool.identity {
                return Ok(pool.clone());
            }
        }
        let pool = Arc::new(Self::open(&path)?);
        // Application has one active A; retain only its handle after source
        // switching. In-flight Arcs retain their own verified old identity.
        pools.clear();
        pools.insert(path, pool.clone());
        Ok(pool)
    }
    fn open(path: &Path) -> Result<Self> {
        let physical = identity(path)?;
        let container = Container::open_existing(path).map_err(|e| e.to_string())?;
        if identity(path)? != physical {
            return Err("暂存池打开期间A被替换".into());
        }
        let store = pool_spec()?;
        let pool = Self {
            container: Mutex::new(container),
            path: path.to_path_buf(),
            identity: physical,
            store,
        };
        pool.access(true,|container| {
            let c=container.connection();
            let found:Option<(i64,String,String,String,String)>=c.query_row("SELECT user_version,module,source_identity,namespace_prefix,state FROM tb_stores WHERE store_id=?1",[&pool.store.id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional().map_err(|e|e.to_string())?;
            if let Some((version,module,source,prefix,state))=found {
                if version!=1 || module!=pool.store.module || source!=pool.store.source_identity || prefix!=pool.store.prefix || state!="ready" { return Err("暂存池格式不可识别，已保留旧账和任务".into()); }
            } else {
                let other:bool=c.query_row("SELECT EXISTS(SELECT 1 FROM tb_stores WHERE module LIKE 'exact.rust.pool%')",[],|r|r.get(0)).map_err(|e|e.to_string())?;
                if other { return Err("未知暂存池模块，停止新增写入".into()); }
                super::stage_pool_backup::ensure(path,c)?;
                c.execute_batch("BEGIN IMMEDIATE").map_err(|e|e.to_string())?;
                let result=(||->Result<()> {
                    container.register(&pool.store).map_err(|e|e.to_string())?;
                    let namespace=SQLiteStoreNamespace::new(pool.store.prefix.clone(),pool.schema().iter().map(|(n,_)|n.clone()));
                    for (name,sql) in pool.schema() {
                        c.execute_batch(&sql).map_err(|e|e.to_string())?;
                        let kind=if name.starts_with("guard_"){ "trigger" }else{"table"};
                        c.execute("INSERT INTO tb_store_objects VALUES(?1,?2,?3,?4)",params![pool.store.id,name,kind,namespace.unbind(&sql).map_err(|e|format!("{e:?}"))?]).map_err(|e|e.to_string())?;
                    }
                    c.execute("UPDATE tb_stores SET user_version=1 WHERE store_id=?1",[&pool.store.id]).map_err(|e|e.to_string())?;
                    c.execute_batch("COMMIT").map_err(|e|e.to_string())?; Ok(())
                })();
                if result.is_err() { let _=c.execute_batch("ROLLBACK"); } result?;
            }
            let mut stmt=c.prepare("SELECT name,sql FROM sqlite_master WHERE substr(name,1,?1)=?2 AND sql IS NOT NULL ORDER BY name").map_err(|e|e.to_string())?;
            let actual=stmt.query_map(params![pool.store.prefix.len(),pool.store.prefix],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))).map_err(|e|e.to_string())?.collect::<std::result::Result<HashMap<_,_>,_>>().map_err(|e|e.to_string())?;
            if actual.len()!=pool.schema().len() { return Err("暂存池结构数量不匹配".into()); }
            for (name,sql) in pool.schema() {
                if actual.get(&format!("{}{name}",pool.store.prefix)).map(|s|s.trim_end_matches(';'))!=Some(sql.trim_end_matches(';')) { return Err("暂存池结构合同不匹配".into()); }
            }
            Ok(())
        })?;
        Ok(pool)
    }
    fn with<T>(&self, f: impl FnOnce(&Container) -> Result<T>) -> Result<T> {
        self.access(false, f)
    }
    fn access<T>(&self, preparing: bool, f: impl FnOnce(&Container) -> Result<T>) -> Result<T> {
        let c = self.container.lock().map_err(|_| "暂存池锁失败")?;
        if identity(&self.path)? != self.identity {
            return Err("业务A已替换，停止暂存池写入".into());
        }
        let state: Option<String> = c
            .connection()
            .query_row(
                "SELECT value FROM tb_container_meta WHERE key='activation_state'",
                [],
                |r| r.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        // Windows uses its initialized marker as the published commit point;
        // it did not write Swift's optional activation_state metadata.
        if state.as_deref().is_some_and(|s| s != "ready") {
            return Err("业务A尚未激活，保留暂存任务".into());
        }
        let version: Option<i64> = c
            .connection()
            .query_row(
                "SELECT user_version FROM tb_stores WHERE store_id=?1 AND state='ready'",
                [&self.store.id],
                |r| r.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        if version != Some(1) && !(preparing && version.is_none()) {
            return Err("暂存池版本或注册状态不可用".into());
        }
        f(&c)
    }
    fn table(&self, name: &str) -> String {
        quote(&format!("{}{name}", self.store.prefix))
    }
    fn schema(&self) -> Vec<(String, String)> {
        let jobs = self.table("jobs");
        let receipts = self.table("publication_receipts");
        let mut out=vec![
            ("operations".into(),format!("CREATE TABLE {}(operation_id TEXT PRIMARY KEY NOT NULL,owner TEXT NOT NULL,base_proof TEXT NOT NULL,phase TEXT NOT NULL) WITHOUT ROWID",self.table("operations"))),
            ("jobs".into(),format!("CREATE TABLE {jobs}(job_id TEXT PRIMARY KEY NOT NULL,owner TEXT NOT NULL,source_path TEXT NOT NULL,base_proof TEXT NOT NULL,contract_digest TEXT NOT NULL,logical_path TEXT NOT NULL UNIQUE,operation_id TEXT NOT NULL,codec INTEGER NOT NULL,state TEXT NOT NULL CHECK(state IN ('building','sealed','consumed','reclaimed')),manifest BLOB,digest TEXT,byte_count INTEGER,row_count INTEGER,sealed_at REAL,pending_generation INTEGER) WITHOUT ROWID")),
            ("publication_receipts".into(),format!("CREATE TABLE {receipts}(owner TEXT NOT NULL,job_id TEXT PRIMARY KEY NOT NULL,payload_digest TEXT NOT NULL,generation INTEGER NOT NULL) WITHOUT ROWID")),
        ];
        for name in ["event_rows", "fingerprints", "chunks"] {
            let t = self.table(name);
            out.push((name.into(),format!("CREATE TABLE {t}(job_id TEXT NOT NULL REFERENCES {jobs}(job_id),ordinal INTEGER NOT NULL CHECK(ordinal>=0),payload BLOB NOT NULL CHECK(length(payload)<=16777216),PRIMARY KEY(job_id,ordinal)) WITHOUT ROWID")));
            for action in ["INSERT", "UPDATE", "DELETE"] {
                let name = format!("guard_{name}_{}", action.to_ascii_lowercase());
                let row = if action == "INSERT" { "NEW" } else { "OLD" };
                let permitted = if action == "DELETE" {
                    format!("state='building' OR (state='consumed' AND EXISTS(SELECT 1 FROM {receipts} r WHERE r.job_id={row}.job_id AND r.owner={jobs}.owner AND r.payload_digest={jobs}.digest))")
                } else {
                    "state='building'".into()
                };
                out.push((name.clone(),format!("CREATE TRIGGER {} BEFORE {action} ON {t} WHEN NOT EXISTS(SELECT 1 FROM {jobs} WHERE job_id={row}.job_id AND ({permitted})) BEGIN SELECT RAISE(ABORT,'immutable stage payload'); END",self.table(&name))));
            }
        }
        out.push(("guard_job_facts".into(),format!("CREATE TRIGGER {} BEFORE UPDATE OF owner,source_path,base_proof,contract_digest,logical_path,operation_id,codec,manifest,digest,byte_count,row_count,sealed_at ON {jobs} WHEN OLD.state<>'building' BEGIN SELECT RAISE(ABORT,'immutable stage seal'); END",self.table("guard_job_facts"))));
        out.push(("guard_job_delete".into(),format!("CREATE TRIGGER {} BEFORE DELETE ON {jobs} BEGIN SELECT RAISE(ABORT,'retain stage receipt header'); END",self.table("guard_job_delete"))));
        out.push(("guard_job_state".into(),format!("CREATE TRIGGER {} BEFORE UPDATE OF state ON {jobs} WHEN NOT (NEW.state=OLD.state OR (OLD.state='building' AND NEW.state='sealed' AND NEW.manifest IS NOT NULL AND NEW.digest IS NOT NULL AND NEW.byte_count>=0 AND NEW.row_count>0) OR (OLD.state='sealed' AND NEW.state='consumed' AND EXISTS(SELECT 1 FROM {receipts} r WHERE r.job_id=OLD.job_id AND r.owner=OLD.owner AND r.payload_digest=OLD.digest)) OR (OLD.state='consumed' AND NEW.state='reclaimed' AND NOT EXISTS(SELECT 1 FROM {} WHERE job_id=OLD.job_id) AND NOT EXISTS(SELECT 1 FROM {} WHERE job_id=OLD.job_id) AND NOT EXISTS(SELECT 1 FROM {} WHERE job_id=OLD.job_id))) BEGIN SELECT RAISE(ABORT,'invalid stage transition'); END",self.table("guard_job_state"),self.table("event_rows"),self.table("fingerprints"),self.table("chunks"))));
        for action in ["UPDATE", "DELETE"] {
            let name = format!("guard_receipt_{}", action.to_ascii_lowercase());
            out.push((name.clone(),format!("CREATE TRIGGER {} BEFORE {action} ON {receipts} BEGIN SELECT RAISE(ABORT,'immutable publication receipt'); END",self.table(&name))));
        }
        out
    }
    fn base(&self, target: &StoreSpec, c: &Connection) -> Result<String> {
        let valid:bool=c.query_row("SELECT EXISTS(SELECT 1 FROM tb_stores WHERE store_id=?1 AND module='exact' AND namespace_prefix=?2)",params![target.id,target.prefix],|r|r.get(0)).map_err(|e|e.to_string())?;
        if !valid {
            return Err("暂存目标Exact owner未注册".into());
        }
        let mut s=c.prepare(&format!("SELECT key,value FROM {} WHERE key IN ('published_generation','attribution_provenance_epoch') ORDER BY key",quote(&format!("{}metadata",target.prefix)))).map_err(|e|e.to_string())?;
        let fields = s
            .query_map([], |r| {
                Ok(format!(
                    "{}={}",
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?
                ))
            })
            .map_err(|e| e.to_string())?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
        Ok(hash(
            &fields.iter().map(|s| s.as_bytes()).collect::<Vec<_>>(),
        ))
    }
    pub(super) fn job(&self, target: &StoreSpec, source: &str, contract: &[u8]) -> Result<Job> {
        self.with(|c| {
            let base = self.base(target, c.connection())?;
            let contract = format!("{:x}", Sha256::digest(contract));
            let id = hash(&[
                b"exact-stage-job-v1",
                target.id.as_bytes(),
                source.as_bytes(),
                base.as_bytes(),
                contract.as_bytes(),
            ]);
            let path = self
                .path
                .parent()
                .ok_or("A缺少父目录")?
                .join(".exact-stage-pool-rust-v1")
                .join(&target.id)
                .join(format!("{id}.stage"));
            Ok(Job {
                id,
                owner: target.id.clone(),
                source: source.into(),
                base,
                contract,
                path,
            })
        })
    }
    pub(super) fn lookup(&self, path: &Path) -> Result<Option<Job>> {
        if !is_path(path)
            || path.parent().and_then(Path::parent)
                != self
                    .path
                    .parent()
                    .map(|p| p.join(".exact-stage-pool-rust-v1"))
                    .as_deref()
        {
            return Err("暂存路径不属于当前A".into());
        }
        let name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .ok_or("暂存路径无效")?;
        self.with(|c|c.connection().query_row(&format!("SELECT owner,source_path,base_proof,contract_digest,codec,logical_path FROM {} WHERE job_id=?1",self.table("jobs")),[name],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?,r.get::<_,i64>(4)?,r.get::<_,String>(5)?))).optional().map_err(|e|e.to_string()).and_then(|v|v.map(|(owner,source,base,contract,codec,logical)|{
            if codec!=1 || Path::new(&logical)!=path || path.parent().and_then(Path::file_name).and_then(|s|s.to_str())!=Some(&owner) || name!=hash(&[b"exact-stage-job-v1",owner.as_bytes(),source.as_bytes(),base.as_bytes(),contract.as_bytes()]) { return Err("暂存job身份或codec不匹配".into()); }
            Ok(Job{id:name.into(),owner,source,base,contract,path:path.to_path_buf()})
        }).transpose()))
    }
    pub(super) fn candidates(&self, target: &StoreSpec, source: &str) -> Result<Vec<PathBuf>> {
        self.with(|c|{
            let mut s=c.connection().prepare(&format!("SELECT logical_path,codec FROM {} WHERE owner=?1 AND source_path=?2 AND base_proof=?3 AND state='sealed' ORDER BY sealed_at DESC,job_id",self.table("jobs"))).map_err(|e|e.to_string())?;
            let rows=s.query_map(params![target.id,source,self.base(target,c.connection())?],|r|Ok((r.get::<_,String>(0)?,r.get::<_,i64>(1)?))).map_err(|e|e.to_string())?;
            rows.map(|r|{let(p,v)=r.map_err(|e|e.to_string())?;if v!=1{return Err("未知暂存codec".into());}Ok(PathBuf::from(p))}).collect()
        })
    }
    pub(super) fn legacy_candidates(&self, index: &Path, source_digest: &str) -> Result<Vec<PathBuf>> {
        self.with(|c|crate::core::business_store_route::exact_stage_candidates_on(c.connection(),index,source_digest))
    }
    pub(super) fn seal(&self, job: &Job) -> Result<Option<Seal>> {
        self.with(|c|{
            let v=c.connection().query_row(&format!("SELECT codec,state,digest,byte_count,row_count,sealed_at,owner,contract_digest FROM {} WHERE job_id=?1",self.table("jobs")),[&job.id],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?,r.get::<_,Option<String>>(2)?,r.get::<_,Option<i64>>(3)?,r.get::<_,Option<i64>>(4)?,r.get::<_,Option<f64>>(5)?,r.get::<_,String>(6)?,r.get::<_,String>(7)?))).optional().map_err(|e|e.to_string())?;
            let Some((codec,state,digest,bytes,rows,date,owner,contract))=v else {return Ok(None)};
            if codec!=1 || owner!=job.owner || contract!=job.contract {return Err("暂存封存身份不匹配".into());}
            if !matches!(state.as_str(),"sealed"|"consumed"){return Ok(None)}
            match (digest,bytes,rows,date) { (Some(digest),Some(bytes),Some(rows),Some(time)) if bytes>=0 && rows>0 && time.is_finite() =>Ok(Some(Seal{digest,bytes:bytes as u64,rows,time})),_=>Err("暂存seal无效".into()) }
        })
    }
    pub(super) fn footprint(source: &Connection) -> Result<u64> {
        let mut count = 0u64;
        for (name, _, order) in TABLES {
            count = count
                .checked_add(name.len() as u64 + 1)
                .ok_or("暂存长度溢出")?;
            let mut s = source
                .prepare(&format!("SELECT * FROM {name} ORDER BY {order}"))
                .map_err(|e| e.to_string())?;
            let mut rows = s.query([]).map_err(|e| e.to_string())?;
            while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                count = count
                    .checked_add((encode_row(row).map_err(|e| e.to_string())?.len() - 8) as u64)
                    .ok_or("暂存长度溢出")?;
            }
        }
        Ok(count)
    }
    pub(super) fn persist(&self, job: &Job, source: &Connection) -> Result<()> {
        let names=source.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").map_err(|e|e.to_string())?.query_map([],|r|r.get::<_,String>(0)).map_err(|e|e.to_string())?.collect::<std::result::Result<Vec<_>,_>>().map_err(|e|e.to_string())?;
        if names != ["chunks", "events", "fingerprints", "manifest"] {
            return Err("暂存表合同不匹配".into());
        }
        let facts:(i64,String,i64,i64,i64,i64)=source.query_row("SELECT complete,path,event_count,fingerprint_count,chunk_count,actual_bytes FROM manifest",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).map_err(|e|e.to_string())?;
        let bytes = Self::footprint(source)?;
        if facts.0 != 1
            || facts.1 != job.source
            || u64::try_from(facts.5).ok() != Some(bytes)
            || source
                .query_row("SELECT COUNT(*) FROM manifest", [], |r| r.get::<_, i64>(0))
                .map_err(|e| e.to_string())?
                != 1
        {
            return Err("暂存manifest合同不匹配".into());
        }
        for (name, count) in [
            ("events", facts.2),
            ("fingerprints", facts.3),
            ("chunks", facts.4),
        ] {
            if count < 0
                || source
                    .query_row(&format!("SELECT COUNT(*) FROM {name}"), [], |r| {
                        r.get::<_, i64>(0)
                    })
                    .map_err(|e| e.to_string())?
                    != count
            {
                return Err("暂存行数量不匹配".into());
            }
        }
        let operation = hash(&[job.owner.as_bytes(), job.base.as_bytes()]);
        self.with(|c|{let tx=c.connection().unchecked_transaction().map_err(|e|e.to_string())?;
            let state:Option<String>=tx.query_row(&format!("SELECT state FROM {} WHERE job_id=?1",self.table("jobs")),[&job.id],|r|r.get(0)).optional().map_err(|e|e.to_string())?;
            if state.as_deref().is_some_and(|s|s!="building"){return Err("封存任务不能重写".into());}
            tx.execute(&format!("INSERT OR IGNORE INTO {} VALUES(?1,?2,?3,'staging')",self.table("operations")),params![operation,job.owner,job.base]).map_err(|e|e.to_string())?;
            tx.execute(&format!("INSERT OR IGNORE INTO {}(job_id,owner,source_path,base_proof,contract_digest,logical_path,operation_id,codec,state) VALUES(?1,?2,?3,?4,?5,?6,?7,1,'building')",self.table("jobs")),params![job.id,job.owner,job.source,job.base,job.contract,job.path.to_str().ok_or("非UTF8暂存路径")?,operation]).map_err(|e|e.to_string())?;
            for name in ["event_rows","fingerprints","chunks"] {tx.execute(&format!("DELETE FROM {} WHERE job_id=?1",self.table(name)),[&job.id]).map_err(|e|e.to_string())?;}
            tx.commit().map_err(|e|e.to_string())
        })?;
        let mut h = Sha256::new();
        let mut total = 0i64;
        let mut manifest = None;
        for (name, cols, order) in TABLES {
            update(&mut h, name.as_bytes());
            let mut s = source
                .prepare(&format!("SELECT * FROM {name} ORDER BY {order}"))
                .map_err(|e| e.to_string())?;
            let mut rows = s.query([]).map_err(|e| e.to_string())?;
            let mut batch = Vec::<(i64, Vec<u8>)>::new();
            let mut batch_bytes = 0;
            let mut ordinal = 0;
            let flush = |batch: &mut Vec<(i64, Vec<u8>)>| -> Result<()> {
                if batch.is_empty() {
                    return Ok(());
                }
                self.with(|c| {
                    let tx = c
                        .connection()
                        .unchecked_transaction()
                        .map_err(|e| e.to_string())?;
                    {
                        let physical = if name == "events" { "event_rows" } else { name };
                        let mut insert = tx
                            .prepare(&format!(
                                "INSERT INTO {} VALUES(?1,?2,?3)",
                                self.table(physical)
                            ))
                            .map_err(|e| e.to_string())?;
                        for (ordinal, data) in batch.iter() {
                            insert
                                .execute(params![job.id, ordinal, data])
                                .map_err(|e| e.to_string())?;
                        }
                    }
                    tx.commit().map_err(|e| e.to_string())
                })?;
                batch.clear();
                Ok(())
            };
            while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                if row.as_ref().column_count() != cols {
                    return Err("暂存列版本不匹配".into());
                }
                let data = encode_row(row).map_err(|e| e.to_string())?;
                update(&mut h, &data);
                total = total.checked_add(1).ok_or("暂存行溢出")?;
                if name == "manifest" {
                    manifest = Some(data);
                } else {
                    batch_bytes += data.len();
                    batch.push((ordinal, data));
                    if batch.len() >= 512 || batch_bytes >= 1_048_576 {
                        flush(&mut batch)?;
                        batch_bytes = 0;
                    }
                }
                ordinal += 1;
            }
            flush(&mut batch)?;
        }
        let digest = format!("{:x}", h.finalize());
        let manifest = manifest.ok_or("暂存缺少manifest")?;
        let time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs_f64();
        self.with(|c|{let changed=c.connection().execute(&format!("UPDATE {} SET manifest=?1,digest=?2,byte_count=?3,row_count=?4,sealed_at=?5,state='sealed' WHERE job_id=?6 AND owner=?7 AND state='building' AND contract_digest=?8",self.table("jobs")),params![manifest,digest,i64::try_from(bytes).map_err(|e|e.to_string())?,total,time,job.id,job.owner,job.contract]).map_err(|e|e.to_string())?;if changed!=1{return Err("暂存封存失效".into());}Ok(())})
    }
    pub(super) fn restore(&self, job: &Job) -> Result<Connection> {
        let seal = self.seal(job)?.ok_or("暂存尚未封存")?;
        let work = Connection::open("").map_err(|e| e.to_string())?;
        work.execute_batch("PRAGMA temp_store=FILE; PRAGMA cache_size=-4096;")
            .map_err(|e| e.to_string())?;
        work.execute_batch(&super::staging_schema_sql(false))
            .map_err(|e| e.to_string())?;
        let mut h = Sha256::new();
        let mut total = 0i64;
        self.with(|c|{let tx=work.unchecked_transaction().map_err(|e|e.to_string())?;
            for(name,cols,_)in TABLES {update(&mut h,name.as_bytes());let mut insert=tx.prepare(&format!("INSERT INTO {name} VALUES({})",vec!["?";cols].join(","))).map_err(|e|e.to_string())?;
                let mut copy=|bytes:Vec<u8>|->Result<()>{let cells=decode_row(&bytes,cols).map_err(|e|e.to_string())?;insert.execute(params_from_iter(cells.iter())).map_err(|e|e.to_string())?;update(&mut h,&bytes);total+=1;Ok(())};
                if name=="manifest" {copy(c.connection().query_row(&format!("SELECT manifest FROM {} WHERE job_id=?1 AND length(manifest)<=16777216",self.table("jobs")),[&job.id],|r|r.get(0)).map_err(|e|e.to_string())?)?;}
                else {let physical=if name=="events"{"event_rows"}else{name};let mut s=c.connection().prepare(&format!("SELECT payload FROM {} WHERE job_id=?1 ORDER BY ordinal",self.table(physical))).map_err(|e|e.to_string())?;let mut rows=s.query([&job.id]).map_err(|e|e.to_string())?;while let Some(row)=rows.next().map_err(|e|e.to_string())?{copy(row.get(0).map_err(|e|e.to_string())?)?;}}
            }tx.commit().map_err(|e|e.to_string())
        })?;
        if total != seal.rows
            || format!("{:x}", h.finalize()) != seal.digest
            || Self::footprint(&work)? != seal.bytes
        {
            return Err("暂存内容与封存证明不匹配".into());
        }
        work.pragma_update(None, "query_only", true)
            .map_err(|e| e.to_string())?;
        Ok(work)
    }
    pub(super) fn reclaim(&self, job: &Job) -> Result<()> {
        self.with(|c|{
            c.connection().busy_timeout(std::time::Duration::from_millis(50)).map_err(|error|error.to_string())?;
            let result = (|| { let tx=c.connection().unchecked_transaction().map_err(|e|e.to_string())?;
            let state:Option<String>=tx.query_row(&format!("SELECT j.state FROM {} j JOIN {} r ON r.job_id=j.job_id AND r.owner=j.owner AND r.payload_digest=j.digest WHERE j.job_id=?1 AND j.owner=?2 AND j.contract_digest=?3",self.table("jobs"),self.table("publication_receipts")),params![job.id,job.owner,job.contract],|r|r.get(0)).optional().map_err(|e|e.to_string())?;
            if state.as_deref()==Some("reclaimed"){return Ok(())} if state.as_deref()!=Some("consumed"){return Ok(())}
            for name in ["event_rows","fingerprints","chunks"] {tx.execute(&format!("DELETE FROM {} WHERE job_id=?1",self.table(name)),[&job.id]).map_err(|e|e.to_string())?;}
            tx.execute(&format!("UPDATE {} SET state='reclaimed' WHERE job_id=?1",self.table("jobs")),[&job.id]).map_err(|e|e.to_string())?;tx.commit().map_err(|e|e.to_string())
            })();
            let _ = c.connection().busy_timeout(std::time::Duration::from_secs(30));
            result
        })
    }

    pub(super) fn legacy_digest(&self, path: &Path) -> Result<String> {
        let stage = crate::core::business_store_route::exact_store_spec(path)?;
        self.with(|container| {
            let tx = container.connection().unchecked_transaction().map_err(|error|error.to_string())?;
            let proof = Container::exact_stage_proof_on_connection(&tx, &stage).map_err(|error|error.to_string())?;
            tx.commit().map_err(|error|error.to_string())?;
            Ok(format!("{}:{}",proof.schema_digest,proof.rows_digest))
        })
    }

    pub(super) fn reclaim_published(&self, maximum: usize, budget: std::time::Duration) -> Result<usize> {
        if !(1..=16).contains(&maximum) { return Err("清理批次超出上限".into()); }
        crate::core::business_store_route::validate_exact_stage_container(&self.path)?;
        let started = std::time::Instant::now();
        let paths = self.with(|container| {
            let mut statement = container.connection().prepare(&format!("SELECT logical_path FROM {} WHERE state='consumed' LIMIT ?1",self.table("jobs"))).map_err(|error|error.to_string())?;
            let rows = statement.query_map([maximum as i64],|row|row.get::<_,String>(0)).map_err(|error|error.to_string())?;
            rows.map(|row|row.map(PathBuf::from).map_err(|error|error.to_string())).collect::<Result<Vec<_>>>()
        })?;
        let mut done = 0;
        for path in paths {
            if started.elapsed() >= budget { return Ok(done); }
            if let Some(job) = self.lookup(&path)? { self.reclaim(&job)?; done += 1; }
        }
        if done >= maximum || started.elapsed() >= budget { return Ok(done); }
        let mut container = self.container.lock().map_err(|_| "暂存池锁失败")?;
        if identity(&self.path)? != self.identity { return Err("清理前A身份已变化".into()); }
        let candidates = {
            let mut statement = container.connection().prepare(&format!("SELECT s.module,s.source_identity,s.logical_path,r.owner,r.payload_digest FROM {} r JOIN {} o ON o.operation_id=r.job_id AND o.owner=r.owner AND o.base_proof=r.payload_digest JOIN tb_stores s ON r.job_id='legacy:'||s.store_id WHERE o.phase='consumed' AND s.module='exact' LIMIT ?1",self.table("publication_receipts"),self.table("operations"))).map_err(|error|error.to_string())?;
            let rows = statement.query_map([(maximum-done) as i64],|row|Ok((row.get::<_,String>(0)?,row.get::<_,String>(1)?,row.get::<_,String>(2)?,row.get::<_,String>(3)?,row.get::<_,String>(4)?))).map_err(|error|error.to_string())?;
            rows.collect::<std::result::Result<Vec<_>,_>>().map_err(|error|error.to_string())?
        };
        for (module,source,logical,owner,digest) in candidates {
            if started.elapsed() >= budget { break; }
            let stage = StoreSpec::new(module,source,logical).map_err(|error|error.to_string())?;
            let version = {
                let tx = container.connection().unchecked_transaction().map_err(|error|error.to_string())?;
                let proof = Container::exact_stage_proof_on_connection(&tx,&stage).map_err(|error|error.to_string())?;
                if format!("{}:{}",proof.schema_digest,proof.rows_digest) != digest { return Err("已消费的旧暂存发生变化，保留证据".into()); }
                let version = tx.query_row("PRAGMA data_version",[],|row|row.get::<_,i64>(0)).map_err(|error|error.to_string())?;
                tx.commit().map_err(|error|error.to_string())?;
                version
            };
            container.connection().busy_timeout(std::time::Duration::from_millis(50)).map_err(|error|error.to_string())?;
            let result = container.reclaim_consumed_exact_stage(&stage,&owner,&self.store,&digest,version).map_err(|error|error.to_string());
            let _ = container.connection().busy_timeout(std::time::Duration::from_secs(30));
            result?;
            done += 1;
        }
        Ok(done)
    }
}

pub(crate) fn start_background_maintenance() {
    use std::sync::atomic::{AtomicBool,Ordering};
    static STARTED: AtomicBool = AtomicBool::new(false);
    if STARTED.swap(true,Ordering::AcqRel) { return; }
    let started = std::thread::Builder::new().name("exact-stage-maintenance".into()).spawn(|| {
        let mut delay = std::time::Duration::from_secs(30);
        let mut last_error = None;
        loop {
            std::thread::sleep(delay);
            delay = std::time::Duration::from_secs(30);
            if crate::core::business_startup::process_coordinator().ensure_ready().is_err() { continue; }
            let began = std::time::Instant::now();
            let result = (|| {
                let path = crate::core::business_store_route::container_path()?;
                let has_pool = {
                    let container = Container::open_read_only_existing(path,std::time::Duration::from_millis(250)).map_err(|error|error.to_string())?;
                    container.connection().query_row("SELECT EXISTS(SELECT 1 FROM tb_stores WHERE module='exact.rust.pool')",[],|row|row.get::<_,bool>(0)).map_err(|error|error.to_string())?
                };
                if !has_pool { return Ok(0); }
                Pool::current()?.reclaim_published(4,std::time::Duration::from_millis(250))
            })();
            match result {
                Ok(count) => { last_error = None; if count > 0 { delay = std::time::Duration::from_secs(2); } }
                Err(error) => { delay = std::time::Duration::from_secs(60); if last_error.as_ref() != Some(&error) { eprintln!("Exact stage maintenance deferred: {error}"); last_error = Some(error); } }
            }
            delay = delay.max(began.elapsed().saturating_mul(4));
        }
    });
    if started.is_err() { STARTED.store(false,Ordering::Release); }
}

#[cfg(test)]
mod tests;

#[cfg(all(feature = "business-store-fixture", not(test)))]
pub(super) fn verify_fixture() -> Result<serde_json::Value> {
    let pool = Pool::current()?;
    let container = Container::open_existing(&pool.path).map_err(|e| e.to_string())?;
    let target = StoreSpec::new(
        "exact",
        "fixed-stage-contract-fixture",
        "exact/testing/fixed-stage-contracts",
    )
    .map_err(|e| e.to_string())?;
    container.register(&target).map_err(|e| e.to_string())?;
    let mut writer = container
        .into_store_connection(&target)
        .map_err(|e| e.to_string())?;
    writer.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);INSERT INTO metadata VALUES('published_generation','1'),('fixture_tokens','123')").map_err(|e|e.to_string())?;
    let raw = Connection::open(&pool.path).map_err(|e| e.to_string())?;
    let count = || -> Result<(i64, i64)> {
        Ok((
            raw.query_row("SELECT COUNT(*) FROM sqlite_master", [], |r| r.get(0))
                .map_err(|e| e.to_string())?,
            raw.query_row("SELECT COUNT(*) FROM tb_stores", [], |r| r.get(0))
                .map_err(|e| e.to_string())?,
        ))
    };
    let before = count()?;
    for i in 0..13 {
        let source = format!("/fixed-pool-fixture/{i}.jsonl");
        let job = pool.job(&target, &source, source.as_bytes())?;
        let work = seed_fixture_stage(&source)?;
        pool.persist(&job, &work)?;
        let seal = pool.seal(&job)?.ok_or("fixture missing seal")?;
        let restored = pool.restore(&job)?;
        if restored.execute("DELETE FROM events", []).is_ok() || writer.unbound_connection().is_ok()
        {
            return Err("fixture bypassed read-only or writer binding".into());
        }
        writer.mount_exact_stage_rows(&target.id, "exact_stage_import", &restored)?;
        let values: (i64, i64) = writer
            .query_row(
                "SELECT tokens,cached_input_tokens FROM exact_stage_import.events",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(|e| e.to_string())?;
        if values != (11, 8)
            || writer
                .execute("DELETE FROM exact_stage_import.events", [])
                .is_ok()
        {
            return Err("fixture typed TEMP alias or read-only guard failed".into());
        }
        writer
            .unmount_exact_stage_rows("exact_stage_import")
            .map_err(|e| e.to_string())?;
        {
            let tx = writer.transaction().map_err(|e| e.to_string())?;
            tx.mark_exact_stage_pending(&target.id, &job.id, &seal.digest, 2)?;
            tx.execute(
                "UPDATE metadata SET value='999' WHERE key='fixture_tokens'",
                [],
            )
            .map_err(|e| e.to_string())?;
            tx.execute(
                "UPDATE metadata SET value='2' WHERE key='published_generation'",
                [],
            )
            .map_err(|e| e.to_string())?;
            tx.consume_exact_stage_generation(2)?;
            // deliberate rollback of both facts and receipts
        }
        if writer
            .query_row(
                "SELECT value FROM metadata WHERE key='fixture_tokens'",
                [],
                |r| r.get::<_, String>(0),
            )
            .map_err(|e| e.to_string())?
            != "123"
        {
            return Err("fixture publication rollback lost prior facts".into());
        }
        {
            let tx = writer.transaction().map_err(|e| e.to_string())?;
            tx.mark_exact_stage_pending(&target.id, &job.id, &seal.digest, 2)?;
            tx.execute(
                "UPDATE metadata SET value='2' WHERE key='published_generation'",
                [],
            )
            .map_err(|e| e.to_string())?;
            tx.consume_exact_stage_generation(2)?;
            tx.commit().map_err(|e| e.to_string())?;
        }
        pool.reclaim(&job)?;
        pool.reclaim(&job)?;
        if pool.restore(&job).is_ok() || count()? != before {
            return Err("fixture failed job-only cleanup/catalog bound".into());
        }
    }
    let legacy = verify_legacy_receipts(&pool)?;
    Ok(
        serde_json::json!({"jobs":13,"catalogGrowth":0,"storeGrowth":0,"typedTempAlias":true,"readOnly":true,"publicationRollback":true,"idempotentCleanup":true,"legacy":legacy}),
    )
}

#[cfg(all(feature = "business-store-fixture", not(test)))]
fn verify_legacy_receipts(pool: &Arc<Pool>) -> Result<serde_json::Value> {
    // Clear only already-consumed, proven queue entries left by other checks.
    for _ in 0..64 { if pool.reclaim_published(16,std::time::Duration::from_secs(2))? == 0 { break; } }
    let index = pool.path.with_file_name("fixed-pool-legacy-index.sqlite3");
    let mut directory = index.as_os_str().to_os_string(); directory.push(".staging");
    let path = PathBuf::from(directory).join(format!("{}.sqlite3","a".repeat(64)));
    let target = crate::core::business_store_route::exact_store_spec(&index)?;
    let stage = crate::core::business_store_route::exact_store_spec(&path)?;
    let container = Container::open_existing(&pool.path).map_err(|error|error.to_string())?;
    container.register(&target).map_err(|error|error.to_string())?;
    container.register(&stage).map_err(|error|error.to_string())?;
    let mut writer = container.into_store_connection(&target).map_err(|error|error.to_string())?;
    writer.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO metadata VALUES('published_generation','1'),('fixture_tokens','123')").map_err(|error|error.to_string())?;
    let container = Container::open_existing(&pool.path).map_err(|error|error.to_string())?;
    let legacy = container.into_store_connection(&stage).map_err(|error|error.to_string())?;
    legacy.execute_batch(&super::staging_schema_sql(false)).map_err(|error|error.to_string())?;
    let work = seed_fixture_stage("/fixed-pool-legacy-source.jsonl")?;
    for (table, columns, _) in TABLES {
        let mut select = work.prepare(&format!("SELECT * FROM {table}")).map_err(|error|error.to_string())?;
        let mut rows = select.query([]).map_err(|error|error.to_string())?;
        while let Some(row) = rows.next().map_err(|error|error.to_string())? {
            let cells = (0..columns).map(|column|row.get::<_,rusqlite::types::Value>(column)).collect::<std::result::Result<Vec<_>,_>>().map_err(|error|error.to_string())?;
            legacy.execute(&format!("INSERT INTO {table} VALUES({})",vec!["?";columns].join(",")),params_from_iter(cells)).map_err(|error|error.to_string())?;
        }
    }
    let digest = pool.legacy_digest(&path)?;
    {
        let tx = writer.transaction().map_err(|error|error.to_string())?;
        tx.mark_exact_legacy_stage_pending(&path,&digest,2)?;
        tx.execute("UPDATE metadata SET value='2' WHERE key='published_generation'",[]).map_err(|error|error.to_string())?;
        tx.consume_exact_stage_generation(2)?;
        // Intentionally roll back both formal generation and its receipt.
    }
    if pool.reclaim_published(4,std::time::Duration::from_secs(2))? != 0 { return Err("legacy rollback became a cleanup receipt".into()); }
    { let tx = writer.transaction().map_err(|error|error.to_string())?;
      tx.mark_exact_legacy_stage_pending(&path,&digest,2)?; tx.commit().map_err(|error|error.to_string())?; }
    if pool.reclaim_published(4,std::time::Duration::from_secs(2))? != 0 { return Err("legacy BUILDING artifact was deleted before final publication".into()); }
    { let tx = writer.transaction().map_err(|error|error.to_string())?;
      tx.execute("UPDATE metadata SET value='2' WHERE key='published_generation'",[]).map_err(|error|error.to_string())?;
      tx.execute("UPDATE metadata SET value='134' WHERE key='fixture_tokens'",[]).map_err(|error|error.to_string())?;
      tx.consume_exact_stage_generation(2)?; tx.commit().map_err(|error|error.to_string())?; }
    legacy.execute("UPDATE events SET tokens=99",[]).map_err(|error|error.to_string())?;
    if pool.reclaim_published(4,std::time::Duration::from_secs(2)).is_ok() { return Err("changed legacy evidence was accepted for deletion".into()); }
    legacy.execute("UPDATE events SET tokens=11",[]).map_err(|error|error.to_string())?;
    if pool.reclaim_published(1,std::time::Duration::from_secs(2))? != 1 || pool.reclaim_published(1,std::time::Duration::from_secs(2))? != 0 {
        return Err("legacy receipt cleanup was not idempotent".into());
    }
    let container = Container::open_read_only_existing(&pool.path,std::time::Duration::from_secs(1)).map_err(|error|error.to_string())?;
    if container.is_registered(&stage).map_err(|error|error.to_string())? { return Err("consumed legacy namespace retained after cleanup".into()); }
    let tokens: String = writer.query_row("SELECT value FROM metadata WHERE key='fixture_tokens'",[],|row|row.get(0)).map_err(|error|error.to_string())?;
    if tokens != "134" { return Err("legacy cleanup changed formal facts".into()); }
    Ok(serde_json::json!({"rollback":true,"buildingKept":true,"changedEvidenceKept":true,"idempotent":true,"publishedTokens":134}))
}

#[cfg(any(test, feature = "business-store-fixture"))]
fn seed_fixture_stage(source: &str) -> Result<Connection> {
    let work = Connection::open("").map_err(|e| e.to_string())?;
    work.execute_batch(&super::staging_schema_sql(false))
        .map_err(|e| e.to_string())?;
    let mut info = work
        .prepare("PRAGMA table_info(manifest)")
        .map_err(|e| e.to_string())?;
    let columns = info
        .query_map([], |r| Ok((r.get::<_, String>(1)?, r.get::<_, String>(2)?)))
        .map_err(|e| e.to_string())?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    use rusqlite::types::Value;
    let values = columns
        .iter()
        .map(|(name, kind)| match name.as_str() {
            "path" => Value::Text(source.into()),
            "complete" | "event_count" | "fingerprint_count" | "chunk_count" => Value::Integer(1),
            "staging_mode" => Value::Text("full".into()),
            _ if kind == "TEXT" => Value::Text("fixture".into()),
            _ => Value::Integer(0),
        })
        .collect::<Vec<_>>();
    work.execute(
        &format!(
            "INSERT INTO manifest VALUES({})",
            vec!["?"; columns.len()].join(",")
        ),
        params_from_iter(values),
    )
    .map_err(|e| e.to_string())?;
    work.execute_batch("INSERT INTO events VALUES(0,100,11,9,8,2,0,'fixture',NULL,NULL,NULL,NULL,0,NULL,0,x'0001');INSERT INTO fingerprints VALUES(x'0001');INSERT INTO chunks VALUES(0,100,x'00ff')").map_err(|e|e.to_string())?;
    let bytes = Pool::footprint(&work)?;
    work.execute("UPDATE manifest SET actual_bytes=?1", [bytes as i64])
        .map_err(|e| e.to_string())?;
    drop(info);
    Ok(work)
}
