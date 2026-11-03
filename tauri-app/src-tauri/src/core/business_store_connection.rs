//! A rusqlite-compatible facade for one logical store inside container A.
//!
//! The unbound constructors remain useful for isolated SQLite fixtures and
//! candidate snapshots. Production callers use `open_store` so every SQL
//! identifier is rewritten to that store's private namespace before SQLite
//! prepares it.

use crate::core::business_store_container::{BusinessStoreError, Container, StoreSpec};
use crate::core::business_store_sql::StoreSqlBinding;
use rusqlite::{
    functions::FunctionFlags,
    types::{ToSql, ToSqlOutput, Value},
    CachedStatement, Connection, OpenFlags, OptionalExtension, Params, Result, Row, Statement,
    TransactionBehavior,
};
use std::cell::RefCell;
use std::ops::Deref;
use std::path::Path;
use std::time::Duration;

pub(crate) struct StoreConnection {
    raw: Connection,
    binding: Option<RefCell<StoreSqlBinding>>,
    owner: Option<StoreSpec>,
}

impl StoreConnection {
    pub(crate) fn bound_with_owner(raw: Connection, binding: StoreSqlBinding, owner: StoreSpec) -> Result<Self> {
        let mut connection = Self::bound(raw, binding)?;
        connection.owner = Some(owner);
        Ok(connection)
    }

    pub(crate) fn bound_store_spec(&self) -> std::result::Result<StoreSpec, BusinessStoreError> {
        let owner = self.owner.as_ref().ok_or(BusinessStoreError::InvalidStore)?;
        let binding = self.binding.as_ref().ok_or(BusinessStoreError::InvalidStore)?.borrow();
        let (module, source, logical, prefix): (String, String, String, String) = self.raw.query_row(
            "SELECT module,source_identity,logical_path,namespace_prefix FROM tb_stores WHERE store_id=?1",
            [binding.store_id()], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?)))?;
        let store = StoreSpec::new(module, source, logical)?;
        if &store != owner || store.id != binding.store_id() || store.prefix != binding.prefix() || store.prefix != prefix {
            return Err(BusinessStoreError::InvalidStore);
        }
        Ok(store)
    }

    pub(crate) fn open(path: impl AsRef<Path>) -> Result<Self> {
        Connection::open(path).map(Self::unbound)
    }

    pub(crate) fn open_with_flags(path: impl AsRef<Path>, flags: OpenFlags) -> Result<Self> {
        Connection::open_with_flags(path, flags).map(Self::unbound)
    }

    pub(crate) fn open_in_memory() -> Result<Self> {
        Connection::open_in_memory().map(Self::unbound)
    }

    pub(crate) fn unbound(raw: Connection) -> Self {
        Self { raw, binding: None, owner: None }
    }

    pub(crate) fn bound(raw: Connection, binding: StoreSqlBinding) -> Result<Self> {
        let prefix = binding.prefix().to_owned();
        let namespace = binding.namespace().clone();
        // temp_store must be selected before the logical catalog views are
        // created: changing it later drops every TEMP object on this handle.
        raw.execute_batch("PRAGMA temp_store=FILE;")?;
        raw.create_scalar_function(
            "codex_tokenbar_unbind_sql",
            1,
            FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC,
            move |context| {
                let sql: Option<String> = context.get(0)?;
                sql.map(|sql| {
                    namespace.unbind(&sql).map_err(|error| {
                        rusqlite::Error::UserFunctionError(Box::new(std::io::Error::other(
                            format!("store catalog SQL unbinding failed: {error:?}"),
                        )))
                    })
                })
                .transpose()
            },
        )?;
        raw.execute_batch(&format!(
            "CREATE TEMP VIEW tb_logical_catalog(name,type,tbl_name,rootpage,sql) AS \
             SELECT substr(name,{after_prefix}) AS name,type, \
                    CASE WHEN substr(tbl_name,1,{prefix_len})='{prefix}' THEN substr(tbl_name,{after_prefix}) ELSE tbl_name END AS tbl_name, \
                    rootpage,codex_tokenbar_unbind_sql(sql) AS sql \
             FROM main.sqlite_master \
             WHERE substr(name,1,{prefix_len})='{prefix}' AND name NOT LIKE 'sqlite_%' \
             UNION ALL \
             SELECT 'sqlite_autoindex_' || substr(name,{autoindex_after_prefix}),type, \
                    substr(tbl_name,{after_prefix}),rootpage,NULL \
             FROM main.sqlite_master \
             WHERE substr(name,1,{autoindex_prefix_len})='sqlite_autoindex_{prefix}'; \
             CREATE TEMP VIEW tb_logical_sequence AS \
             SELECT substr(name,{after_prefix}) AS name,seq FROM main.sqlite_sequence \
             WHERE substr(name,1,{prefix_len})='{prefix}';",
            after_prefix = prefix.len() + 1,
            prefix_len = prefix.len(),
            autoindex_after_prefix = 18 + prefix.len(),
            autoindex_prefix_len = 17 + prefix.len(),
            prefix = prefix
        ))?;
        Ok(Self {
            raw,
            binding: Some(RefCell::new(binding)),
            owner: None,
        })
    }

    /// Open a standalone SQLite database with an explicitly scoped logical
    /// namespace. This is for small module-owned tables stored inside another
    /// app database: unlike `open_store`, it does not consult container A or
    /// require rows in `tb_stores`. The caller supplies a safe `s<id>_` prefix
    /// and the complete set of logical object names accepted by the binder.
    pub(crate) fn open_scoped(
        path: impl AsRef<Path>,
        store_id: impl Into<String>,
        prefix: impl Into<String>,
        object_names: impl IntoIterator<Item = String>,
    ) -> Result<Self> {
        let raw = Connection::open(path)?;
        let binding = StoreSqlBinding::new(store_id, prefix, object_names).map_err(|error| {
            rusqlite::Error::InvalidParameterName(format!("store SQL binding: {error:?}"))
        })?;
        Self::bound(raw, binding)
    }

    pub(crate) fn open_store(
        container_path: impl AsRef<Path>,
        store: &StoreSpec,
    ) -> std::result::Result<Self, BusinessStoreError> {
        Container::open(container_path)?.into_store_connection(store)
    }

    fn raw(&self) -> &Connection {
        &self.raw
    }

    fn raw_mut(&mut self) -> &mut Connection {
        &mut self.raw
    }

    fn into_raw(self) -> Connection {
        self.raw
    }

    fn bind_sql(&self, sql: &str) -> Result<String> {
        let Some(binding) = &self.binding else {
            return Ok(sql.to_owned());
        };
        binding.borrow_mut().sql(sql).map_err(|error| {
            rusqlite::Error::InvalidParameterName(format!("store SQL binding: {error:?}"))
        })
    }

    pub(crate) fn execute<P: Params>(&self, sql: &str, params: P) -> Result<usize> {
        let sql = self.bind_sql(sql)?;
        if sql.trim().is_empty() {
            return Ok(0);
        }
        self.raw.execute(&sql, params)
    }

    pub(crate) fn execute_batch(&self, sql: &str) -> Result<()> {
        let sql = self.bind_sql(sql)?;
        if sql.trim().is_empty() {
            return Ok(());
        }
        self.raw.execute_batch(&sql)
    }

    pub(crate) fn set_temporary_namespace_mode(&self, enabled: bool) -> Result<()> {
        let Some(binding) = &self.binding else {
            return Err(rusqlite::Error::InvalidQuery);
        };
        binding
            .borrow_mut()
            .set_temporary_namespace_enabled(enabled);
        Ok(())
    }

    pub(crate) fn prepare(&self, sql: &str) -> Result<Statement<'_>> {
        let sql = self.bind_sql(sql)?;
        self.raw.prepare(&sql)
    }

    pub(crate) fn prepare_cached(&self, sql: &str) -> Result<CachedStatement<'_>> {
        let sql = self.bind_sql(sql)?;
        self.raw.prepare_cached(&sql)
    }

    pub(crate) fn query_row<T, P, F>(&self, sql: &str, params: P, f: F) -> Result<T>
    where
        P: Params,
        F: FnOnce(&Row<'_>) -> Result<T>,
    {
        let sql = self.bind_sql(sql)?;
        self.raw.query_row(&sql, params, f)
    }

    pub(crate) fn pragma_update<T: ToSql + ?Sized>(
        &self,
        schema: Option<&str>,
        pragma_name: &str,
        value: &T,
    ) -> Result<()> {
        if self.binding.is_none() {
            return self.raw.pragma_update(schema, pragma_name, value);
        }
        if pragma_name.eq_ignore_ascii_case("user_version") {
            let store_id = self
                .binding
                .as_ref()
                .expect("binding checked above")
                .borrow()
                .store_id()
                .to_owned();
            let value = match value.to_sql()? {
                ToSqlOutput::Owned(value) => value,
                ToSqlOutput::Borrowed(value) => Value::from(value),
                _ => return Err(rusqlite::Error::InvalidQuery),
            };
            let version = match value {
                Value::Integer(value) if value >= 0 => value,
                Value::Text(value) => value
                    .parse::<i64>()
                    .ok()
                    .filter(|value| *value >= 0)
                    .ok_or(rusqlite::Error::InvalidQuery)?,
                _ => return Err(rusqlite::Error::InvalidQuery),
            };
            self.raw.execute(
                "UPDATE main.tb_stores SET user_version=?1, revision=revision+1 WHERE store_id=?2",
                rusqlite::params![version, store_id],
            )?;
            return Ok(());
        }
        self.raw.pragma_update(schema, pragma_name, value)
    }

    pub(crate) fn pragma_query_value<T, F>(
        &self,
        schema: Option<&str>,
        pragma_name: &str,
        f: F,
    ) -> Result<T>
    where
        F: FnOnce(&Row<'_>) -> Result<T>,
    {
        if self.binding.is_some() && pragma_name.eq_ignore_ascii_case("user_version") {
            return self.query_row("PRAGMA user_version", [], f);
        }
        self.raw.pragma_query_value(schema, pragma_name, f)
    }

    pub(crate) fn transaction(&mut self) -> Result<StoreTransaction<'_>> {
        self.transaction_with_behavior(TransactionBehavior::Deferred)
    }

    pub(crate) fn unchecked_transaction(&self) -> Result<StoreTransaction<'_>> {
        StoreTransaction::begin(self, TransactionBehavior::Deferred)
    }

    pub(crate) fn transaction_with_behavior(
        &mut self,
        behavior: TransactionBehavior,
    ) -> Result<StoreTransaction<'_>> {
        StoreTransaction::begin(self, behavior)
    }

    pub(crate) fn busy_timeout(&self, timeout: Duration) -> Result<()> {
        self.raw.busy_timeout(timeout)
    }

    pub(crate) fn last_insert_rowid(&self) -> i64 {
        self.raw.last_insert_rowid()
    }

    pub(crate) fn changes(&self) -> u64 {
        self.raw.changes()
    }

    pub(crate) fn total_changes(&self) -> u64 {
        self.raw.total_changes()
    }

    pub(crate) fn register_readonly_namespace_alias(
        &self,
        alias: &str,
        prefix: String,
        object_names: impl IntoIterator<Item = String>,
    ) -> Result<()> {
        if alias.is_empty()
            || !alias
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
        {
            return Err(rusqlite::Error::InvalidQuery);
        }
        let Some(binding) = &self.binding else {
            return Err(rusqlite::Error::InvalidQuery);
        };
        binding
            .borrow_mut()
            .register_attached_namespace(alias, prefix, object_names);
        Ok(())
    }

    pub(crate) fn unregister_namespace_alias(&self, alias: &str) -> Result<()> {
        let Some(binding) = &self.binding else {
            return Err(rusqlite::Error::InvalidQuery);
        };
        binding.borrow_mut().unregister_attached_namespace(alias);
        Ok(())
    }

    pub(crate) fn is_autocommit(&self) -> bool {
        self.raw.is_autocommit()
    }

    pub(crate) fn is_bound(&self) -> bool {
        self.binding.is_some()
    }

    /// Only private work areas can expose their raw handle. A bound A writer
    /// never escapes the namespace facade through this method.
    pub(crate) fn unbound_connection(&self) -> Result<&Connection> {
        if self.binding.is_some() {
            return Err(rusqlite::Error::InvalidQuery);
        }
        Ok(&self.raw)
    }

    fn exact_stage_pool(&self, owner: &str) -> std::result::Result<StoreSpec, String> {
        let main = self.raw.path().ok_or("暂存目标没有物理A")?;
        let active = crate::core::business_store_route::container_path()?;
        if std::fs::canonicalize(main).map_err(|e| e.to_string())?
            != std::fs::canonicalize(active).map_err(|e| e.to_string())?
        {
            return Err("暂存发布目标不是当前A".into());
        }
        let binding = self
            .binding
            .as_ref()
            .ok_or("暂存发布需要已绑定的Exact writer")?;
        if binding.borrow().store_id() != owner {
            return Err("暂存发布owner不匹配".into());
        }
        let module: String = self
            .raw
            .query_row(
                "SELECT module FROM tb_stores WHERE store_id=?1",
                [owner],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        if module != "exact" {
            return Err("非Exact owner不能消费暂存".into());
        }
        let pool = StoreSpec::new(
            "exact.rust.pool",
            "exact-stage-pool-v1",
            "exact/stage-pool-v1",
        )
        .map_err(|e| e.to_string())?;
        let valid: bool = self.raw.query_row("SELECT EXISTS(SELECT 1 FROM tb_stores WHERE store_id=?1 AND module=?2 AND source_identity=?3 AND namespace_prefix=?4 AND user_version=1 AND state='ready')", rusqlite::params![pool.id,pool.module,pool.source_identity,pool.prefix], |r| r.get(0)).map_err(|e|e.to_string())?;
        if !valid {
            return Err("暂存池合同不可用".into());
        }
        Ok(pool)
    }

    /// Typed same-A bridge. This is the per-file BUILDING transaction, not a
    /// consumption receipt. The receipt is written by the final publication.
    pub(crate) fn mark_exact_stage_pending(
        &self,
        owner: &str,
        job: &str,
        digest: &str,
        generation: i64,
    ) -> std::result::Result<(), String> {
        if self.raw.is_autocommit() || generation <= 0 {
            return Err("暂存关联必须在原导入事务内".into());
        }
        let p = self.exact_stage_pool(owner)?;
        let changed = self.raw.execute(&format!("UPDATE {}jobs SET pending_generation=?1 WHERE job_id=?2 AND owner=?3 AND digest=?4 AND state='sealed' AND (pending_generation IS NULL OR pending_generation=?1)",p.prefix), rusqlite::params![generation,job,owner,digest]).map_err(|e|e.to_string())?;
        if changed != 1 {
            return Err("暂存关联证明不匹配，已保留任务".into());
        }
        Ok(())
    }

    pub(crate) fn mark_exact_legacy_stage_pending(&self, stage_path: &Path, digest: &str, generation: i64) -> std::result::Result<(), String> {
        if self.raw.is_autocommit() || generation <= 0 { return Err("旧暂存关联必须在原导入事务内".into()); }
        let directory = stage_path.parent().ok_or("旧暂存缺少目录")?;
        let index_name = directory.file_name().and_then(|name|name.to_str()).and_then(|name|name.strip_suffix(".staging")).ok_or("旧暂存目录不属于Exact")?;
        let target = crate::core::business_store_route::exact_store_spec(&directory.with_file_name(index_name))?;
        let pool = self.exact_stage_pool(&target.id)?;
        let stage = crate::core::business_store_route::exact_store_spec(stage_path)?;
        if stage.id == target.id { return Err("主索引不能当作旧暂存消费".into()); }
        let proof = Container::exact_stage_proof_on_connection(&self.raw,&stage).map_err(|error|error.to_string())?;
        if format!("{}:{}",proof.schema_digest,proof.rows_digest) != digest { return Err("旧暂存导入证明发生变化".into()); }
        let key = format!("legacy:{}",stage.id);
        let phase = format!("pending:{generation}");
        let prior: Option<(String,String,String)> = self.raw.query_row(&format!("SELECT owner,base_proof,phase FROM {}operations WHERE operation_id=?1",pool.prefix),[&key],|row|Ok((row.get(0)?,row.get(1)?,row.get(2)?))).optional().map_err(|error|error.to_string())?;
        if let Some(prior) = prior {
            if prior != (target.id,digest.to_owned(),phase) { return Err("旧暂存已关联另一发布，保留原任务".into()); }
        } else {
            self.raw.execute(&format!("INSERT INTO {}operations(operation_id,owner,base_proof,phase) VALUES(?1,?2,?3,?4)",pool.prefix),rusqlite::params![key,target.id,digest,phase]).map_err(|error|error.to_string())?;
        }
        Ok(())
    }

    /// Final exact generation and its job receipts commit on this *same*
    /// handle. No caller gets arbitrary SQL access to another namespace.
    pub(crate) fn consume_exact_stage_generation(
        &self,
        generation: i64,
    ) -> std::result::Result<(), String> {
        if self.raw.is_autocommit() {
            return Err("暂存消费必须在正式发布事务内".into());
        }
        let binding = self.binding.as_ref().ok_or("正式发布缺少Exact owner")?;
        let owner = binding.borrow().store_id().to_owned();
        let p = StoreSpec::new(
            "exact.rust.pool",
            "exact-stage-pool-v1",
            "exact/stage-pool-v1",
        )
        .map_err(|e| e.to_string())?;
        let exists: bool = self
            .raw
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM tb_stores WHERE store_id=?1)",
                [&p.id],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        if !exists {
            return Ok(());
        }
        let p = self.exact_stage_pool(&owner)?;
        let published: Option<String> = self
            .raw
            .query_row(
                &format!(
                    "SELECT value FROM {}metadata WHERE key='published_generation'",
                    binding.borrow().prefix()
                ),
                [],
                |r| r.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        if published.as_deref() != Some(&generation.to_string()) {
            return Err("暂存消费与正式发布代不一致".into());
        }
        self.raw.execute(&format!("INSERT INTO {}publication_receipts(owner,job_id,payload_digest,generation) SELECT owner,job_id,digest,?1 FROM {}jobs WHERE owner=?2 AND pending_generation=?1 AND state='sealed'",p.prefix,p.prefix),rusqlite::params![generation,owner]).map_err(|e|e.to_string())?;
        self.raw.execute(&format!("UPDATE {}jobs SET state='consumed' WHERE owner=?1 AND pending_generation=?2 AND state='sealed'",p.prefix),rusqlite::params![owner,generation]).map_err(|e|e.to_string())?;
        self.raw.execute(&format!("INSERT INTO {}publication_receipts(owner,job_id,payload_digest,generation) SELECT owner,operation_id,base_proof,?1 FROM {}operations WHERE owner=?2 AND phase=?3 AND substr(operation_id,1,7)='legacy:'",p.prefix,p.prefix),rusqlite::params![generation,owner,format!("pending:{generation}")]).map_err(|error|error.to_string())?;
        self.raw.execute(&format!("UPDATE {}operations SET phase='consumed' WHERE owner=?1 AND phase=?2 AND substr(operation_id,1,7)='legacy:'",p.prefix),rusqlite::params![owner,format!("pending:{generation}")]).map_err(|error|error.to_string())?;
        Ok(())
    }

    /// The immutable artifact was verified before reaching this method.
    /// Mount just four typed tables in TEMP; no job-specific MAIN DDL or store.
    pub(crate) fn mount_exact_stage_rows(
        &self,
        owner: &str,
        alias: &str,
        source: &Connection,
    ) -> std::result::Result<(), String> {
        self.exact_stage_pool(owner)?;
        if !matches!(alias, "exact_stage_import" | "exact_enrichment_compare")
            || !self.raw.is_autocommit()
        {
            return Err("无效的暂存读取挂载".into());
        }
        let names = ["manifest", "events", "fingerprints", "chunks"];
        let prefix = format!("tb_{alias}_");
        self.unmount_exact_stage_rows(alias)
            .map_err(|e| e.to_string())?;
        let copied = (|| -> std::result::Result<(), String> {
            self.raw
                .execute_batch("BEGIN DEFERRED")
                .map_err(|e| e.to_string())?;
            for name in names {
                let mut info = source
                    .prepare(&format!("PRAGMA table_info({name})"))
                    .map_err(|e| e.to_string())?;
                let columns = info
                    .query_map([], |r| r.get::<_, String>(1))
                    .map_err(|e| e.to_string())?
                    .collect::<Result<Vec<_>>>()
                    .map_err(|e| e.to_string())?;
                if !(1..=64).contains(&columns.len()) {
                    return Err("暂存列合同无效".into());
                }
                let q = crate::core::business_store_sql::SQLiteStoreNamespace::quote;
                self.raw
                    .execute_batch(&format!(
                        "CREATE TEMP TABLE {}({})",
                        q(&format!("{prefix}{name}")),
                        columns.iter().map(|c| q(c)).collect::<Vec<_>>().join(",")
                    ))
                    .map_err(|e| e.to_string())?;
                let mut select = source
                    .prepare(&format!("SELECT * FROM {name}"))
                    .map_err(|e| e.to_string())?;
                let mut rows = select.query([]).map_err(|e| e.to_string())?;
                let mut insert = self
                    .raw
                    .prepare(&format!(
                        "INSERT INTO temp.{} VALUES({})",
                        q(&format!("{prefix}{name}")),
                        vec!["?"; columns.len()].join(",")
                    ))
                    .map_err(|e| e.to_string())?;
                while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                    struct RawCell<'a>(rusqlite::types::ValueRef<'a>);
                    impl ToSql for RawCell<'_> {
                        fn to_sql(&self) -> Result<ToSqlOutput<'_>> {
                            Ok(ToSqlOutput::Borrowed(self.0))
                        }
                    }
                    let values = (0..columns.len())
                        .map(|i| row.get_ref(i).map(RawCell))
                        .collect::<Result<Vec<_>>>()
                        .map_err(|e| e.to_string())?;
                    insert
                        .execute(rusqlite::params_from_iter(values))
                        .map_err(|e| e.to_string())?;
                }
            }
            self.raw
                .execute_batch("COMMIT")
                .map_err(|e| e.to_string())?;
            Ok(())
        })();
        if let Err(error) = copied {
            let _ = self.raw.execute_batch("ROLLBACK");
            let _ = self.unmount_exact_stage_rows(alias);
            return Err(error);
        }
        self.binding
            .as_ref()
            .ok_or("暂存挂载缺少owner")?
            .borrow_mut()
            .register_temporary_attached_namespace(
                alias,
                prefix,
                names.into_iter().map(str::to_owned),
            );
        Ok(())
    }

    pub(crate) fn unmount_exact_stage_rows(&self, alias: &str) -> Result<()> {
        if !matches!(alias, "exact_stage_import" | "exact_enrichment_compare") {
            return Err(rusqlite::Error::InvalidQuery);
        }
        let binding = self.binding.as_ref().ok_or(rusqlite::Error::InvalidQuery)?;
        binding.borrow_mut().unregister_attached_namespace(alias);
        for name in ["manifest", "events", "fingerprints", "chunks"] {
            self.raw
                .execute_batch(&format!("DROP TABLE IF EXISTS temp.tb_{alias}_{name}"))?;
        }
        Ok(())
    }

    pub(crate) fn has_logical_object(&self, name: &str) -> Result<bool> {
        if let Some(binding) = &self.binding {
            return Ok(binding.borrow().has_object(name));
        }
        self.raw.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name=?1)",
            [name],
            |row| row.get(0),
        )
    }
}

pub(crate) struct StoreTransaction<'connection> {
    connection: &'connection StoreConnection,
    finished: bool,
}

impl<'connection> StoreTransaction<'connection> {
    fn begin(
        connection: &'connection StoreConnection,
        behavior: TransactionBehavior,
    ) -> Result<Self> {
        let begin = match behavior {
            TransactionBehavior::Deferred => "BEGIN DEFERRED",
            TransactionBehavior::Immediate => "BEGIN IMMEDIATE",
            TransactionBehavior::Exclusive => "BEGIN EXCLUSIVE",
            _ => "BEGIN DEFERRED",
        };
        connection.execute_batch(begin)?;
        Ok(Self {
            connection,
            finished: false,
        })
    }

    pub(crate) fn commit(mut self) -> Result<()> {
        self.connection.execute_batch("COMMIT")?;
        self.finished = true;
        Ok(())
    }

    pub(crate) fn rollback(mut self) -> Result<()> {
        self.connection.execute_batch("ROLLBACK")?;
        self.finished = true;
        Ok(())
    }
}

impl Deref for StoreTransaction<'_> {
    type Target = StoreConnection;
    fn deref(&self) -> &Self::Target {
        self.connection
    }
}

impl Drop for StoreTransaction<'_> {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.connection.execute_batch("ROLLBACK");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::business_store_sql::StoreSqlBinding;

    fn bound() -> StoreConnection {
        let raw = Connection::open_in_memory().unwrap();
        raw.execute_batch("CREATE TABLE tb_stores(store_id TEXT PRIMARY KEY,user_version INTEGER); CREATE TABLE tb_store_objects(store_id TEXT,name TEXT,type TEXT,original_sql TEXT); INSERT INTO tb_stores VALUES('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',0);").unwrap();
        StoreConnection::bound(
            raw,
            StoreSqlBinding::new(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "saaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_",
                Vec::<String>::new(),
            )
            .unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn scoped_connection_namespaces_tables_without_container_metadata() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("shared.sqlite");
        let store_id = "b".repeat(64);
        let prefix = format!("s{store_id}_");
        let raw = Connection::open(&path).unwrap();
        raw.pragma_update(None, "user_version", 19_i64).unwrap();
        drop(raw);

        let store = StoreConnection::open_scoped(
            &path,
            store_id.clone(),
            prefix.clone(),
            ["events".to_owned()],
        )
        .unwrap();
        store
            .execute_batch("CREATE TABLE events(id TEXT PRIMARY KEY, value INTEGER) WITHOUT ROWID")
            .unwrap();
        store
            .execute("INSERT INTO events(id, value) VALUES('one', 7)", [])
            .unwrap();
        let value: i64 = store
            .query_row("SELECT value FROM events WHERE id='one'", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(value, 7);
        drop(store);

        let raw = Connection::open(&path).unwrap();
        let version: i64 = raw
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(version, 19);
        let physical: i64 = raw
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                [format!("{prefix}events")],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(physical, 1);
    }

    #[test]
    fn transaction_uses_bound_sql_and_rolls_back_on_drop() {
        let mut db = bound();
        db.execute_batch("CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT);")
            .unwrap();
        {
            let tx = db.transaction().unwrap();
            tx.execute(
                "INSERT INTO records VALUES (?1, ?2)",
                rusqlite::params![1, "x"],
            )
            .unwrap();
        }
        let count: i64 = db
            .query_row("SELECT COUNT(*) FROM records", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn user_version_is_scoped_to_container_metadata() {
        let db = bound();
        db.execute_batch("PRAGMA user_version = 7;").unwrap();
        let value: i64 = db
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        let physical: i64 = db
            .raw()
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(value, 7);
        assert_eq!(physical, 0);
    }

    #[test]
    fn namespaced_quick_checks_cover_all_stage_tables_and_isolate_siblings() {
        let db = bound();
        let prefix = format!("s{}_", "a".repeat(64));
        let stage_tables = ["manifest", "fingerprints", "events", "chunks"];
        for table in stage_tables {
            db.execute_batch(&format!(
                "CREATE TABLE {table}(value INTEGER NOT NULL CHECK(value >= 0)); INSERT INTO {table} VALUES(0);"
            ))
            .unwrap();
        }

        let sibling_table = format!("\"s{}_unrelated_guard\"", "b".repeat(64));
        db.raw()
            .execute_batch(&format!(
                "CREATE TABLE {sibling_table}(value INTEGER NOT NULL CHECK(value >= 0)); \
                 PRAGMA ignore_check_constraints=ON; INSERT INTO {sibling_table} VALUES(-1); \
                 PRAGMA ignore_check_constraints=OFF;"
            ))
            .unwrap();
        let whole_container_check: String = db
            .raw()
            .query_row("PRAGMA quick_check(1)", [], |row| row.get(0))
            .unwrap();
        assert_ne!(
            whole_container_check, "ok",
            "fixture must corrupt a sibling partition"
        );

        for table in stage_tables {
            let rows = db
                .prepare(&format!("PRAGMA quick_check('{table}')"))
                .unwrap()
                .query_map([], |row| row.get::<_, String>(0))
                .unwrap()
                .collect::<std::result::Result<Vec<_>, _>>()
                .unwrap();
            assert_eq!(
                rows,
                vec!["ok".to_owned()],
                "the check for {table} must ignore the sibling"
            );

            let physical_table = format!("\"{prefix}{table}\"");
            db.raw()
                .execute_batch(&format!(
                    "PRAGMA ignore_check_constraints=ON; INSERT INTO {physical_table} VALUES(-1); \
                     PRAGMA ignore_check_constraints=OFF;"
                ))
                .unwrap();
            let corrupt_rows = db
                .prepare(&format!("PRAGMA quick_check('{table}')"))
                .unwrap()
                .query_map([], |row| row.get::<_, String>(0))
                .unwrap()
                .collect::<std::result::Result<Vec<_>, _>>()
                .unwrap();
            assert_ne!(
                corrupt_rows,
                vec!["ok".to_owned()],
                "the check must detect corruption in {table}"
            );
            db.raw()
                .execute(&format!("DELETE FROM {physical_table} WHERE value < 0"), [])
                .unwrap();
        }
    }

    #[test]
    fn batched_version_and_ddl_bind_without_touching_other_namespaces() {
        let db = bound();
        db.execute_batch(
            "PRAGMA user_version=11; CREATE TABLE events(id INTEGER PRIMARY KEY, value TEXT);",
        )
        .unwrap();
        let version: i64 = db
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        let has_table: bool = db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='events')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let physical: i64 = db
            .raw()
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, 11);
        assert!(has_table);
        assert_eq!(physical, 0);
    }

    #[test]
    fn logical_catalog_and_pragma_metadata_follow_runtime_schema_changes() {
        let directory =
            std::env::temp_dir().join(format!("business-catalog-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("codex-ledger.sqlite");
        let container = Container::open(&path).unwrap();
        let store = StoreSpec::new("exact", "source-a", "exact/home-a").unwrap();
        container.register(&store).unwrap();
        let db = container.into_store_connection(&store).unwrap();
        db.execute_batch(
            "CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT UNIQUE); CREATE INDEX idx_events_value ON events(value);",
        )
        .unwrap();
        db.execute("INSERT INTO events(value) VALUES(?1)", ["first"])
            .unwrap();

        let mut statement = db
            .prepare("SELECT name,type,tbl_name,sql FROM main.sqlite_master WHERE name IN ('events','idx_events_value','sqlite_autoindex_events_1') ORDER BY name")
            .unwrap();
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        drop(statement);
        assert_eq!(rows.len(), 3);
        assert!(rows.iter().any(|row| {
            row.0 == "events"
                && row.1 == "table"
                && row.2 == "events"
                && row
                    .3
                    .as_deref()
                    .is_some_and(|sql| !sql.contains(&store.prefix))
        }));
        assert!(rows.iter().any(|row| {
            row.0 == "sqlite_autoindex_events_1" && row.2 == "events" && row.3.is_none()
        }));

        let table_info: i64 = db
            .query_row("PRAGMA table_info('events')", [], |row| row.get(0))
            .unwrap();
        assert_eq!(table_info, 0);
        let column_count: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('events')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(column_count, 2);
        let sequence: (String, i64) = db
            .query_row(
                "SELECT name,seq FROM sqlite_sequence WHERE name='events'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(sequence, ("events".into(), 1));

        db.execute_batch("DROP INDEX idx_events_value;").unwrap();
        let index_still_visible: bool = db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_events_value')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(!index_still_visible);
        drop(db);
        let _ = std::fs::remove_dir_all(directory);
    }
}
