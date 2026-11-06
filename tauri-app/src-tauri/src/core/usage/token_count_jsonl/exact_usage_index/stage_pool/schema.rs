//! One additive v1 -> v2 migration. Index, catalog and version commit together;
//! no job data, owner identity or publication protocol changes.
use super::*;

pub(super) const CANDIDATE_INDEX: &str = "jobs_sealed_candidates";

fn object_kind(sql: &str) -> Result<&'static str> {
    match sql.split_whitespace().nth(1) {
        Some("TABLE") => Ok("table"),
        Some("TRIGGER") => Ok("trigger"),
        Some("INDEX") => Ok("index"),
        _ => Err("未知暂存池结构对象".into()),
    }
}

impl Pool {
    pub(super) fn candidate_index(&self) -> (String, String) {
        (CANDIDATE_INDEX.into(), format!(
            "CREATE INDEX {} ON {}(owner,source_path,base_proof,sealed_at DESC,job_id,logical_path,codec) WHERE state='sealed'",
            self.table(CANDIDATE_INDEX), self.table("jobs")))
    }

    fn registered_version(&self, c: &Connection) -> Result<Option<i64>> {
        let found = c.query_row(
            "SELECT user_version,module,source_identity,namespace_prefix,logical_path,state FROM tb_stores WHERE store_id=?1",
            [&self.store.id], |r| Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?,r.get::<_,String>(4)?,r.get::<_,String>(5)?)))
            .optional().map_err(|e|e.to_string())?;
        match found {
            Some((version, module, source, prefix, logical, state)) => {
                if !matches!(version, 1 | EXACT_STAGE_POOL_VERSION)
                    || module != self.store.module
                    || source != self.store.source_identity
                    || prefix != self.store.prefix
                    || logical != self.store.logical_path
                    || state != "ready"
                {
                    return Err("暂存池格式不可识别，已保留旧账和任务".into());
                }
                Ok(Some(version))
            }
            None => {
                let other: bool = c.query_row("SELECT EXISTS(SELECT 1 FROM tb_stores WHERE module LIKE 'exact.rust.pool%')", [], |r|r.get(0)).map_err(|e|e.to_string())?;
                if other {
                    return Err("未知暂存池模块，停止新增写入".into());
                }
                Ok(None)
            }
        }
    }

    fn install_object(
        &self,
        c: &Connection,
        object: &(String, String),
        namespace: &SQLiteStoreNamespace,
    ) -> Result<()> {
        let (name, sql) = object;
        c.execute_batch(sql).map_err(|e| e.to_string())?;
        c.execute(
            "INSERT INTO tb_store_objects(store_id,name,type,original_sql) VALUES(?1,?2,?3,?4)",
            params![
                self.store.id,
                name,
                object_kind(sql)?,
                namespace.unbind(sql).map_err(|e| format!("{e:?}"))?
            ],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub(super) fn validate_schema(
        &self,
        c: &Connection,
        objects: &[(String, String)],
    ) -> Result<()> {
        let mut statement = c.prepare("SELECT name,type,sql FROM sqlite_master WHERE substr(name,1,?1)=?2 AND sql IS NOT NULL").map_err(|e|e.to_string())?;
        let physical = statement
            .query_map(params![self.store.prefix.len(), self.store.prefix], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    (r.get::<_, String>(1)?, r.get::<_, String>(2)?),
                ))
            })
            .map_err(|e| e.to_string())?
            .collect::<std::result::Result<HashMap<_, _>, _>>()
            .map_err(|e| e.to_string())?;
        let mut statement = c
            .prepare("SELECT name,type,original_sql FROM tb_store_objects WHERE store_id=?1")
            .map_err(|e| e.to_string())?;
        let registered = statement
            .query_map([&self.store.id], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    (r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?),
                ))
            })
            .map_err(|e| e.to_string())?
            .collect::<std::result::Result<HashMap<_, _>, _>>()
            .map_err(|e| e.to_string())?;
        if physical.len() != objects.len() || registered.len() != objects.len() {
            return Err("暂存池结构或登记数量不匹配".into());
        }
        let namespace = SQLiteStoreNamespace::new(
            self.store.prefix.clone(),
            objects.iter().map(|(n, _)| n.clone()),
        );
        for (name, sql) in objects {
            let kind = object_kind(sql)?;
            let original = namespace.unbind(sql).map_err(|e| format!("{e:?}"))?;
            let actual = physical.get(&format!("{}{name}", self.store.prefix));
            let catalog = registered.get(name);
            if !actual.is_some_and(|(k, s)| {
                k == kind && s.trim_end_matches(';') == sql.trim_end_matches(';')
            }) || !catalog
                .is_some_and(|(k, s)| k == kind && s.as_deref() == Some(original.as_str()))
            {
                return Err("暂存池结构或登记合同不匹配".into());
            }
        }
        Ok(())
    }

    pub(super) fn prepare_schema(&self, container: &Container) -> Result<()> {
        let c = container.connection();
        let backed_up = self.registered_version(c)?.is_none();
        if backed_up {
            // The existing pre-pool snapshot is created before taking A's
            // writer lease. Index-only upgrades need no copy of business data.
            super::super::stage_pool_backup::ensure(&self.path, c)?;
        }
        let tx = begin_pool_write(c).map_err(|e| e.to_string())?;
        Container::validate_version_on(&tx).map_err(|e| e.to_string())?;
        let activation: Option<String> = tx
            .query_row(
                "SELECT value FROM tb_container_meta WHERE key='activation_state'",
                [],
                |r| r.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        if activation.as_deref().is_some_and(|state| state != "ready") {
            return Err("业务A尚未激活，保留暂存任务".into());
        }
        let objects = self.schema();
        let namespace = SQLiteStoreNamespace::new(
            self.store.prefix.clone(),
            objects.iter().map(|(n, _)| n.clone()),
        );
        // Reread only after acquiring the writer: another process may have
        // completed the migration while this connection was waiting.
        match self.registered_version(&tx)? {
            Some(1) => {
                self.validate_schema(&tx, &self.schema_v1())?;
                self.install_object(&tx, &self.candidate_index(), &namespace)?;
                container
                    .set_user_version(&self.store, EXACT_STAGE_POOL_VERSION)
                    .map_err(|e| e.to_string())?;
            }
            Some(EXACT_STAGE_POOL_VERSION) => {}
            None if backed_up => {
                self.validate_schema(&tx, &[])?;
                container.register(&self.store).map_err(|e| e.to_string())?;
                for object in &objects {
                    self.install_object(&tx, object, &namespace)?;
                }
                container
                    .set_user_version(&self.store, EXACT_STAGE_POOL_VERSION)
                    .map_err(|e| e.to_string())?;
                #[cfg(all(feature = "business-store-fixture", not(test)))]
                crash_fixture::process_fault("initialize-before-commit", &self.path);
            }
            _ => return Err("暂存池注册在打开期间发生变化，保留原数据".into()),
        }
        self.validate_schema(&tx, &objects)?;
        tx.commit().map_err(|e| e.to_string())
    }
}
