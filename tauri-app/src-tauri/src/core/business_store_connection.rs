//! A rusqlite-compatible facade for one logical store inside container A.
//!
//! The unbound constructors remain useful for isolated SQLite fixtures and
//! candidate snapshots. Production callers use `open_store` so every SQL
//! identifier is rewritten to that store's private namespace before SQLite
//! prepares it.

use crate::core::business_store_container::{BusinessStoreError, Container, StoreSpec};
use crate::core::business_store_sql::{references_logical_sequence, split_complete_statements, StoreSqlBinding};
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

pub(crate) mod exact;

#[cfg(test)]
mod retention_lookup_tests;

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
             WHERE substr(name,1,{prefix_len})='{prefix}' AND lower(substr(name,1,7)) <> 'sqlite_' \
             UNION ALL \
             SELECT 'sqlite_autoindex_' || substr(name,{autoindex_after_prefix}),type, \
                    substr(tbl_name,{after_prefix}),rootpage,NULL \
             FROM main.sqlite_master \
             WHERE substr(name,1,{autoindex_prefix_len})='sqlite_autoindex_{prefix}';",
            after_prefix = prefix.len() + 1,
            prefix_len = prefix.len(),
            autoindex_after_prefix = 18 + prefix.len(),
            autoindex_prefix_len = 17 + prefix.len(),
            prefix = prefix
        ))?;
        Self::refresh_sequence_view(&raw, &prefix, false)?;
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

    fn translate_sql(&self, sql: &str) -> Result<String> {
        let Some(binding) = &self.binding else {
            return Ok(sql.to_owned());
        };
        binding.borrow_mut().sql(sql).map_err(|error| {
            rusqlite::Error::InvalidParameterName(format!("store SQL binding: {error:?}"))
        })
    }

    fn bind_sql(&self, sql: &str) -> Result<String> {
        let bound = self.translate_sql(sql)?;
        self.refresh_sequence_view_for_sql(&bound)?;
        Ok(bound)
    }

    fn refresh_sequence_view_for_sql(&self, sql: &str) -> Result<()> {
        if references_logical_sequence(sql).map_err(|error| {
            rusqlite::Error::InvalidParameterName(format!("store SQL binding: {error:?}"))
        })? {
            if let Some(binding) = &self.binding {
                Self::refresh_sequence_view(&self.raw, binding.borrow().prefix(), true)?;
            }
        }
        Ok(())
    }

    fn refresh_sequence_view(raw: &Connection, prefix: &str, required: bool) -> Result<()> {
        let physical_exists: bool = raw.query_row(
            "SELECT EXISTS(SELECT 1 FROM main.sqlite_master WHERE type='table' AND name='sqlite_sequence')",
            [], |row| row.get(0),
        )?;
        // A dangling TEMP view makes SQLite reject even an unrelated ALTER.
        // Do not synthesize an empty sequence: prepared or indirect readers
        // could retain that projection after the first AUTOINCREMENT CREATE.
        // Before the physical table exists, explicit sequence reads retain
        // SQLite's missing-table error. No MAIN placeholder is created.
        if !physical_exists {
            if required {
                return Err(rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_ERROR),
                    Some("no such table: main.sqlite_sequence".to_owned()),
                ));
            }
            return Ok(());
        }
        let select = format!("SELECT substr(name,{}) AS name,seq FROM main.sqlite_sequence WHERE substr(name,1,{})='{prefix}'", prefix.len() + 1, prefix.len());
        let expected = format!("CREATE VIEW tb_logical_sequence AS {select}");
        let existing: Option<String> = raw.query_row(
            "SELECT sql FROM sqlite_temp_master WHERE type='view' AND name='tb_logical_sequence'",
            [], |row| row.get(0),
        ).optional()?;
        if existing.as_deref() != Some(&expected) {
            raw.execute_batch(&format!("DROP VIEW IF EXISTS temp.tb_logical_sequence; CREATE TEMP VIEW tb_logical_sequence AS {select}"))?;
        }
        Ok(())
    }

    pub(crate) fn execute<P: Params>(&self, sql: &str, params: P) -> Result<usize> {
        let sql = self.bind_sql(sql)?;
        if sql.trim().is_empty() {
            return Ok(0);
        }
        self.raw.execute(&sql, params)
    }

    pub(crate) fn execute_batch(&self, sql: &str) -> Result<()> {
        let sql = self.translate_sql(sql)?;
        if sql.trim().is_empty() {
            return Ok(());
        }
        if self.binding.is_some() && sql.contains("tb_logical_sequence") {
            // A batch can create its first AUTOINCREMENT table before reading
            // its sequence. Bind the whole batch before executing any of it,
            // then refresh the view at the statement that actually uses it.
            let statements = split_complete_statements(&sql).map_err(|error| {
                rusqlite::Error::InvalidParameterName(format!("store SQL binding: {error:?}"))
            })?;
            for statement in statements {
                self.refresh_sequence_view_for_sql(statement)?;
                self.raw.execute_batch(statement)?;
            }
            Ok(())
        } else {
            self.raw.execute_batch(&sql)
        }
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
    #[test]
    fn bound_temporary_tables_and_views_cannot_shadow_published_rows() {
        for mode in [false, true] {
            for declaration in ["CREATE TEMP TABLE facts(value INTEGER)",
                "CREATE TEMP VIEW facts AS SELECT 99 AS value", "CREATE TABLE temp.facts(value INTEGER)",
                "CREATE TEMPORARY TABLE facts(value INTEGER)",
                "CREATE TABLE \"temp\".\"facts\"(value INTEGER)",
                "CREATE TEMP VIEW \"facts\" AS SELECT 99 AS value"] {
                let db = bound();
                db.set_temporary_namespace_mode(mode).unwrap();
                db.execute_batch("CREATE TABLE facts(value INTEGER);INSERT INTO facts VALUES(17)").unwrap();
                assert_eq!(db.query_row("SELECT value FROM facts", [], |r|r.get::<_,i64>(0)).unwrap(), 17);
                assert!(db.execute_batch(declaration).is_err(), "{declaration}");
                assert_eq!(db.query_row("SELECT value FROM facts", [], |r|r.get::<_,i64>(0)).unwrap(), 17);
                db.execute("UPDATE facts SET value=18", []).unwrap();
                assert_eq!(db.query_row("SELECT value FROM main.facts", [], |r|r.get::<_,i64>(0)).unwrap(), 18);
                assert_eq!(db.raw().query_row("SELECT COUNT(*) FROM sqlite_temp_master WHERE type='table'", [], |r|r.get::<_,i64>(0)).unwrap(), 0);
            }
        }
    }

    #[test]
    fn bound_drop_and_rename_preserve_main_and_temp_ownership() {
        for mode in [false, true] {
            let db = bound();
            db.set_temporary_namespace_mode(mode).unwrap();
            db.execute_batch("CREATE TABLE facts(value INTEGER);INSERT INTO facts VALUES(17);CREATE TEMP TABLE work(value INTEGER);INSERT INTO work VALUES(99)").unwrap();
            for sql in ["DROP TABLE IF EXISTS temp.facts", "DROP TABLE IF EXISTS main.work",
                "ALTER TABLE temp.work RENAME TO facts", "ALTER TABLE main.facts RENAME TO work"] {
                assert!(db.execute_batch(sql).is_err(), "{sql}");
            }
            db.execute_batch("ALTER TABLE temp.work RENAME TO next").unwrap();
            assert_eq!(db.query_row("SELECT value FROM temp.next", [], |r|r.get::<_,i64>(0)).unwrap(), 99);
            assert_eq!(db.query_row("SELECT value FROM next", [], |r|r.get::<_,i64>(0)).unwrap(), 99);
            assert_eq!(db.query_row("SELECT value FROM facts", [], |r|r.get::<_,i64>(0)).unwrap(), 17);
            db.execute_batch("DROP TABLE next;CREATE TEMP TABLE next(value INTEGER);INSERT INTO next VALUES(100)").unwrap();
            assert_eq!(db.query_row("SELECT value FROM temp.next", [], |r|r.get::<_,i64>(0)).unwrap(), 100);
            assert!(db.execute_batch("CREATE TABLE next(value INTEGER)").is_err(), "dropped names retain their established schema reservation");
        }
    }

    #[test]
    fn rejected_binding_batches_leave_no_names_or_partial_sql_execution() {
        for mode in [false, true] {
            let db = bound();
            db.set_temporary_namespace_mode(mode).unwrap();
            db.execute_batch("CREATE TABLE facts(value INTEGER);INSERT INTO facts VALUES(17)").unwrap();
            assert!(db.execute_batch("CREATE TEMP TABLE poison(value INTEGER);ALTER TABLE temp.poison RENAME TO facts").is_err());
            assert_eq!(db.raw().query_row("SELECT COUNT(*) FROM sqlite_temp_master WHERE type='table'", [], |r|r.get::<_,i64>(0)).unwrap(), 0);
            db.execute_batch("CREATE TABLE poison(value INTEGER);INSERT INTO poison VALUES(23)").unwrap();
            assert_eq!(db.query_row("SELECT value FROM main.poison", [], |r|r.get::<_,i64>(0)).unwrap(), 23);
            assert!(db.execute_batch("CREATE TEMP TABLE unused(value INTEGER);VACUUM INTO 'not-created.sqlite'").is_err());
            db.execute_batch("CREATE TABLE unused(value INTEGER);INSERT INTO unused VALUES(29)").unwrap();
            assert_eq!(db.query_row("SELECT value FROM main.unused", [], |r|r.get::<_,i64>(0)).unwrap(), 29);
        }
    }

    #[test]
    fn bound_temporary_objects_and_dependencies_remain_usable() {
        for mode in [false, true] {
            let db = bound();
            db.set_temporary_namespace_mode(mode).unwrap();
            db.execute_batch("CREATE TABLE temp.work(value INTEGER);INSERT INTO temp.work VALUES(31);CREATE INDEX work_index ON work(value);CREATE TRIGGER work_trigger AFTER INSERT ON work BEGIN SELECT 1; END").unwrap();
            assert!(db.execute_batch("DROP INDEX main.work_index").is_err());
            assert!(db.execute_batch("DROP TRIGGER main.work_trigger").is_err());
            db.execute_batch("DROP INDEX temp.work_index;DROP TRIGGER temp.work_trigger").unwrap();
            assert_eq!(db.query_row("SELECT value FROM temp.work", [], |r|r.get::<_,i64>(0)).unwrap(), 31);
            assert!(db.execute_batch("CREATE TABLE work(value INTEGER)").is_err());
            db.execute_batch("CREATE TEMP VIEW projection AS SELECT value FROM temp.work").unwrap();
            assert_eq!(db.query_row("SELECT value FROM temp.projection", [], |r|r.get::<_,i64>(0)).unwrap(), 31);
        }
        let private = StoreConnection::open_in_memory().unwrap();
        private.execute_batch("CREATE TABLE facts(value INTEGER);INSERT INTO main.facts VALUES(17);CREATE TEMP TABLE facts(value INTEGER);INSERT INTO temp.facts VALUES(99)").unwrap();
        assert_eq!(private.query_row("SELECT value FROM facts", [], |r|r.get::<_,i64>(0)).unwrap(), 99);
        assert_eq!(private.query_row("SELECT value FROM main.facts", [], |r|r.get::<_,i64>(0)).unwrap(), 17);
    }

    #[test]
    fn bound_sequence_projection_tracks_first_autoincrement_and_transaction_rollback() {
        let mut db = bound();
        db.execute_batch("CREATE TABLE facts(value INTEGER);INSERT INTO facts VALUES(17)").unwrap();
        assert!(db.query_row("SELECT COUNT(*) FROM sqlite_sequence", [], |r| r.get::<_, i64>(0)).is_err());
        assert!(db.prepare("SELECT name,seq FROM sqlite_sequence").is_err());
        assert!(db.execute_batch("CREATE TEMP VIEW early_sequence AS SELECT name,seq FROM sqlite_sequence").is_err());
        assert_eq!(db.raw().query_row("SELECT COUNT(*) FROM sqlite_master WHERE name='sqlite_sequence'", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
        {
            let tx = db.transaction().unwrap();
            tx.execute_batch("CREATE TABLE provisional(id INTEGER PRIMARY KEY AUTOINCREMENT);INSERT INTO provisional DEFAULT VALUES").unwrap();
            assert_eq!(tx.query_row("SELECT seq FROM sqlite_sequence WHERE name='provisional'", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
            // Both the first physical sequence and its TEMP projection roll back.
        }
        assert!(db.query_row("SELECT COUNT(*) FROM sqlite_sequence", [], |r| r.get::<_, i64>(0)).is_err());
        db.execute_batch("ALTER TABLE facts RENAME TO renamed;CREATE TABLE stable(id INTEGER PRIMARY KEY AUTOINCREMENT);INSERT INTO stable DEFAULT VALUES").unwrap();
        db.raw().execute_batch("CREATE TABLE sibling(id INTEGER PRIMARY KEY AUTOINCREMENT);INSERT INTO sibling DEFAULT VALUES").unwrap();
        let sequences = db.prepare("SELECT name,seq FROM sqlite_sequence").unwrap()
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))).unwrap()
            .collect::<Result<Vec<_>>>().unwrap();
        assert_eq!(sequences, vec![("stable".to_owned(), 1)]);
        db.execute_batch("CREATE TEMP VIEW later_sequence AS SELECT name,seq FROM sqlite_sequence").unwrap();
        let mut held = db.prepare("SELECT seq FROM sqlite_sequence WHERE name='stable'").unwrap();
        db.execute_batch("INSERT INTO stable DEFAULT VALUES").unwrap();
        assert_eq!(held.query_row([], |r| r.get::<_, i64>(0)).unwrap(), 2);
        assert_eq!(db.query_row("SELECT seq FROM later_sequence WHERE name='stable'", [], |r| r.get::<_, i64>(0)).unwrap(), 2);
        assert_eq!(db.query_row("SELECT value FROM renamed", [], |r| r.get::<_, i64>(0)).unwrap(), 17);
    }

    #[test]
    fn bound_batch_can_create_and_read_its_first_autoincrement_sequence() {
        let db = bound();
        db.execute_batch("CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT);INSERT INTO records DEFAULT VALUES;CREATE TEMP TABLE copied_sequence AS SELECT name,seq FROM sqlite_sequence").unwrap();
        assert_eq!(db.query_row("SELECT seq FROM copied_sequence WHERE name='records'", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
        db.execute_batch("INSERT INTO records DEFAULT VALUES").unwrap();
        assert_eq!(db.query_row("SELECT seq FROM sqlite_sequence WHERE name='records'", [], |r| r.get::<_, i64>(0)).unwrap(), 2);
    }

    #[test]
    fn missing_sequence_does_not_reject_literal_or_comment_markers() {
        let db = bound();
        assert_eq!(db.query_row("SELECT 'tb_logical_sequence'", [], |r| r.get::<_, String>(0)).unwrap(), "tb_logical_sequence");
        for sql in ["SELECT 1 /* tb_logical_sequence */", "SELECT 1 -- tb_logical_sequence\n"] {
            assert_eq!(db.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap(), 1);
        }
        db.execute_batch("CREATE TABLE facts(value TEXT);INSERT INTO facts VALUES('tb_logical_sequence')").unwrap();
        assert_eq!(db.query_row("SELECT value FROM facts", [], |r| r.get::<_, String>(0)).unwrap(), "tb_logical_sequence");
    }

}
