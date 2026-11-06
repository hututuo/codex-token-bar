//! Snapshot import, export and cloning for one logical store.
//!
//! The caller keeps its original connection. Each operation retains its own
//! transaction, attachment lifetime and foreign-key restoration order. Legacy
//! input selection and receipt policy stay with the parent; a supplied receipt
//! is written in the same import transaction as its rows.

use super::{
    drop_object, drop_store_objects, has_table, proof_for, readonly_file_uri,
    rowid_alias, table_columns, table_xinfo_columns, write_legacy_receipt,
    BusinessStoreError, BusinessStoreResult, Container, LegacyReceiptWrite,
    StoreProof, StoreSpec, StoreState,
};
use crate::core::business_store_sql::SQLiteStoreNamespace;
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashSet;
use std::path::Path;

const IMPORT_ALIAS: &str = "tb_import_source";
const EXPORT_ALIAS: &str = "tb_export_source";

impl Container {
    /// Import one immutable SQLite snapshot into a single store namespace.
    /// The source is attached read-only and never modified; receipt and table
    /// replacement are committed together in the container transaction.
    pub(crate) fn import_snapshot(
        &mut self,
        source_path: impl AsRef<Path>,
        store: &StoreSpec,
        backup_path: impl AsRef<Path>,
        now: f64,
        replace_existing: bool,
    ) -> BusinessStoreResult<StoreProof> {
        self.import_snapshot_inner(
            source_path.as_ref(),
            store,
            backup_path.as_ref(),
            now,
            replace_existing,
            None,
            None,
            None,
        )
    }

    pub(crate) fn replace_frozen_snapshot(
        &mut self, source: &Path, store: &StoreSpec, backup: &Path, now: f64, expected: &StoreProof, expected_source: &StoreProof,
    ) -> BusinessStoreResult<StoreProof> {
        self.import_snapshot_inner(source, store, backup, now, true, None, Some(expected), Some(expected_source))
    }

    pub(super) fn import_snapshot_inner(
        &mut self,
        source_path: &Path,
        store: &StoreSpec,
        backup_path: &Path,
        now: f64,
        replace_existing: bool,
        legacy_receipt: Option<LegacyReceiptWrite>,
        expected_current: Option<&StoreProof>,
        expected_source: Option<&StoreProof>,
    ) -> BusinessStoreResult<StoreProof> {
        if !now.is_finite() {
            return Err(BusinessStoreError::InvalidTimestamp);
        }
        self.register(store)?;
        let uri = readonly_file_uri(source_path);
        self.connection
            .execute("ATTACH DATABASE ?1 AS tb_import_source", [&uri])?;
        let foreign_keys: bool = self
            .connection
            .query_row("PRAGMA foreign_keys", [], |row| row.get(0))?;
        self.connection.execute_batch("PRAGMA foreign_keys=OFF")?;
        let result =
            self.import_attached(store, backup_path, now, replace_existing, legacy_receipt, expected_current, expected_source);
        let detach_result = self
            .connection
            .execute_batch("DETACH DATABASE tb_import_source");
        let restore_result = self.connection.execute_batch(if foreign_keys {
            "PRAGMA foreign_keys=ON"
        } else {
            "PRAGMA foreign_keys=OFF"
        });
        match result {
            Err(error) => Err(error),
            Ok(value) => {
                detach_result?;
                restore_result?;
                Ok(value)
            }
        }
    }

    fn import_attached(
        &mut self,
        store: &StoreSpec,
        backup_path: &Path,
        now: f64,
        replace_existing: bool,
        legacy_receipt: Option<LegacyReceiptWrite>,
        expected_current: Option<&StoreProof>,
        expected_source: Option<&StoreProof>,
    ) -> BusinessStoreResult<StoreProof> {
        let tx = self.connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        if let Some(expected) = expected_current {
            let version: i64 = tx.query_row("SELECT user_version FROM tb_stores WHERE store_id=?1", [&store.id], |r|r.get(0))?;
            if proof_for(&tx,"main",&store.prefix,true,Some(version))? != *expected {
                return Err(BusinessStoreError::ProofMismatch);
            }
        }
        let source = proof_for(&tx, IMPORT_ALIAS, "", false, None)?;
        let source_digest = format!("{}:{}", source.schema_digest, source.rows_digest);
        if expected_source.is_some_and(|expected| expected != &source)
            || legacy_receipt.as_ref().is_some_and(|receipt| receipt.source_digest != source_digest) {
            return Err(BusinessStoreError::ProofMismatch);
        }
        let existing: Option<String> = tx
            .query_row(
                "SELECT rows_digest FROM tb_store_imports WHERE store_id=?1 AND source_digest=?2",
                params![store.id, source_digest],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(existing) = existing {
            if existing != source.rows_digest {
                return Err(BusinessStoreError::ProofMismatch);
            }
            if !replace_existing {
                if let Some(receipt) = legacy_receipt.as_ref() {
                    write_legacy_receipt(&tx, receipt)?;
                }
                tx.commit()?;
                return Ok(source);
            }
        }

        if !replace_existing && !schema_objects(&tx,"main",&store.prefix)?.is_empty() {
            return Err(BusinessStoreError::ProofMismatch);
        }

        let objects = schema_objects(&tx, IMPORT_ALIAS, "")?;
        validate_objects(&tx, IMPORT_ALIAS, &objects)?;
        let names: HashSet<String> = objects
            .iter()
            .map(|object| object.name.to_ascii_lowercase())
            .collect();
        let mut namespace = SQLiteStoreNamespace::new(store.prefix.clone(), names.iter().cloned());
        for object in &objects {
            if object.kind == "table" {
                let columns = table_columns(&tx, IMPORT_ALIAS, &object.name)?;
                if columns
                    .iter()
                    .any(|name| names.contains(&name.to_ascii_lowercase()))
                {
                    return Err(BusinessStoreError::UnsupportedSchema(format!(
                        "object and column names overlap in {}",
                        object.name
                    )));
                }
            }
        }

        drop_store_objects(&tx, &store.prefix)?;
        tx.execute(
            "DELETE FROM tb_store_objects WHERE store_id=?1",
            [&store.id],
        )?;

        for object in objects.iter().filter(|object| object.kind == "table") {
            let sql = object
                .sql
                .as_deref()
                .ok_or_else(|| BusinessStoreError::UnsupportedSchema(object.name.clone()))?;
            if sql.to_ascii_uppercase().contains("CREATE VIRTUAL TABLE") {
                return Err(BusinessStoreError::UnsupportedSchema(object.name.clone()));
            }
            tx.execute_batch(&namespace.bind(sql)?)?;
            copy_table(
                &tx,
                IMPORT_ALIAS,
                "main",
                &object.name,
                &format!("{}{}", store.prefix, object.name),
                sql,
            )?;
        }

        copy_sequences(&tx, IMPORT_ALIAS, "main", &store.prefix, "")?;

        for object in objects.iter().filter(|object| object.kind != "table") {
            if let Some(sql) = object.sql.as_deref() {
                tx.execute_batch(&namespace.bind(sql)?)?;
            }
        }

        for object in &objects {
            tx.execute(
                "INSERT INTO tb_store_objects(store_id,name,type,original_sql) VALUES (?1,?2,?3,?4)",
                params![store.id, object.name, object.kind, object.sql],
            )?;
        }
        let user_version: i64 =
            tx.query_row("PRAGMA tb_import_source.user_version", [], |row| row.get(0))?;
        tx.execute(
            "UPDATE tb_stores SET user_version=?1,revision=revision+1 WHERE store_id=?2",
            params![user_version, store.id],
        )?;

        let actual = proof_for(&tx, "main", &store.prefix, true, Some(user_version))?;
        if actual.row_count != source.row_count
            || actual.schema_digest != source.schema_digest
            || actual.rows_digest != source.rows_digest
            || actual.table_counts != source.table_counts
        {
            return Err(BusinessStoreError::ProofMismatch);
        }
        let foreign_key_rows: i64 = tx.query_row(
            "SELECT COUNT(*) FROM pragma_foreign_key_check WHERE substr(\"table\",1,?1)=?2",
            params![store.prefix.len() as i64, store.prefix],
            |row| row.get(0),
        )?;
        if foreign_key_rows != 0 {
            return Err(BusinessStoreError::ProofMismatch);
        }
        tx.execute(
            "INSERT INTO tb_store_imports(store_id,source_digest,schema_digest,row_count,rows_digest,backup_path,imported_at) VALUES (?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(store_id,source_digest) DO UPDATE SET schema_digest=excluded.schema_digest,row_count=excluded.row_count,rows_digest=excluded.rows_digest,backup_path=excluded.backup_path,imported_at=excluded.imported_at",
            params![store.id, source_digest, source.schema_digest, source.row_count, source.rows_digest, backup_path.to_string_lossy(), now],
        )?;
        if let Some(receipt) = legacy_receipt.as_ref() {
            write_legacy_receipt(&tx, receipt)?;
        }
        tx.commit()?;
        Ok(source)
    }

    /// Export one namespace into a caller-provided destination connection.
    /// The target's current user_version is replaced by this store's legacy
    /// module version; the container's own PRAGMA user_version is untouched.
    pub(crate) fn export_to(
        &self,
        store: &StoreSpec,
        target: &mut Connection,
    ) -> BusinessStoreResult<StoreProof> {
        self.ensure_registered(store)?;
        let expected = self.proof(store)?;
        let module_version = self.user_version(store)?;
        let uri = readonly_file_uri(&self.path);
        target.execute("ATTACH DATABASE ?1 AS tb_export_source", [&uri])?;
        let foreign_keys: bool = target.query_row("PRAGMA foreign_keys", [], |row| row.get(0))?;
        target.execute_batch("PRAGMA foreign_keys=OFF")?;
        let result = export_attached(store, target, module_version, &expected);
        let detach_result = target.execute_batch("DETACH DATABASE tb_export_source");
        let restore_result = target.execute_batch(if foreign_keys {
            "PRAGMA foreign_keys=ON"
        } else {
            "PRAGMA foreign_keys=OFF"
        });
        match result {
            Err(error) => Err(error),
            Ok(value) => {
                detach_result?;
                restore_result?;
                Ok(value)
            }
        }
    }

    /// Replace one module namespace with a transactionally cloned namespace.
    /// The source and target remain inside the same physical container; a
    /// failed clone leaves every other store and the old target intact.
    pub(crate) fn clone_store_namespace(
        &mut self,
        source: &StoreSpec,
        target: &StoreSpec,
    ) -> BusinessStoreResult<StoreProof> {
        // Match verified snapshot import: tables are not necessarily emitted
        // in FK dependency order, and cycles cannot be topologically sorted.
        // Disable enforcement on this private handle only, prove every target
        // FK before commit, then restore the caller's setting on every exit.
        let foreign_keys: bool = self.connection.query_row("PRAGMA foreign_keys", [], |r| r.get(0))?;
        self.connection.execute_batch("PRAGMA foreign_keys=OFF")?;
        let result = self.clone_store_namespace_inner(source, target);
        let restored = self.connection.execute_batch(if foreign_keys {
            "PRAGMA foreign_keys=ON"
        } else {
            "PRAGMA foreign_keys=OFF"
        });
        restored?;
        result
    }

    fn clone_store_namespace_inner(
        &mut self,
        source: &StoreSpec,
        target: &StoreSpec,
    ) -> BusinessStoreResult<StoreProof> {
        self.ensure_registered(source)?;
        if source.id == target.id {
            return Err(BusinessStoreError::InvalidStore);
        }
        let source_proof = self.proof(source)?;
        let module_version = self.user_version(source)?;
        let objects = schema_objects(&self.connection, "main", &source.prefix)?;
        let names = objects
            .iter()
            .map(|object| object.name[source.prefix.len()..].to_ascii_lowercase())
            .collect::<HashSet<_>>();
        let source_namespace =
            SQLiteStoreNamespace::new(source.prefix.clone(), names.iter().cloned());
        let mut target_namespace = SQLiteStoreNamespace::new(target.prefix.clone(), names);
        self.register_with_state(target, StoreState::Staging)?;

        let tx = self.connection.transaction()?;
        drop_store_objects(&tx, &target.prefix)?;
        tx.execute(
            "DELETE FROM tb_store_objects WHERE store_id=?1",
            [&target.id],
        )?;
        for object in objects.iter().filter(|object| object.kind == "table") {
            let physical_sql = object
                .sql
                .as_deref()
                .ok_or_else(|| BusinessStoreError::UnsupportedSchema(object.name.clone()))?;
            let logical_sql = source_namespace.unbind(physical_sql)?;
            if logical_sql
                .to_ascii_uppercase()
                .contains("CREATE VIRTUAL TABLE")
            {
                return Err(BusinessStoreError::UnsupportedSchema(object.name.clone()));
            }
            tx.execute_batch(&target_namespace.bind(&logical_sql)?)?;
            let logical_name = object.name[source.prefix.len()..].to_owned();
            copy_table(
                &tx,
                "main",
                "main",
                &object.name,
                &format!("{}{}", target.prefix, logical_name),
                &logical_sql,
            )?;
        }
        copy_sequences(&tx, "main", "main", &target.prefix, &source.prefix)?;
        for object in objects.iter().filter(|object| object.kind != "table") {
            if let Some(physical_sql) = object.sql.as_deref() {
                let logical_sql = source_namespace.unbind(physical_sql)?;
                tx.execute_batch(&target_namespace.bind(&logical_sql)?)?;
            }
        }
        for object in &objects {
            let original_sql = object
                .sql
                .as_deref()
                .map(|sql| source_namespace.unbind(sql))
                .transpose()?;
            tx.execute(
                "INSERT INTO tb_store_objects(store_id,name,type,original_sql) VALUES (?1,?2,?3,?4)",
                params![
                    target.id,
                    object.name[source.prefix.len()..].to_owned(),
                    object.kind,
                    original_sql,
                ],
            )?;
        }
        tx.execute(
            "UPDATE tb_stores SET user_version=?1,state='staging',revision=revision+1 WHERE store_id=?2",
            params![module_version, target.id],
        )?;
        let actual = proof_for(&tx, "main", &target.prefix, true, Some(module_version))?;
        if actual != source_proof {
            return Err(BusinessStoreError::ProofMismatch);
        }
        let broken: i64 = tx.query_row(
            "SELECT COUNT(*) FROM pragma_foreign_key_check WHERE substr(\"table\",1,?1)=?2",
            params![target.prefix.len() as i64, target.prefix], |r| r.get(0),
        )?;
        if broken != 0 { return Err(BusinessStoreError::ProofMismatch); }
        tx.commit()?;
        Ok(actual)
    }
}

fn export_attached(
    store: &StoreSpec,
    target: &mut Connection,
    module_version: i64,
    expected: &StoreProof,
) -> BusinessStoreResult<StoreProof> {
    let tx = target.transaction()?;
    let objects = schema_objects(&tx, EXPORT_ALIAS, &store.prefix)?;
    let names: HashSet<String> = objects
        .iter()
        .map(|object| object.name[store.prefix.len()..].to_ascii_lowercase())
        .collect();
    let namespace = SQLiteStoreNamespace::new(store.prefix.clone(), names);
    drop_all_objects(&tx, "main")?;

    for object in objects.iter().filter(|object| object.kind == "table") {
        let sql = object
            .sql
            .as_deref()
            .ok_or_else(|| BusinessStoreError::UnsupportedSchema(object.name.clone()))?;
        let logical_sql = namespace.unbind(sql)?;
        tx.execute_batch(&logical_sql)?;
        let logical = object.name[store.prefix.len()..].to_string();
        copy_table(
            &tx,
            EXPORT_ALIAS,
            "main",
            &object.name,
            &logical,
            &logical_sql,
        )?;
    }
    for object in objects.iter().filter(|object| object.kind != "table") {
        if let Some(sql) = object.sql.as_deref() {
            tx.execute_batch(&namespace.unbind(sql)?)?;
        }
    }
    copy_sequences(&tx, EXPORT_ALIAS, "main", "", &store.prefix)?;
    tx.execute_batch(&format!("PRAGMA user_version={module_version}"))?;

    let actual = proof_for(&tx, "main", "", false, Some(module_version))?;
    if actual.row_count != expected.row_count
        || actual.rows_digest != expected.rows_digest
        || actual.table_counts != expected.table_counts
        || actual.module_user_version != expected.module_user_version
    {
        return Err(BusinessStoreError::ProofMismatch);
    }
    tx.commit()?;
    Ok(actual)
}

#[derive(Clone, Debug)]
struct SchemaObject {
    name: String,
    kind: String,
    sql: Option<String>,
}

fn schema_objects(
    connection: &Connection,
    schema: &str,
    prefix: &str,
) -> BusinessStoreResult<Vec<SchemaObject>> {
    let sql = format!(
        "SELECT name,type,sql FROM {schema}.sqlite_master WHERE lower(substr(name,1,7)) <> 'sqlite_' AND substr(name,1,?1)=?2 ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 1 WHEN 'index' THEN 2 WHEN 'trigger' THEN 3 ELSE 4 END,name"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(params![prefix.len() as i64, prefix], |row| {
        Ok(SchemaObject {
            name: row.get(0)?,
            kind: row.get(1)?,
            sql: row.get(2)?,
        })
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

fn validate_objects(
    connection: &Connection,
    schema: &str,
    objects: &[SchemaObject],
) -> BusinessStoreResult<()> {
    for object in objects {
        if !["table", "index", "view", "trigger"].contains(&object.kind.as_str()) {
            return Err(BusinessStoreError::UnsupportedSchema(object.kind.clone()));
        }
        if object.kind == "table" {
            let sql = object
                .sql
                .as_deref()
                .unwrap_or_default()
                .to_ascii_uppercase();
            if sql.contains("CREATE VIRTUAL TABLE") {
                return Err(BusinessStoreError::UnsupportedSchema(object.name.clone()));
            }
            let _ = table_columns(connection, schema, &object.name)?;
        }
    }
    Ok(())
}

fn copy_table(
    connection: &Connection,
    source_schema: &str,
    target_schema: &str,
    source_table: &str,
    target_table: &str,
    logical_sql: &str,
) -> BusinessStoreResult<()> {
    let table_info = table_xinfo_columns(connection, source_schema, source_table)?;
    let rowid_columns = table_info
        .iter()
        .filter(|(_, hidden)| *hidden != 1)
        .map(|(name, _)| name.clone())
        .collect::<Vec<_>>();
    let mut columns = rowid_alias(logical_sql, &rowid_columns)?
        .into_iter()
        .collect::<Vec<_>>();
    columns.extend(
        table_info
            .iter()
            .filter(|(_, hidden)| *hidden == 0)
            .map(|(name, _)| name.clone()),
    );
    let source_ref = format!(
        "{source_schema}.{}",
        SQLiteStoreNamespace::quote(source_table)
    );
    let target_ref = format!(
        "{target_schema}.{}",
        SQLiteStoreNamespace::quote(target_table)
    );
    if columns.is_empty() {
        let count: i64 =
            connection.query_row(&format!("SELECT COUNT(*) FROM {source_ref}"), [], |row| {
                row.get(0)
            })?;
        for _ in 0..count {
            connection.execute(&format!("INSERT INTO {target_ref} DEFAULT VALUES"), [])?;
        }
        return Ok(());
    }
    let columns_sql = columns
        .iter()
        .map(|column| SQLiteStoreNamespace::quote(column))
        .collect::<Vec<_>>()
        .join(",");
    connection.execute(
        &format!("INSERT INTO {target_ref} ({columns_sql}) SELECT {columns_sql} FROM {source_ref}"),
        [],
    )?;
    Ok(())
}

fn copy_sequences(
    connection: &Connection,
    source_schema: &str,
    target_schema: &str,
    target_prefix: &str,
    source_prefix: &str,
) -> BusinessStoreResult<()> {
    if !has_table(connection, source_schema, "sqlite_sequence")? {
        return Ok(());
    }
    let sql = format!(
        "SELECT name,seq FROM {source_schema}.sqlite_sequence WHERE substr(name,1,?1)=?2 ORDER BY name"
    );
    let mut statement = connection.prepare(&sql)?;
    let sequences = statement
        .query_map(params![source_prefix.len() as i64, source_prefix], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    if !has_table(connection, target_schema, "sqlite_sequence")? && !sequences.is_empty() {
        return Err(BusinessStoreError::UnsupportedSchema(
            "sqlite_sequence is absent in target".into(),
        ));
    }
    // Copying an empty AUTOINCREMENT table may create a zero sequence in
    // the destination even when the source has no sqlite_sequence row.
    // Replace only this partition's complete sequence set, including absence.
    if has_table(connection, target_schema, "sqlite_sequence")? {
        connection.execute(
            &format!("DELETE FROM {target_schema}.sqlite_sequence WHERE substr(name,1,?1)=?2"),
            params![target_prefix.len() as i64, target_prefix],
        )?;
    }
    for (source_name, sequence) in sequences {
        let logical = source_name
            .strip_prefix(source_prefix)
            .ok_or(BusinessStoreError::InvalidStore)?;
        let target_name = format!("{target_prefix}{logical}");
        connection.execute(
            &format!("DELETE FROM {target_schema}.sqlite_sequence WHERE name=?1"),
            [&target_name],
        )?;
        connection.execute(
            &format!("INSERT INTO {target_schema}.sqlite_sequence(name,seq) VALUES (?1,?2)"),
            params![target_name, sequence],
        )?;
    }
    Ok(())
}

fn drop_all_objects(connection: &Connection, schema: &str) -> BusinessStoreResult<()> {
    let sql = format!(
        "SELECT name,type FROM {schema}.sqlite_master WHERE lower(substr(name,1,7)) <> 'sqlite_' ORDER BY CASE type WHEN 'view' THEN 0 WHEN 'trigger' THEN 1 WHEN 'index' THEN 2 ELSE 3 END,name"
    );
    let mut statement = connection.prepare(&sql)?;
    let objects = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for (name, kind) in objects {
        drop_object(connection, schema, &kind, &name)?;
    }
    Ok(())
}
