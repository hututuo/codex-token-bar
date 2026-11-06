//! Exact-specific operations on an admitted store connection.
//!
//! Keep pool identity/version, staged row mounting and publication receipts
//! together. Every operation still uses the caller's original connection;
//! this module never opens a second writer or commits the caller's publication.

use super::StoreConnection;
use crate::core::business_store_container::{BusinessStoreResult, Container, StoreSpec};
use rusqlite::{
    types::{ToSql, ToSqlOutput},
    Connection, OptionalExtension, Result,
};
use std::path::Path;

// Shared by pool admission and the same-A publication bridge. Store identity
// remains v1 so existing jobs, receipts and virtual paths keep their owners.
pub(crate) const EXACT_STAGE_POOL_VERSION: i64 = 2;
pub(crate) fn exact_stage_pool_spec() -> BusinessStoreResult<StoreSpec> {
    StoreSpec::new("exact.rust.pool", "exact-stage-pool-v1", "exact/stage-pool-v1")
}

impl StoreConnection {
    pub(crate) fn preserves_legacy_exact_migration(&self, index: &Path) -> std::result::Result<bool, String> {
        use crate::core::business_store_route as route;
        let physical = Path::new(self.raw.path().ok_or("迁移保留检查缺少物理 A")?);
        let active = route::container_path()?;
        if std::fs::canonicalize(physical).map_err(|error| error.to_string())?
            != std::fs::canonicalize(&active).map_err(|error| error.to_string())? {
            return Err("迁移保留检查连接不是当前 A".into());
        }
        route::validate_exact_stage_container(&active)?;
        let snapshot = if self.raw.is_autocommit() {
            Some(self.raw.unchecked_transaction().map_err(|error| error.to_string())?)
        } else { None };
        let owner = self.bound_store_spec().map_err(|error| error.to_string())?;
        let result = route::preserves_legacy_exact_migration_on(&self.raw, index, &owner)?;
        if let Some(snapshot) = snapshot {
            snapshot.commit().map_err(|error| error.to_string())?;
        }
        Ok(result)
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
        let pool = exact_stage_pool_spec().map_err(|e| e.to_string())?;
        // A v1 pool may reach publication before the first staging lookup on
        // restart. Its unchanged receipt protocol remains supported; schema
        // upgrade belongs to Pool::open, never this caller-owned transaction.
        let valid: bool = self.raw.query_row("SELECT EXISTS(SELECT 1 FROM tb_stores WHERE store_id=?1 AND module=?2 AND source_identity=?3 AND namespace_prefix=?4 AND logical_path=?5 AND user_version IN (1,?6) AND state='ready')", rusqlite::params![pool.id,pool.module,pool.source_identity,pool.prefix,pool.logical_path,EXACT_STAGE_POOL_VERSION], |r| r.get(0)).map_err(|e|e.to_string())?;
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
        let p = exact_stage_pool_spec().map_err(|e| e.to_string())?;
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
}
