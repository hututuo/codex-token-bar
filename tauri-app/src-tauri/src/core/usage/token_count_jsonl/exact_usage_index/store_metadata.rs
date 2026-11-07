//! Metadata reads/writes and row-proof queries on the caller's connection.
//!
//! These are database operations, not pure contracts. No helper opens a handle,
//! begins a transaction or commits: callers retain snapshot/transaction ownership.
//! set_metadata writes durable metadata; schema11_query_digest executes its
//! caller's SQL in that existing snapshot. Its name/encoding also serve ledger
//! proofs and are kept byte-for-byte for historical compatibility.

use super::connection::Connection;
use rusqlite::{params, OptionalExtension};
use sha2::{Digest, Sha256};

pub(super) fn schema11_digest_value(hasher: &mut Sha256, value: rusqlite::types::ValueRef<'_>) {
    match value {
        rusqlite::types::ValueRef::Null => hasher.update([0]),
        rusqlite::types::ValueRef::Integer(value) => {
            hasher.update([1]);
            hasher.update(value.to_le_bytes());
        }
        rusqlite::types::ValueRef::Real(value) => {
            hasher.update([2]);
            hasher.update(value.to_bits().to_le_bytes());
        }
        rusqlite::types::ValueRef::Text(value) => {
            hasher.update([3]);
            hasher.update((value.len() as u64).to_le_bytes());
            hasher.update(value);
        }
        rusqlite::types::ValueRef::Blob(value) => {
            hasher.update([4]);
            hasher.update((value.len() as u64).to_le_bytes());
            hasher.update(value);
        }
    }
}

pub(super) fn schema11_finish_digest(hasher: Sha256) -> String {
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub(super) fn schema11_query_digest(
    connection: &Connection,
    sql: &str,
    parameters: impl rusqlite::Params,
    context: &str,
) -> Result<String, String> {
    let mut statement = connection
        .prepare(sql)
        .map_err(|error| format!("无法准备 schema 11 {context}逐行对账：{error}"))?;
    let column_count = statement.column_count();
    let mut rows = statement
        .query(parameters)
        .map_err(|error| format!("无法读取 schema 11 {context}逐行对账：{error}"))?;
    let mut hasher = Sha256::new();
    hasher.update(b"codex-token-bar-schema11-row-digest-v1");
    while let Some(row) = rows
        .next()
        .map_err(|error| format!("无法遍历 schema 11 {context}逐行对账：{error}"))?
    {
        hasher.update([0xff]);
        for column in 0..column_count {
            let value = row
                .get_ref(column)
                .map_err(|error| format!("无法解码 schema 11 {context}逐行对账：{error}"))?;
            schema11_digest_value(&mut hasher, value);
        }
    }
    Ok(schema11_finish_digest(hasher))
}

pub(super) fn table_row_count(connection: &Connection, table: &str) -> Result<i64, String> {
    connection
        .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
            row.get(0)
        })
        .map_err(|error| format!("无法统计精确 token 表 {table}：{error}"))
}

pub(super) fn table_exists_checked(connection: &Connection, table: &str) -> Result<bool, String> {
    connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
            [table],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法检查精确 token 表 {table}：{error}"))
}

pub(super) fn metadata_text(connection: &Connection, key: &str) -> Result<Option<String>, String> {
    connection
        .query_row(
            "SELECT value FROM metadata WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| format!("无法读取精确 token 索引元数据 {key}：{error}"))
}

pub(super) fn metadata_i64(connection: &Connection, key: &str) -> Result<Option<i64>, String> {
    let Some(value) = metadata_text(connection, key)? else {
        return Ok(None);
    };
    value.parse::<i64>().map(Some).map_err(|_| {
        format!("精确 token 索引元数据 {key} 已损坏：无法解析整数值 {value:?}，已拒绝按缺失值覆盖")
    })
}

pub(super) fn set_metadata(connection: &Connection, key: &str, value: &str) -> Result<(), String> {
    connection
        .execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES (?1, ?2)",
            params![key, value],
        )
        .map(|_| ())
        .map_err(|error| format!("无法写入精确 token 索引元数据 {key}：{error}"))
}

pub(super) fn column_exists_checked(
    connection: &Connection,
    table: &str,
    column: &str,
) -> Result<bool, String> {
    let mut statement = connection
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|error| format!("无法读取 SQLite 表结构 {table}：{error}"))?;
    let rows = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| format!("无法枚举 SQLite 表结构 {table}：{error}"))?;
    for row in rows {
        let name = row.map_err(|error| format!("无法读取 SQLite 字段 {table}：{error}"))?;
        if name == column {
            return Ok(true);
        }
    }
    Ok(false)
}

pub(super) fn required_startup_metadata_text(connection: &Connection, key: &str) -> Result<String, String> {
    metadata_text(connection, key)?
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("精确 token 启动缓存索引元数据 {key} 缺失"))
}

pub(super) fn required_startup_metadata_i64(connection: &Connection, key: &str) -> Result<i64, String> {
    let raw = required_startup_metadata_text(connection, key)?;
    raw.parse::<i64>()
        .map_err(|_| format!("精确 token 启动缓存索引元数据 {key} 无效"))
}

pub(super) fn required_startup_metadata_u64(connection: &Connection, key: &str) -> Result<u64, String> {
    let raw = required_startup_metadata_text(connection, key)?;
    raw.parse::<u64>()
        .map_err(|_| format!("精确 token 启动缓存索引元数据 {key} 无效"))
}

pub(super) fn optional_startup_metadata_u64(
    connection: &Connection,
    key: &str,
) -> Result<Option<u64>, String> {
    metadata_text(connection, key)?
        .map(|raw| {
            raw.parse::<u64>()
                .map_err(|_| format!("精确 token 启动缓存索引元数据 {key} 无效"))
        })
        .transpose()
}

pub(super) fn startup_metadata_bool(connection: &Connection, key: &str) -> Result<bool, String> {
    match metadata_text(connection, key)?.as_deref() {
        None | Some("0") => Ok(false),
        Some("1") => Ok(true),
        Some(_) => Err(format!("精确 token 启动缓存索引元数据 {key} 无效")),
    }
}
