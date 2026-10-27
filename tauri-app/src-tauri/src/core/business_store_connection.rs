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
    CachedStatement, Connection, OpenFlags, Params, Result, Row, Statement, TransactionBehavior,
};
use std::cell::RefCell;
use std::ops::Deref;
use std::path::Path;
use std::time::Duration;

pub(crate) struct StoreConnection {
    raw: Connection,
    binding: Option<RefCell<StoreSqlBinding>>,
}

impl StoreConnection {
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
        Self { raw, binding: None }
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
        })
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
