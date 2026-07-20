// SPDX-License-Identifier: AGPL-3.0-only
// Behavior adapted from CodexPlusPlus v1.2.41 (BigPizzaV3), then rewritten
// for Codex Token Bar's Rust bridge. See OPEN_SOURCE_NOTICES.md.

use crate::core::atomic_file::{write_atomically_streaming, AtomicWriteError};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use serde::Serialize;
use serde_json::Value;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

const DATABASE_BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const BACKUP_ATTEMPTS: usize = 64;
static BACKUP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkdownExportResult {
    pub filename: String,
    pub markdown: String,
    pub message: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceMoveResult {
    pub message: String,
    pub previous_cwd: String,
    pub target_cwd: String,
}

#[derive(Clone, Debug)]
struct ThreadRecord {
    title: String,
    cwd: String,
    rollout_path: String,
}

pub fn export_markdown(
    codex_home: &Path,
    thread_id: &str,
    fallback_title: &str,
) -> Result<MarkdownExportResult, String> {
    validate_thread_id(thread_id)?;
    let connection = open_state_database(codex_home, true)?;
    let record = thread_record(&connection, thread_id)?;
    let title = display_title(if record.title.trim().is_empty() {
        fallback_title
    } else {
        &record.title
    });
    let rollout = trusted_rollout_path(codex_home, &record.rollout_path)?;
    let markdown = render_markdown_from_rollout(&rollout, &title)?;
    let filename = build_filename(&title, thread_id);
    Ok(MarkdownExportResult {
        message: format!("已生成 Markdown：{filename}"),
        filename,
        markdown,
    })
}

pub fn move_thread_workspace(
    codex_home: &Path,
    thread_id: &str,
    target_cwd: &str,
) -> Result<WorkspaceMoveResult, String> {
    validate_thread_id(thread_id)?;
    let target = canonical_target_directory(target_cwd)?;
    let mut connection = open_state_database(codex_home, false)?;
    let record = thread_record(&connection, thread_id)?;
    let rollout = if record.rollout_path.trim().is_empty() {
        None
    } else {
        Some(trusted_rollout_path(codex_home, &record.rollout_path)?)
    };
    let backup = rollout.as_deref().map(create_rollout_backup).transpose()?;

    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| format!("启动会话项目移动事务失败：{error}"))?;
    let changed = transaction
        .execute(
            "UPDATE threads SET cwd = ?1 WHERE id = ?2",
            params![target.to_string_lossy().as_ref(), thread_id],
        )
        .map_err(|error| format!("更新会话项目目录失败：{error}"))?;
    if changed != 1 {
        cleanup_backup(backup.as_deref());
        return Err(format!("本地数据库中未找到会话：{thread_id}"));
    }

    if let Some(rollout) = rollout.as_deref() {
        if let Err(error) = rewrite_rollout_atomically(rollout, thread_id, &target) {
            cleanup_backup(backup.as_deref());
            return Err(error);
        }
    }

    if let Err(error) = transaction.commit() {
        let restore = match (rollout.as_deref(), backup.as_deref()) {
            (Some(rollout), Some(backup)) => restore_rollout(rollout, backup),
            _ => Ok(()),
        };
        cleanup_backup(backup.as_deref());
        return match restore {
            Ok(()) => Err(format!("提交会话项目移动失败，rollout 已恢复：{error}")),
            Err(restore_error) => Err(format!(
                "提交会话项目移动失败且 rollout 恢复失败：{error}；{restore_error}"
            )),
        };
    }

    cleanup_backup(backup.as_deref());
    Ok(WorkspaceMoveResult {
        message: "已移动对话".into(),
        previous_cwd: record.cwd,
        target_cwd: target.to_string_lossy().into_owned(),
    })
}

fn open_state_database(codex_home: &Path, read_only: bool) -> Result<Connection, String> {
    let database = codex_home.join("state_5.sqlite");
    if !database.is_file() {
        return Err(format!("Codex 本地数据库不可用：{}", database.display()));
    }
    let flags = if read_only {
        OpenFlags::SQLITE_OPEN_READ_ONLY
    } else {
        OpenFlags::SQLITE_OPEN_READ_WRITE
    } | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let connection = Connection::open_with_flags(&database, flags)
        .map_err(|error| format!("打开 Codex 本地数据库失败：{error}"))?;
    connection
        .busy_timeout(DATABASE_BUSY_TIMEOUT)
        .map_err(|error| format!("设置 Codex 数据库等待时间失败：{error}"))?;
    Ok(connection)
}

fn thread_record(connection: &Connection, thread_id: &str) -> Result<ThreadRecord, String> {
    let mut schema = connection
        .prepare("PRAGMA table_info(threads)")
        .map_err(|error| format!("读取 Codex 会话表结构失败：{error}"))?;
    let columns = schema
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| format!("读取 Codex 会话表字段失败：{error}"))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("解析 Codex 会话表字段失败：{error}"))?;
    for required in ["id", "title", "cwd", "rollout_path"] {
        if !columns.iter().any(|column| column == required) {
            return Err(format!("当前 Codex 本地存储缺少字段：{required}"));
        }
    }
    connection
        .query_row(
            "SELECT title, cwd, rollout_path FROM threads WHERE id = ?1 LIMIT 1",
            params![thread_id],
            |row| {
                Ok(ThreadRecord {
                    title: row.get::<_, Option<String>>(0)?.unwrap_or_default(),
                    cwd: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    rollout_path: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                })
            },
        )
        .optional()
        .map_err(|error| format!("读取 Codex 会话失败：{error}"))?
        .ok_or_else(|| format!("本地数据库中未找到会话：{thread_id}"))
}

fn trusted_rollout_path(codex_home: &Path, raw: &str) -> Result<PathBuf, String> {
    if raw.trim().is_empty() {
        return Err("会话缺少 rollout 文件路径".into());
    }
    let home = codex_home
        .canonicalize()
        .map_err(|error| format!("解析 Codex Home 失败：{error}"))?;
    let raw = PathBuf::from(raw.trim());
    let candidate = if raw.is_absolute() {
        raw
    } else {
        codex_home.join(raw)
    };
    let resolved = candidate.canonicalize().map_err(|error| {
        format!(
            "rollout 文件不存在或不可读取：{}（{error}）",
            candidate.display()
        )
    })?;
    if !path_is_within(&home, &resolved) || !resolved.is_file() {
        return Err(format!(
            "rollout 文件不存在或不在当前 Codex Home 内：{}",
            resolved.display()
        ));
    }
    Ok(resolved)
}

#[cfg(not(windows))]
fn path_is_within(root: &Path, candidate: &Path) -> bool {
    candidate.starts_with(root) && candidate != root
}

#[cfg(windows)]
fn path_is_within(root: &Path, candidate: &Path) -> bool {
    let root = root.components().collect::<Vec<_>>();
    let candidate = candidate.components().collect::<Vec<_>>();
    candidate.len() > root.len()
        && root.iter().zip(candidate.iter()).all(|(left, right)| {
            left.as_os_str()
                .to_string_lossy()
                .eq_ignore_ascii_case(&right.as_os_str().to_string_lossy())
        })
}

fn canonical_target_directory(raw: &str) -> Result<PathBuf, String> {
    let expanded = expand_tilde(raw.trim());
    let resolved = expanded
        .canonicalize()
        .map_err(|error| format!("目标项目目录不可用：{}（{error}）", expanded.display()))?;
    if !resolved.is_dir() {
        return Err(format!("目标项目目录不可用：{}", resolved.display()));
    }
    Ok(resolved)
}

fn expand_tilde(raw: &str) -> PathBuf {
    if raw != "~" && !raw.starts_with("~/") && !raw.starts_with("~\\") {
        return PathBuf::from(raw);
    }
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from);
    match (
        home,
        raw.strip_prefix("~/").or_else(|| raw.strip_prefix("~\\")),
    ) {
        (Some(home), Some(rest)) => home.join(rest),
        (Some(home), None) => home,
        _ => PathBuf::from(raw),
    }
}

fn render_markdown_from_rollout(path: &Path, title: &str) -> Result<String, String> {
    let file = File::open(path)
        .map_err(|error| format!("打开 rollout 文件失败：{}（{error}）", path.display()))?;
    let mut markdown = format!("# {title}\n\n");
    let mut message_count = 0usize;
    for line in BufReader::new(file).lines() {
        let line = line.map_err(|error| format!("读取 rollout 文件失败：{error}"))?;
        let Ok(event) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if event.get("type").and_then(Value::as_str) != Some("response_item") {
            continue;
        }
        let Some(payload) = event.get("payload") else {
            continue;
        };
        if payload.get("type").and_then(Value::as_str) != Some("message") {
            continue;
        }
        let Some(role @ ("user" | "assistant")) = payload.get("role").and_then(Value::as_str)
        else {
            continue;
        };
        let Some(content) = payload.get("content").and_then(Value::as_array) else {
            continue;
        };
        let body = content
            .iter()
            .filter_map(serialize_content_block)
            .collect::<Vec<_>>()
            .join("\n\n");
        let body = body.trim();
        if body.is_empty() {
            continue;
        }
        message_count += 1;
        markdown.push_str(if role == "user" {
            "### User\n"
        } else {
            "### Assistant\n"
        });
        if let Some(timestamp) = event
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(format_timestamp)
        {
            markdown.push('_');
            markdown.push_str(&timestamp);
            markdown.push_str("_\n");
        }
        markdown.push('\n');
        markdown.push_str(body);
        markdown.push_str("\n\n");
    }
    if message_count == 0 {
        return Err("未找到可导出的用户或助手消息".into());
    }
    Ok(markdown)
}

fn serialize_content_block(block: &Value) -> Option<String> {
    match block.get("type").and_then(Value::as_str) {
        Some("input_text" | "output_text") => {
            let text = block
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let text = text.replace("\r\n", "\n").replace('\r', "\n");
            let trimmed = text.trim_matches('\n');
            (!trimmed.trim().is_empty()).then(|| trimmed.to_string())
        }
        Some("input_image") => {
            let url = block
                .get("image_url")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim();
            Some(if url.is_empty() || url.starts_with("data:") {
                "> Image attachment".into()
            } else {
                format!("> Image attachment\n[Image link](<{url}>)")
            })
        }
        _ => None,
    }
}

fn format_timestamp(raw: &str) -> Option<String> {
    let date_time = raw.get(..19)?;
    Some(date_time.replace('T', " "))
}

fn display_title(raw: &str) -> String {
    let title = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if title.is_empty() {
        "Untitled session".into()
    } else {
        title
    }
}

fn build_filename(title: &str, thread_id: &str) -> String {
    let mut safe = title
        .chars()
        .map(|character| {
            if character.is_control() || "<>:\"/\\|?*".contains(character) {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches([' ', '.'])
        .chars()
        .take(80)
        .collect::<String>();
    safe = safe.trim_matches([' ', '.']).to_string();
    if safe.is_empty() {
        safe = "Untitled session".into();
    }
    format!("{safe}-{thread_id}.md")
}

fn create_rollout_backup(path: &Path) -> Result<PathBuf, String> {
    let parent = path
        .parent()
        .ok_or_else(|| "rollout 文件缺少父目录".to_string())?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("rollout.jsonl");
    for _ in 0..BACKUP_ATTEMPTS {
        let sequence = BACKUP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let backup = parent.join(format!(
            ".{name}.codex-token-bar-move-backup-{}-{sequence:020}",
            std::process::id()
        ));
        let mut destination = match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&backup)
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("创建 rollout 回滚副本失败：{error}")),
        };
        let mut source =
            File::open(path).map_err(|error| format!("打开 rollout 备份源失败：{error}"))?;
        if let Err(error) = std::io::copy(&mut source, &mut destination)
            .and_then(|_| destination.flush())
            .and_then(|_| destination.sync_all())
        {
            let _ = std::fs::remove_file(&backup);
            return Err(format!("写入 rollout 回滚副本失败：{error}"));
        }
        return Ok(backup);
    }
    Err("创建唯一 rollout 回滚副本失败".into())
}

fn rewrite_rollout_atomically(path: &Path, thread_id: &str, target: &Path) -> Result<(), String> {
    let target = target.to_string_lossy().into_owned();
    write_atomically_streaming(path, |output| {
        rewrite_rollout(path, output, thread_id, &target)
    })
    .map_err(atomic_write_error)
}

fn rewrite_rollout(
    source_path: &Path,
    output: &mut File,
    thread_id: &str,
    target_cwd: &str,
) -> Result<(), String> {
    let source = File::open(source_path).map_err(|error| error.to_string())?;
    let mut reader = BufReader::new(source);
    let mut line = Vec::new();
    let mut matched = false;
    loop {
        line.clear();
        let read = reader
            .read_until(b'\n', &mut line)
            .map_err(|error| error.to_string())?;
        if read == 0 {
            break;
        }
        let newline = if line.ends_with(b"\r\n") {
            b"\r\n".as_slice()
        } else if line.ends_with(b"\n") {
            b"\n".as_slice()
        } else {
            b"".as_slice()
        };
        let json_len = line.len().saturating_sub(newline.len());
        let mut event = match serde_json::from_slice::<Value>(&line[..json_len]) {
            Ok(event) => event,
            Err(_) => {
                output.write_all(&line).map_err(|error| error.to_string())?;
                continue;
            }
        };
        let is_match = event.get("type").and_then(Value::as_str) == Some("session_meta")
            && event
                .get("payload")
                .and_then(|payload| payload.get("id"))
                .and_then(Value::as_str)
                == Some(thread_id);
        if !is_match {
            output.write_all(&line).map_err(|error| error.to_string())?;
            continue;
        }
        matched = true;
        if let Some(payload) = event.get_mut("payload").and_then(Value::as_object_mut) {
            payload.insert("cwd".into(), Value::String(target_cwd.into()));
        }
        serde_json::to_writer(&mut *output, &event).map_err(|error| error.to_string())?;
        output
            .write_all(newline)
            .map_err(|error| error.to_string())?;
    }
    if matched {
        Ok(())
    } else {
        Err(format!("rollout 中未找到会话元数据：{thread_id}"))
    }
}

fn restore_rollout(path: &Path, backup: &Path) -> Result<(), String> {
    write_atomically_streaming(path, |output| {
        let mut source = File::open(backup).map_err(|error| error.to_string())?;
        std::io::copy(&mut source, output)
            .map(|_| ())
            .map_err(|error| error.to_string())
    })
    .map_err(atomic_write_error)
}

fn atomic_write_error(error: AtomicWriteError) -> String {
    format!("原子更新 rollout 失败：{error}")
}

fn cleanup_backup(path: Option<&Path>) {
    if let Some(path) = path {
        if let Err(error) = std::fs::remove_file(path) {
            eprintln!(
                "Codex Token Bar: rollout move backup cleanup failed path={} error={error}",
                path.display()
            );
        }
    }
}

fn validate_thread_id(value: &str) -> Result<(), String> {
    let bytes = value.as_bytes();
    let valid = bytes.len() == 36
        && bytes.iter().copied().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        });
    valid
        .then_some(())
        .ok_or_else(|| "会话 ID 不是有效 UUID".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        home: PathBuf,
        rollout: PathBuf,
        thread_id: String,
        original_cwd: PathBuf,
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.home);
        }
    }

    #[test]
    fn markdown_export_streams_real_user_and_assistant_messages() {
        let fixture = fixture();
        let result = export_markdown(&fixture.home, &fixture.thread_id, "备用标题").unwrap();
        assert_eq!(
            result.filename,
            format!("真实会话-{}.md", fixture.thread_id)
        );
        assert!(result.markdown.starts_with("# 真实会话\n"));
        assert!(result.markdown.contains("### User"));
        assert!(result.markdown.contains("你好，Codex"));
        assert!(result.markdown.contains("### Assistant"));
        assert!(result.markdown.contains("已经完成"));
        assert!(result.markdown.contains("2026-07-20 12:01:00"));
    }

    #[test]
    fn project_move_updates_database_and_rollout_together() {
        let fixture = fixture();
        let target = fixture.home.join("Target Project");
        std::fs::create_dir_all(&target).unwrap();

        let result = move_thread_workspace(
            &fixture.home,
            &fixture.thread_id,
            target.to_string_lossy().as_ref(),
        )
        .unwrap();

        assert_eq!(PathBuf::from(result.previous_cwd), fixture.original_cwd);
        assert_eq!(
            PathBuf::from(result.target_cwd),
            target.canonicalize().unwrap()
        );
        let connection = Connection::open(fixture.home.join("state_5.sqlite")).unwrap();
        let cwd: String = connection
            .query_row(
                "SELECT cwd FROM threads WHERE id = ?1",
                params![fixture.thread_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(PathBuf::from(cwd), target.canonicalize().unwrap());
        let first = std::fs::read_to_string(&fixture.rollout)
            .unwrap()
            .lines()
            .next()
            .unwrap()
            .to_string();
        let event: Value = serde_json::from_str(&first).unwrap();
        let expected_target = target
            .canonicalize()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        assert_eq!(
            event.pointer("/payload/cwd").and_then(Value::as_str),
            Some(expected_target.as_str())
        );
        assert!(std::fs::read_dir(fixture.rollout.parent().unwrap())
            .unwrap()
            .all(|entry| !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains("move-backup")));
    }

    #[test]
    fn missing_target_never_changes_database_or_rollout() {
        let fixture = fixture();
        let before = std::fs::read(&fixture.rollout).unwrap();
        let error = move_thread_workspace(
            &fixture.home,
            &fixture.thread_id,
            fixture.home.join("Missing").to_string_lossy().as_ref(),
        )
        .unwrap_err();
        assert!(error.contains("目标项目目录不可用"));
        assert_eq!(std::fs::read(&fixture.rollout).unwrap(), before);
        let connection = Connection::open(fixture.home.join("state_5.sqlite")).unwrap();
        let cwd: String = connection
            .query_row(
                "SELECT cwd FROM threads WHERE id = ?1",
                params![fixture.thread_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(PathBuf::from(cwd), fixture.original_cwd);
    }

    fn fixture() -> Fixture {
        let sequence = BACKUP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let home = std::env::temp_dir().join(format!(
            "codex-token-bar-session-enhancements-{}-{sequence}",
            std::process::id()
        ));
        let sessions = home.join("sessions/2026/07/20");
        std::fs::create_dir_all(&sessions).unwrap();
        let thread_id = "019f5a7c-1234-7abc-8def-0123456789ab".to_string();
        let original_cwd = home.join("Original Project");
        std::fs::create_dir_all(&original_cwd).unwrap();
        let rollout = sessions.join(format!("rollout-{thread_id}.jsonl"));
        let contents = format!(
            "{{\"timestamp\":\"2026-07-20T12:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{thread_id}\",\"cwd\":{cwd:?}}}}}\n{{\"timestamp\":\"2026-07-20T12:01:00.000Z\",\"type\":\"response_item\",\"payload\":{{\"type\":\"message\",\"role\":\"user\",\"content\":[{{\"type\":\"input_text\",\"text\":\"你好，Codex\"}}]}}}}\n{{\"timestamp\":\"2026-07-20T12:02:00.000Z\",\"type\":\"response_item\",\"payload\":{{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"已经完成\"}}]}}}}\n",
            cwd = original_cwd.to_string_lossy(),
        );
        std::fs::write(&rollout, contents).unwrap();
        let connection = Connection::open(home.join("state_5.sqlite")).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, cwd TEXT, rollout_path TEXT);",
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO threads (id, title, cwd, rollout_path) VALUES (?1, ?2, ?3, ?4)",
                params![
                    thread_id,
                    "真实会话",
                    original_cwd.to_string_lossy().as_ref(),
                    rollout.to_string_lossy().as_ref(),
                ],
            )
            .unwrap();
        Fixture {
            home,
            rollout,
            thread_id,
            original_cwd,
        }
    }
}
