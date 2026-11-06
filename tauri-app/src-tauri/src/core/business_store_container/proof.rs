//! Read-only structural and typed-row proofs for a logical store.
//!
//! The caller owns the connection and snapshot. Proof encoding and object
//! ordering are persisted compatibility contracts; this module does not open
//! connections, change schema or manage transactions.

use super::{has_table, hex_digest, rowid_alias, BusinessStoreError, BusinessStoreResult, StoreProof};
use crate::core::business_store_sql::SQLiteStoreNamespace;
use rusqlite::{params, types::ValueRef, Connection};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

pub(super) fn proof_for(
    connection: &Connection,
    schema: &str,
    prefix: &str,
    unbind_schema: bool,
    module_version: Option<i64>,
) -> BusinessStoreResult<StoreProof> {
    proof_for_filtered(connection, schema, prefix, unbind_schema, module_version, false)
}

// Exact relocation adds only this known provenance row. This narrowly scoped
// proof is never used by generic imports or full backup verification.
pub(super) fn proof_for_filtered(
    connection: &Connection,
    schema: &str,
    prefix: &str,
    unbind_schema: bool,
    module_version: Option<i64>,
    exclude_exact_relocation: bool,
) -> BusinessStoreResult<StoreProof> {
    if prefix.is_empty() && !unbind_schema {
        let sql = format!("PRAGMA {schema}.quick_check");
        let mut statement = connection.prepare(&sql)?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        let checks = rows.collect::<Result<Vec<_>, _>>()?;
        if checks.len() != 1 || checks.first().map(String::as_str) != Some("ok") {
            return Err(BusinessStoreError::ProofMismatch);
        }
    }
    let module_user_version = if let Some(version) = module_version {
        version
    } else if prefix.is_empty() {
        connection.query_row(&format!("PRAGMA {schema}.user_version"), [], |row| {
            row.get(0)
        })?
    } else {
        connection.query_row(
            "SELECT user_version FROM main.tb_stores WHERE namespace_prefix=?1",
            [prefix],
            |row| row.get(0),
        )?
    };

    let raw_objects = if prefix.is_empty() {
        let mut statement = connection.prepare(&format!(
            "SELECT type,name,tbl_name,sql FROM {schema}.sqlite_master WHERE lower(substr(name,1,7)) <> 'sqlite_' ORDER BY type,name"
        ))?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    } else {
        let mut statement = connection.prepare(&format!(
            "SELECT type,name,tbl_name,sql FROM {schema}.sqlite_master WHERE lower(substr(name,1,7)) <> 'sqlite_' AND (substr(name,1,?1)=?2 OR substr(tbl_name,1,?1)=?2) ORDER BY type,name"
        ))?;
        let rows = statement.query_map(params![prefix.len() as i64, prefix], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    let mut objects = Vec::with_capacity(raw_objects.len());
    for (kind, physical_name, physical_table, sql) in raw_objects {
        let name = if prefix.is_empty() {
            physical_name
        } else {
            strip_prefix_case_insensitive(&physical_name, prefix)
                .ok_or(BusinessStoreError::ProofMismatch)?
                .to_owned()
        };
        let table = if prefix.is_empty() {
            physical_table
        } else {
            strip_prefix_case_insensitive(&physical_table, prefix)
                .unwrap_or(&physical_table)
                .to_owned()
        };
        objects.push((
            kind.to_ascii_lowercase(),
            name,
            table,
            sql.unwrap_or_default(),
        ));
    }
    objects.sort_by_key(|(kind, name, _, _)| (kind.clone(), name.to_lowercase()));

    let logical_names = objects
        .iter()
        .map(|(_, name, _, _)| name.clone())
        .collect::<Vec<_>>();
    let namespace = SQLiteStoreNamespace::new(prefix.to_string(), logical_names);
    let mut rows_hash = Sha256::new();
    let mut schema_hash = Sha256::new();
    let mut table_counts = BTreeMap::new();
    let mut total = 0i64;
    update_text_fields(
        &mut schema_hash,
        &[
            "tokenbar-schema-proof-v1",
            "module-user-version",
            &module_user_version.to_string(),
        ],
    );

    for (kind, name, table, sql) in &objects {
        let logical_sql = if unbind_schema {
            namespace.unbind(sql)?
        } else {
            sql.clone()
        };
        let canonical_sql = SQLiteStoreNamespace::canonical_sql(&logical_sql)?;
        update_text_fields(
            &mut schema_hash,
            &["object", kind, &name.to_lowercase(), &table.to_lowercase()],
        );
        update_text_fields(&mut schema_hash, &[&canonical_sql]);
    }

    for (_kind, name, _, logical_sql) in objects.iter().filter(|(kind, _, _, _)| kind == "table") {
        let physical = format!("{prefix}{name}");
        let quoted = SQLiteStoreNamespace::quote(&physical);
        let xinfo = table_xinfo_rows(connection, schema, &physical)?;
        update_text_fields(&mut schema_hash, &["table-xinfo", &name.to_lowercase()]);
        for row_fields in &xinfo {
            for value in &row_fields.canonical_values {
                update_binary_field(&mut schema_hash, value);
            }
        }

        let foreign_key_sql = format!("PRAGMA {schema}.foreign_key_list({quoted})");
        let mut statement = connection.prepare(&foreign_key_sql)?;
        let mut rows = statement.query([])?;
        update_text_fields(
            &mut schema_hash,
            &["foreign-key-list", &name.to_lowercase()],
        );
        while let Some(row) = rows.next()? {
            let target: String = row.get::<_, Option<String>>(2)?.unwrap_or_default();
            let target = strip_prefix_case_insensitive(&target, prefix).unwrap_or(&target);
            let fields = [
                row.get::<_, i64>(0)?.to_string(),
                row.get::<_, i64>(1)?.to_string(),
                target.to_lowercase(),
                row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                row.get::<_, Option<String>>(4)?.unwrap_or_default(),
                row.get::<_, Option<String>>(5)?.unwrap_or_default(),
                row.get::<_, Option<String>>(6)?.unwrap_or_default(),
                row.get::<_, Option<String>>(7)?.unwrap_or_default(),
            ];
            update_text_fields(
                &mut schema_hash,
                &fields.iter().map(String::as_str).collect::<Vec<_>>(),
            );
        }

        let index_list_sql = format!("PRAGMA {schema}.index_list({quoted})");
        let mut statement = connection.prepare(&index_list_sql)?;
        let mut rows = statement.query([])?;
        let mut indexes = Vec::new();
        while let Some(row) = rows.next()? {
            let physical_index: String = row.get(1)?;
            indexes.push((
                logical_index_name(&physical_index, prefix),
                physical_index,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
            ));
        }
        indexes.sort_by_key(|(logical, _, _, _, _)| logical.to_lowercase());
        update_text_fields(&mut schema_hash, &["index-list", &name.to_lowercase()]);
        for (logical_index, physical_index, unique, origin, partial) in indexes {
            update_text_fields(
                &mut schema_hash,
                &[
                    &logical_index.to_lowercase(),
                    &unique.to_string(),
                    &origin,
                    &partial.to_string(),
                ],
            );
            let index_sql = format!(
                "PRAGMA {schema}.index_xinfo({})",
                SQLiteStoreNamespace::quote(&physical_index)
            );
            let mut statement = connection.prepare(&index_sql)?;
            let width = statement.column_count();
            let mut rows = statement.query([])?;
            while let Some(row) = rows.next()? {
                for column in 0..width {
                    update_canonical_value(&mut schema_hash, row.get_ref(column)?);
                }
            }
        }

        let columns = xinfo
            .iter()
            .filter(|column| column.hidden != 1)
            .map(|column| column.name.clone())
            .collect::<Vec<_>>();
        if columns.is_empty() {
            return Err(BusinessStoreError::UnsupportedSchema(name.clone()));
        }
        let rowid = rowid_alias(logical_sql, &columns)?;
        let projection = rowid
            .iter()
            .cloned()
            .chain(columns.iter().cloned())
            .map(|column| SQLiteStoreNamespace::quote(&column))
            .collect::<Vec<_>>();
        let order_by = projection
            .iter()
            .map(|column| format!("{column} COLLATE BINARY"))
            .collect::<Vec<_>>()
            .join(",");
        let table_ref = format!("{schema}.{quoted}");
        let filter = if exclude_exact_relocation && name.eq_ignore_ascii_case("metadata") {
            " WHERE key <> 'release_upgrade_retention_v1'"
        } else { "" };
        let query = format!(
            "SELECT {} FROM {table_ref}{filter} ORDER BY {order_by}",
            projection.join(",")
        );
        let mut statement = connection.prepare(&query)?;
        let width = statement.column_count();
        let mut rows = statement.query([])?;
        let mut count = 0i64;
        update_text_fields(&mut rows_hash, &["table", &name.to_lowercase()]);
        while let Some(row) = rows.next()? {
            for column in 0..width {
                update_canonical_value(&mut rows_hash, row.get_ref(column)?);
            }
            count += 1;
        }
        total += count;
        table_counts.insert(name.clone(), count);
    }

    // A logical proof must not depend on another module's AUTOINCREMENT use.
    update_text_fields(&mut rows_hash, &["sqlite-sequence"]);
    if has_table(connection, schema, "sqlite_sequence")? {
        let mut statement = connection.prepare(&format!(
            "SELECT name,seq FROM {schema}.sqlite_sequence ORDER BY name"
        ))?;
        let sequences = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .filter_map(|(physical, sequence)| {
                if prefix.is_empty() {
                    Some((physical, sequence))
                } else {
                    strip_prefix_case_insensitive(&physical, prefix)
                        .map(|logical| (logical.to_owned(), sequence))
                }
            })
            .collect::<Vec<_>>();
        for (name, sequence) in &sequences {
            update_text_fields(
                &mut rows_hash,
                &[&name.to_lowercase(), &sequence.to_string()],
            );
        }
        if !sequences.is_empty() {
            let sequence_count = sequences.len() as i64;
            total += sequence_count;
            table_counts.insert("sqlite_sequence".to_string(), sequence_count);
        }
    }

    Ok(StoreProof {
        row_count: total,
        rows_digest: hex_digest(&rows_hash.finalize()),
        schema_digest: hex_digest(&schema_hash.finalize()),
        table_counts,
        module_user_version,
    })
}

pub(super) fn logical_footprint(connection: &Connection, prefix: &str) -> BusinessStoreResult<u64> {
    let mut statement = connection.prepare(
        "SELECT substr(name,?1) FROM main.sqlite_master WHERE type='table' AND lower(substr(name,1,7)) <> 'sqlite_' AND substr(name,1,?2)=?3 ORDER BY name",
    )?;
    let tables = statement
        .query_map(
            params![prefix.len() as i64 + 1, prefix.len() as i64, prefix],
            |row| row.get::<_, String>(0),
        )?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    let mut bytes = 0u64;
    for table in tables {
        bytes = bytes.saturating_add(table.len() as u64 + 1);
        let physical = format!("{prefix}{table}");
        let query = format!(
            "SELECT * FROM main.{}",
            SQLiteStoreNamespace::quote(&physical)
        );
        let mut statement = connection.prepare(&query)?;
        let width = statement.column_count();
        let mut rows = statement.query([])?;
        while let Some(row) = rows.next()? {
            for column in 0..width {
                bytes =
                    bytes.saturating_add(canonical_value_bytes(row.get_ref(column)?).len() as u64);
            }
        }
    }
    Ok(bytes)
}

struct TableXInfo {
    name: String,
    hidden: i64,
    canonical_values: Vec<Vec<u8>>,
}

fn table_xinfo_rows(
    connection: &Connection,
    schema: &str,
    table: &str,
) -> BusinessStoreResult<Vec<TableXInfo>> {
    let sql = format!(
        "PRAGMA {schema}.table_xinfo({})",
        SQLiteStoreNamespace::quote(table)
    );
    let mut statement = connection.prepare(&sql)?;
    let width = statement.column_count();
    let mut rows = statement.query([])?;
    let mut values = Vec::new();
    while let Some(row) = rows.next()? {
        let name = row.get::<_, String>(1)?;
        let hidden = row.get::<_, i64>(6)?;
        let mut canonical_values = Vec::with_capacity(width);
        for column in 0..width {
            canonical_values.push(canonical_value_bytes(row.get_ref(column)?));
        }
        values.push(TableXInfo {
            name,
            hidden,
            canonical_values,
        });
    }
    Ok(values)
}

fn update_text_fields(hash: &mut Sha256, fields: &[&str]) {
    for field in fields {
        update_binary_field(hash, field.as_bytes());
    }
}

fn update_binary_field(hash: &mut Sha256, field: &[u8]) {
    hash.update((field.len() as u64).to_be_bytes());
    hash.update(field);
}

fn update_canonical_value(hash: &mut Sha256, value: ValueRef<'_>) {
    let canonical = canonical_value_bytes(value);
    update_binary_field(hash, &canonical);
}

fn canonical_value_bytes(value: ValueRef<'_>) -> Vec<u8> {
    let (kind, bytes): (u8, Vec<u8>) = match value {
        ValueRef::Null => (5, Vec::new()),
        ValueRef::Integer(integer) => (1, integer.to_be_bytes().to_vec()),
        ValueRef::Real(real) => (2, real.to_bits().to_be_bytes().to_vec()),
        ValueRef::Text(text) => (3, text.to_vec()),
        ValueRef::Blob(blob) => (4, blob.to_vec()),
    };
    let mut canonical = Vec::with_capacity(9 + bytes.len());
    canonical.push(kind);
    canonical.extend_from_slice(&(bytes.len() as u64).to_be_bytes());
    canonical.extend_from_slice(&bytes);
    canonical
}

fn strip_prefix_case_insensitive<'a>(value: &'a str, prefix: &str) -> Option<&'a str> {
    value
        .get(..prefix.len())
        .filter(|head| head.eq_ignore_ascii_case(prefix))
        .map(|_| &value[prefix.len()..])
}

fn logical_index_name(physical: &str, prefix: &str) -> String {
    if let Some(suffix) = physical.strip_prefix("sqlite_autoindex_") {
        if let Some(logical) = strip_prefix_case_insensitive(suffix, prefix) {
            return format!("sqlite_autoindex_{logical}");
        }
    }
    strip_prefix_case_insensitive(physical, prefix)
        .unwrap_or(physical)
        .to_owned()
}
