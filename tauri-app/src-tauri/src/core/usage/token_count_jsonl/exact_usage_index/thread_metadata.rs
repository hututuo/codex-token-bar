//! Read and publish the disposable session-title projection.
//!
//! Staging reads live external state through the existing reader. Applying a
//! stage borrows the caller's transaction; only the metadata-only entrypoint
//! starts and commits its own transaction on the supplied Exact connection.

use super::{external_state, file_signature};
use super::connection::{Connection, Transaction};
use super::store_metadata::{metadata_i64, metadata_text, set_metadata};
use crate::models::LocalDataWarning;
use rusqlite::{params, TransactionBehavior};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::path::Path;

const THREAD_METADATA_FALLBACK_MAX_CHARS: usize = 240;

#[derive(Clone, Debug)]
pub(super) struct StagedThreadMetadata {
    pub(super) signature: Option<(String, String)>,
    pub(super) source_signature: Option<String>,
    pub(super) rows: Vec<(String, String, Option<i64>)>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ThreadMetadataApplyOutcome {
    Unchanged,
    SignatureOnly,
    ContentChanged,
}

pub(super) enum ThreadMetadataStage {
    /// The state database signature still matches the published metadata.
    Unchanged,
    /// The complete replacement was read successfully and is safe to apply.
    Updated(StagedThreadMetadata),
    /// Reading the replacement failed. Keep the published rows and signature.
    Failed,
}

pub(super) fn sync_thread_metadata(
    transaction: &Transaction<'_>,
    codex_home: &Path,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<bool, String> {
    let previous = (
        metadata_text(transaction, "state_size")?,
        metadata_text(transaction, "state_modified_ns")?,
    );
    let stage = stage_thread_metadata(codex_home, previous,
        metadata_text(transaction, "state_source_signature")?, warnings)?;
    Ok(matches!(
        apply_thread_metadata_stage(transaction, stage)?,
        ThreadMetadataApplyOutcome::ContentChanged
    ))
}

fn display_thread_title(
    title: Option<String>,
    first_user_message: Option<String>,
    preview: Option<String>,
) -> String {
    if let Some(title) = title.filter(|value| !value.trim().is_empty()) {
        // A formal title is authoritative product data. Keep it byte-for-byte
        // instead of applying a display-layer limit in the durable catalog.
        return title;
    }

    for fallback in [first_user_message, preview] {
        let Some(fallback) = fallback else {
            continue;
        };
        let fallback = fallback.trim();
        if fallback.is_empty() {
            continue;
        }
        if fallback.chars().count() <= THREAD_METADATA_FALLBACK_MAX_CHARS {
            return fallback.to_owned();
        }
        let mut bounded = fallback
            .chars()
            .take(THREAD_METADATA_FALLBACK_MAX_CHARS.saturating_sub(1))
            .collect::<String>();
        bounded.push('…');
        return bounded;
    }

    "Untitled".into()
}

pub(super) fn stage_thread_metadata(
    codex_home: &Path,
    previous: (Option<String>, Option<String>),
    previous_source: Option<String>,
    warnings: &mut Vec<LocalDataWarning>,
) -> Result<ThreadMetadataStage, String> {
    let database = codex_home.join("state_5.sqlite");
    match fs::symlink_metadata(&database) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(ThreadMetadataStage::Updated(StagedThreadMetadata {
                signature: None, source_signature: None, rows: Vec::new(),
            }));
        }
        Err(error) => {
            warnings.push(thread_info_warning(format!("检查会话标题索引失败：{error}")));
            return Ok(ThreadMetadataStage::Failed);
        }
        Ok(_) => {}
    }
    let signature = match file_signature(&database) {
        Ok(value) => value,
        Err(error) => {
            warnings.push(thread_info_warning(error));
            return Ok(ThreadMetadataStage::Failed);
        }
    };
    let signature_text = Some((signature.size.to_string(), signature.modified_ns.to_string()));
    // Stat is provenance, not proof of freshness. A stat-only change still
    // refreshes that provenance without advancing the row-content revision.
    let previous_token = if previous == signature_text.clone().unzip() { previous_source.as_deref() } else { None };
    let result = external_state::read_snapshot(&database, previous_token, |connection| {
        let mut column_query = connection.prepare("PRAGMA table_info(threads)")
            .map_err(|e| format!("读取会话标题索引结构失败：{e}"))?;
        let columns = column_query.query_map([], |row| row.get::<_, String>(1))
            .map_err(|e| e.to_string())?.collect::<rusqlite::Result<HashSet<_>>>()
            .map_err(|e| e.to_string())?;
        drop(column_query);
        if !columns.contains("id") || !columns.contains("title")
            || (!columns.contains("updated_at") && !columns.contains("updated_at_ms")) {
            return Err("读取会话标题索引结构失败：缺少必需的 id、title 或更新时间列".into());
        }
        let project = |name: &'static str| if columns.contains(name) { name } else { "NULL" };
        let sql = format!("SELECT id, title, {}, {}, COALESCE({}, {}) FROM threads",
            project("first_user_message"), project("preview"), project("updated_at_ms"), project("updated_at"));
        let mut statement = connection.prepare(&sql).map_err(|e| e.to_string())?;
        let rows = statement.query_map([], |row| Ok((
            row.get::<_, String>(0)?,
            display_thread_title(row.get(1)?, row.get(2)?, row.get(3)?),
            row.get::<_, Option<i64>>(4)?.map(normalize_thread_timestamp),
        ))).map_err(|e| e.to_string())?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|e| e.to_string())
    });
    match result {
        Ok(external_state::SourceRead::Unchanged) => Ok(ThreadMetadataStage::Unchanged),
        Ok(external_state::SourceRead::Updated { token, value }) => {
            // Windows uses short connections so it cannot use a cross-open
            // data_version comparison. Compare only after reading the actual
            // committed rows, never skip a read based on stat/WAL length.
            let token = if cfg!(windows) {
                let bytes = serde_json::to_vec(&value).map_err(|e| e.to_string())?;
                let identity = signature.physical.map(|s| (s.volume, s.file_id));
                format!("sqlite-live-rows-v2:{identity:?}:{:x}", Sha256::digest(bytes))
            } else { token };
            if previous_source.as_deref() == Some(token.as_str()) && previous == signature_text.clone().unzip() {
                return Ok(ThreadMetadataStage::Unchanged);
            }
            Ok(ThreadMetadataStage::Updated(StagedThreadMetadata {
                signature: signature_text,
                source_signature: Some(token), rows: value,
            }))
        }
        Err(error) => {
            warnings.push(thread_info_warning(format!("读取会话标题索引失败，已保留原有标题：{error}")));
            Ok(ThreadMetadataStage::Failed)
        }
    }
}

fn apply_thread_metadata_stage(
    transaction: &Transaction<'_>,
    stage: ThreadMetadataStage,
) -> Result<ThreadMetadataApplyOutcome, String> {
    let ThreadMetadataStage::Updated(staged) = stage else {
        return Ok(ThreadMetadataApplyOutcome::Unchanged);
    };
    transaction
        .execute_batch(
            r#"
            CREATE TEMP TABLE IF NOT EXISTS thread_metadata_stage (
                session_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                updated_at INTEGER
            ) WITHOUT ROWID;
            DELETE FROM temp.thread_metadata_stage;
            "#,
        )
        .map_err(|error| format!("无法准备会话标题增量暂存：{error}"))?;
    {
        let mut insert = transaction
            .prepare(
                "INSERT INTO temp.thread_metadata_stage(session_id, title, updated_at) VALUES (?1, ?2, ?3)",
            )
            .map_err(|error| format!("无法准备会话标题增量写入：{error}"))?;
        for (session_id, title, updated_at) in staged.rows {
            insert
                .execute(params![session_id, title, updated_at])
                .map_err(|error| format!("写入会话标题增量暂存失败：{error}"))?;
        }
    }

    let content_changed = transaction
        .query_row(
            r#"
            SELECT
                EXISTS(
                    SELECT 1
                    FROM temp.thread_metadata_stage staged
                    WHERE NOT EXISTS(
                        SELECT 1
                        FROM session_metadata published
                        WHERE published.session_id = staged.session_id
                          AND published.title = staged.title
                          AND published.updated_at IS staged.updated_at
                    )
                )
                OR EXISTS(
                    SELECT 1
                    FROM session_metadata published
                    WHERE NOT EXISTS(
                        SELECT 1
                        FROM temp.thread_metadata_stage staged
                        WHERE staged.session_id = published.session_id
                    )
                )
            "#,
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("无法比较会话标题增量：{error}"))?;

    if content_changed {
        transaction
            .execute(
                r#"
                INSERT INTO session_metadata(session_id, title, updated_at)
                SELECT staged.session_id, staged.title, staged.updated_at
                FROM temp.thread_metadata_stage staged
                WHERE NOT EXISTS(
                    SELECT 1
                    FROM session_metadata published
                    WHERE published.session_id = staged.session_id
                      AND published.title = staged.title
                      AND published.updated_at IS staged.updated_at
                )
                ON CONFLICT(session_id) DO UPDATE SET
                    title = excluded.title,
                    updated_at = excluded.updated_at
                "#,
                [],
            )
            .map_err(|error| format!("写入会话标题增量失败：{error}"))?;
        transaction
            .execute(
                r#"
                DELETE FROM session_metadata
                WHERE NOT EXISTS(
                    SELECT 1
                    FROM temp.thread_metadata_stage staged
                    WHERE staged.session_id = session_metadata.session_id
                )
                "#,
                [],
            )
            .map_err(|error| format!("删除已确认消失的会话标题失败：{error}"))?;
    }

    if let Some((size, modified_ns)) = staged.signature {
        set_metadata(transaction, "state_size", &size)?;
        set_metadata(transaction, "state_modified_ns", &modified_ns)?;
    } else {
        transaction
            .execute(
                "DELETE FROM metadata WHERE key IN ('state_size', 'state_modified_ns')",
                [],
            )
            .map_err(|error| format!("无法清理会话标题索引签名：{error}"))?;
    }
    if let Some(signature) = staged.source_signature {
        set_metadata(transaction, "state_source_signature", &signature)?;
    } else {
        transaction.execute("DELETE FROM metadata WHERE key='state_source_signature'", [])
            .map_err(|error| format!("无法清理会话标题来源签名：{error}"))?;
    }
    Ok(if content_changed {
        ThreadMetadataApplyOutcome::ContentChanged
    } else {
        ThreadMetadataApplyOutcome::SignatureOnly
    })
}

pub(super) fn publish_thread_metadata_only(
    connection: &mut Connection,
    staged: StagedThreadMetadata,
) -> Result<u64, String> {
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("无法开始会话标题索引发布事务：{error}"))?;
    let outcome = apply_thread_metadata_stage(&transaction, ThreadMetadataStage::Updated(staged))?;
    let current_revision = metadata_i64(&transaction, "revision")?.unwrap_or(0);
    let revision = if outcome == ThreadMetadataApplyOutcome::ContentChanged {
        let next = current_revision.saturating_add(1);
        set_metadata(&transaction, "revision", &next.to_string())?;
        next
    } else {
        current_revision
    };
    transaction
        .commit()
        .map_err(|error| format!("无法提交会话标题索引发布事务：{error}"))?;
    Ok(u64::try_from(revision).unwrap_or(0))
}

fn normalize_thread_timestamp(value: i64) -> i64 {
    if value > 10_000_000_000 {
        value / 1000
    } else {
        value
    }
}

fn thread_info_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "thread_info".into(),
        message,
    }
}
