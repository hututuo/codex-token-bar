// SPDX-License-Identifier: AGPL-3.0-only
// Behavior adapted from CodexPlusPlus v1.2.41 (BigPizzaV3), then rewritten
// for Codex Token Bar's Rust bridge. See OPEN_SOURCE_NOTICES.md.

use super::cross_process_lock::CrossProcessFileLock;
use super::provider_repair::safe_fs::{AtomicInstallPhase, PinnedHome};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::fs::File;
#[cfg(test)]
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Mutex, OnceLock,
};
use std::time::Duration;

const DATABASE_BUSY_TIMEOUT: Duration = Duration::from_secs(5);
static BACKUP_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static WORKSPACE_MOVE_LEASES: OnceLock<Mutex<HashSet<(PathBuf, String)>>> =
    OnceLock::new();
// v2 起与 Swift 端共用同一 JSON 形状与恢复语义：camelCase 键名（threadId、
// retainedOriginalRelativePath 全相对路径），retained 文件契约为"首行 = 原始
// rollout 首行"（本端只保留首行、Swift 端保留整文件，均满足），恢复判定与
// 还原一律只使用 retained 首行。v1 时期两端格式互不兼容，读到即显式拒绝。
const WORKSPACE_MOVE_SCHEMA_VERSION: u32 = 2;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkdownExportResult {
    pub filename: String,
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

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceMoveJournal {
    schema_version: u32,
    codex_home: String,
    state_database: String,
    thread_id: String,
    rollout_relative_path: String,
    retained_original_relative_path: String,
    original_cwd: String,
    target_cwd: String,
}

struct WorkspaceMoveLease {
    key: (PathBuf, String),
    _cross_process_lock: CrossProcessFileLock,
}

pub fn export_markdown(
    codex_home: &Path,
    thread_id: &str,
    fallback_title: &str,
    emit: &mut dyn FnMut(&str) -> Result<(), String>,
) -> Result<MarkdownExportResult, String> {
    validate_thread_id(thread_id)?;
    let connection = open_state_database(codex_home, true)?;
    let record = thread_record(&connection, thread_id)?;
    drop(connection);
    let title = display_title(if record.title.trim().is_empty() {
        fallback_title
    } else {
        &record.title
    });
    let rollout = trusted_rollout_path(codex_home, &record.rollout_path)?;
    render_markdown_from_rollout(&rollout, &title, emit)?;
    let filename = build_filename(&title, thread_id);
    Ok(MarkdownExportResult {
        message: format!("已生成 Markdown：{filename}"),
        filename,
    })
}

pub fn move_thread_workspace(
    codex_home: &Path,
    thread_id: &str,
    target_cwd: &str,
) -> Result<WorkspaceMoveResult, String> {
    validate_thread_id(thread_id)?;
    let target = canonical_target_directory(target_cwd)?;
    let pinned_home = PinnedHome::open(codex_home)?;
    let _lease = WorkspaceMoveLease::acquire(&pinned_home, thread_id)?;
    let database_path = state_database_path(codex_home)?;
    pinned_home.ensure_parent_directories(
        &workspace_move_journal_relative_path(thread_id),
    )?;
    recover_interrupted_workspace_move(
        &pinned_home,
        &database_path,
        thread_id,
    )?;

    let connection = open_state_database(codex_home, true)?;
    let record = thread_record(&connection, thread_id)?;
    drop(connection);
    let target = target.to_string_lossy().into_owned();
    if record.cwd == target {
        return finish_noop_move_with_drift_heal(
            &pinned_home,
            codex_home,
            &record,
            thread_id,
            target,
        );
    }

    let rollout_relative = if record.rollout_path.trim().is_empty() {
        None
    } else {
        let rollout = trusted_rollout_path(codex_home, &record.rollout_path)?;
        Some(trusted_relative_path(
            pinned_home.canonical_path(),
            &rollout,
        )?)
    };

    let journal = rollout_relative
        .as_deref()
        .map(|rollout_relative| {
            WorkspaceMoveJournal::new(
                &pinned_home,
                &database_path,
                thread_id,
                rollout_relative,
                &record.cwd,
                &target,
            )
        })
        .transpose()?;

    if let Some(journal) = journal.as_ref() {
        if let Err(error) = prepare_workspace_rollout_move(&pinned_home, journal) {
            return recover_after_workspace_move_error(
                &pinned_home,
                &database_path,
                thread_id,
                "准备项目移动失败",
                error,
            );
        }
    }

    let connection = open_state_database(codex_home, false)?;
    let changed = connection
        .execute(
            "
            UPDATE threads
            SET cwd = ?1
            WHERE id = ?2
              AND COALESCE(cwd, '') = ?3
            ",
            params![target, thread_id, record.cwd],
        )
        .map_err(|error| format!("更新会话项目目录失败：{error}"));
    match changed {
        Ok(1) => {}
        Ok(_) => {
            return recover_after_workspace_move_error(
                &pinned_home,
                &database_path,
                thread_id,
                "更新项目目录时检测到并发变化",
                format!("会话 {thread_id} 的原目录已变化"),
            )
        }
        Err(error) => {
            return recover_after_workspace_move_error(
                &pinned_home,
                &database_path,
                thread_id,
                "更新项目目录失败",
                error,
            )
        }
    }

    if journal.is_some() {
        recover_interrupted_workspace_move(
            &pinned_home,
            &database_path,
            thread_id,
        )
        .map_err(|error| {
            format!(
                "项目移动已写入数据库，但持久化事务收尾失败；下次会自动恢复：{error}"
            )
        })?;
    }

    Ok(WorkspaceMoveResult {
        message: "已移动对话".into(),
        previous_cwd: record.cwd,
        target_cwd: target,
    })
}

fn open_state_database(codex_home: &Path, read_only: bool) -> Result<Connection, String> {
    let database = state_database_path(codex_home)?;
    open_state_database_at(&database, read_only)
}

fn state_database_path(codex_home: &Path) -> Result<PathBuf, String> {
    Ok(super::provider_repair::resolve_sqlite_home_path(codex_home)?
        .join("state_5.sqlite"))
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
    Ok(persisted_workspace_path(&resolved))
}

fn persisted_workspace_path(path: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        return PathBuf::from(strip_windows_extended_prefix(
            path.to_string_lossy().as_ref(),
        ));
    }
    #[cfg(not(windows))]
    {
        path.to_path_buf()
    }
}

fn strip_windows_extended_prefix(raw: &str) -> String {
    if let Some(rest) = raw.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else if let Some(rest) = raw.strip_prefix(r"\\?\") {
        rest.to_string()
    } else {
        raw.to_string()
    }
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

fn render_markdown_from_rollout(
    path: &Path,
    title: &str,
    emit: &mut dyn FnMut(&str) -> Result<(), String>,
) -> Result<(), String> {
    let file = File::open(path)
        .map_err(|error| format!("打开 rollout 文件失败：{}（{error}）", path.display()))?;
    emit(&format!("# {title}\n\n"))?;
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
        if message_count > 0 {
            emit("\n\n")?;
        }
        message_count += 1;
        emit(if role == "user" {
            "### User\n"
        } else {
            "### Assistant\n"
        })?;
        if let Some(timestamp) = event
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(format_timestamp)
        {
            emit(&format!("_{timestamp}_\n"))?;
        }
        emit("\n")?;
        emit(body)?;
    }
    if message_count == 0 {
        return Err("未找到可导出的用户或助手消息".into());
    }
    emit("\n")?;
    Ok(())
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

impl WorkspaceMoveJournal {
    fn new(
        pinned_home: &PinnedHome,
        database_path: &Path,
        thread_id: &str,
        rollout_relative_path: &Path,
        original_cwd: &str,
        target_cwd: &str,
    ) -> Result<Self, String> {
        let parent = rollout_relative_path
            .parent()
            .ok_or_else(|| "rollout 文件缺少父目录".to_string())?;
        let retained_original_relative_path =
            parent.join(format!(".provider-session-prefix-workspace-{thread_id}"));
        let database_path = database_path.canonicalize().map_err(|error| {
            format!(
                "解析 Codex 本地数据库路径失败 {}：{error}",
                database_path.display()
            )
        })?;
        Ok(Self {
            schema_version: WORKSPACE_MOVE_SCHEMA_VERSION,
            codex_home: pinned_home
                .canonical_path()
                .to_string_lossy()
                .into_owned(),
            state_database: database_path.to_string_lossy().into_owned(),
            thread_id: thread_id.into(),
            rollout_relative_path: rollout_relative_path
                .to_string_lossy()
                .into_owned(),
            retained_original_relative_path: retained_original_relative_path
                .to_string_lossy()
                .into_owned(),
            original_cwd: original_cwd.into(),
            target_cwd: target_cwd.into(),
        })
    }
}

impl WorkspaceMoveLease {
    fn acquire(pinned_home: &PinnedHome, thread_id: &str) -> Result<Self, String> {
        let lock_relative = workspace_move_lock_relative_path(thread_id);
        pinned_home.ensure_parent_directories(&lock_relative)?;
        let key = (
            pinned_home.canonical_path().to_path_buf(),
            thread_id.to_string(),
        );
        let leases = WORKSPACE_MOVE_LEASES.get_or_init(|| Mutex::new(HashSet::new()));
        let mut leases = leases.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if !leases.insert(key.clone()) {
            return Err(format!(
                "会话 {thread_id} 的项目移动正在进行，请稍后重试"
            ));
        }
        drop(leases);

        let cross_process_lock = match CrossProcessFileLock::acquire(
            &pinned_home.canonical_path().join(lock_relative),
            &format!("会话 {thread_id} 的项目移动"),
        ) {
            Ok(lock) => lock,
            Err(error) => {
                WORKSPACE_MOVE_LEASES
                    .get()
                    .expect("workspace move leases initialized")
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .remove(&key);
                return Err(error);
            }
        };
        Ok(Self {
            key,
            _cross_process_lock: cross_process_lock,
        })
    }
}

impl Drop for WorkspaceMoveLease {
    fn drop(&mut self) {
        if let Some(leases) = WORKSPACE_MOVE_LEASES.get() {
            leases
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .remove(&self.key);
        }
    }
}

fn workspace_move_journal_relative_path(thread_id: &str) -> PathBuf {
    PathBuf::from("backups_state")
        .join("codex-token-bar")
        .join("workspace-move")
        .join(format!("{thread_id}.json"))
}

fn workspace_move_lock_relative_path(thread_id: &str) -> PathBuf {
    PathBuf::from("backups_state")
        .join("codex-token-bar")
        .join("workspace-move")
        .join(format!("{thread_id}.lock"))
}

fn trusted_relative_path(root: &Path, path: &Path) -> Result<PathBuf, String> {
    let relative = path.strip_prefix(root).map_err(|_| {
        format!(
            "rollout 文件不在固定 Codex Home 内：{}",
            path.display()
        )
    })?;
    if relative.as_os_str().is_empty() {
        return Err("rollout 文件相对路径为空".into());
    }
    Ok(relative.to_path_buf())
}

fn prepare_workspace_rollout_move(
    pinned_home: &PinnedHome,
    journal: &WorkspaceMoveJournal,
) -> Result<(), String> {
    let rollout_relative = Path::new(&journal.rollout_relative_path);
    let original_line = read_first_line(pinned_home, rollout_relative)?;
    let current_cwd = workspace_metadata_cwd(&original_line, &journal.thread_id)?;
    if current_cwd != journal.original_cwd {
        return Err(format!(
            "rollout 与数据库的项目目录不一致，已拒绝覆盖：数据库={}，rollout={current_cwd}",
            journal.original_cwd
        ));
    }

    let journal_relative = workspace_move_journal_relative_path(&journal.thread_id);
    let journal_bytes = serde_json::to_vec(journal)
        .map_err(|error| format!("编码项目移动事务失败：{error}"))?;
    install_new_managed_file(pinned_home, &journal_relative, &journal_bytes)?;
    install_new_managed_file(
        pinned_home,
        Path::new(&journal.retained_original_relative_path),
        &original_line,
    )?;

    let changed = pinned_home.transform_first_line_atomically(
        rollout_relative,
        |current| {
            if current != original_line {
                return Err(
                    "rollout 首行在项目移动准备期间发生变化，已拒绝覆盖".into(),
                );
            }
            rewrite_workspace_metadata_line(
                current,
                &journal.thread_id,
                &journal.target_cwd,
            )
            .map(Some)
        },
        |_, _| Ok(()),
    )?;
    if !changed {
        return Err("项目移动未产生预期的 rollout 首行更新".into());
    }
    Ok(())
}

fn install_new_managed_file(
    pinned_home: &PinnedHome,
    relative: &Path,
    bytes: &[u8],
) -> Result<(), String> {
    let expected_size =
        u64::try_from(bytes.len()).map_err(|_| "项目移动事务文件过大".to_string())?;
    pinned_home.install_atomically(
        relative,
        Some(expected_size),
        None,
        |target| {
            target
                .write_all(bytes)
                .map_err(|error| format!("写入项目移动事务文件失败：{error}"))
        },
        |phase, _| {
            if phase == AtomicInstallPhase::BeforeReplace
                && pinned_home.open_file(relative)?.is_some()
            {
                return Err(format!(
                    "项目移动事务文件已存在，已拒绝覆盖：{}",
                    relative.display()
                ));
            }
            Ok(())
        },
    )
}

fn recover_interrupted_workspace_move(
    pinned_home: &PinnedHome,
    database_path: &Path,
    thread_id: &str,
) -> Result<(), String> {
    let journal_relative = workspace_move_journal_relative_path(thread_id);
    let Some(journal_bytes) = read_managed_file_if_present(pinned_home, &journal_relative)? else {
        return Ok(());
    };
    let probe = serde_json::from_slice::<Value>(&journal_bytes)
        .map_err(|error| format!("解析项目移动事务失败：{error}"))?;
    let version = probe.get("schemaVersion").and_then(Value::as_u64);
    if version != Some(u64::from(WORKSPACE_MOVE_SCHEMA_VERSION)) {
        return Err(format!(
            "项目移动事务版本不受支持（schemaVersion={}）：v1 时期 Swift 与 Tauri \
             两端格式互不兼容，无法安全自动恢复；请用创建它的应用端完成恢复，\
             或人工核对后删除：{}",
            version.map_or_else(|| "缺失".to_string(), |value| value.to_string()),
            pinned_home
                .canonical_path()
                .join(&journal_relative)
                .display()
        ));
    }
    let journal = serde_json::from_slice::<WorkspaceMoveJournal>(&journal_bytes)
        .map_err(|error| format!("解析项目移动事务失败：{error}"))?;
    validate_workspace_move_journal(
        pinned_home,
        database_path,
        thread_id,
        &journal,
    )?;

    let rollout_relative = Path::new(&journal.rollout_relative_path);
    let current_line = read_first_line(pinned_home, rollout_relative)?;
    let current_cwd = workspace_metadata_cwd(&current_line, thread_id)?;
    let connection = open_state_database_at(database_path, true)?;
    let record = thread_record(&connection, thread_id)?;
    drop(connection);

    let retained_relative = Path::new(&journal.retained_original_relative_path);
    let retained_bytes = read_managed_file_if_present(pinned_home, retained_relative)?;
    match retained_bytes {
        Some(retained_bytes) => {
            // v2 契约：retained 首行 = 原始 rollout 首行。Swift 端保留整文件、
            // 本端只保留首行，判定与还原一律只取首行，两种形态都兼容。
            let retained_line = first_line_slice(&retained_bytes).to_vec();
            let retained_cwd = workspace_metadata_cwd(&retained_line, thread_id)?;
            match (
                record.cwd.as_str(),
                current_cwd.as_str(),
                retained_cwd.as_str(),
            ) {
                (database, current, retained)
                    if database == journal.original_cwd
                        && current == journal.original_cwd
                        && retained == journal.original_cwd =>
                {
                    // The process stopped after persisting the prefix but before replacing
                    // the rollout. Nothing was committed, so discard the prepared state.
                }
                (database, current, retained)
                    if database == journal.original_cwd
                        && current == journal.target_cwd
                        && retained == journal.original_cwd =>
                {
                    replace_workspace_first_line(
                        pinned_home,
                        rollout_relative,
                        &current_line,
                        &retained_line,
                    )?;
                }
                (database, current, retained)
                    if database == journal.target_cwd
                        && current == journal.original_cwd
                        && retained == journal.original_cwd =>
                {
                    replace_workspace_cwd(
                        pinned_home,
                        rollout_relative,
                        &current_line,
                        thread_id,
                        &journal.target_cwd,
                    )?;
                }
                (database, current, retained)
                    if database == journal.target_cwd
                        && current == journal.target_cwd
                        && retained == journal.original_cwd =>
                {
                    // Both durable stores reached the target. Cleanup below commits it.
                }
                (database, current, retained)
                    if database == journal.original_cwd
                        && current == journal.original_cwd
                        && retained == journal.target_cwd =>
                {
                    // Swift 端 SWAP 中断残留：replacement 落在 retained 位置，
                    // rollout 与数据库都还是原状。丢弃残留即可（下方统一删除）。
                }
                _ => {
                    return Err(format!(
                        "项目移动事务状态无法安全判定：数据库={}，rollout={current_cwd}，保留原件={retained_cwd}；恢复文件保留在 {}",
                        record.cwd,
                        pinned_home
                            .canonical_path()
                            .join(&journal.retained_original_relative_path)
                            .display()
                    ))
                }
            }
            pinned_home.remove_file(retained_relative, || Ok(()))?;
        }
        None => match (record.cwd.as_str(), current_cwd.as_str()) {
            (database, current)
                if database == journal.original_cwd
                    && current == journal.original_cwd => {}
            (database, current)
                if database == journal.original_cwd
                    && current == journal.target_cwd =>
            {
                compare_and_set_thread_cwd(
                    database_path,
                    thread_id,
                    &journal.original_cwd,
                    &journal.target_cwd,
                )?;
            }
            (database, current)
                if database == journal.target_cwd
                    && current == journal.original_cwd =>
            {
                replace_workspace_cwd(
                    pinned_home,
                    rollout_relative,
                    &current_line,
                    thread_id,
                    &journal.target_cwd,
                )?;
            }
            (database, current)
                if database == journal.target_cwd
                    && current == journal.target_cwd => {}
            _ => {
                return Err(format!(
                    "项目移动事务缺少保留原件且状态无法安全判定：数据库={}，rollout={current_cwd}；事务保留在 {}",
                    record.cwd,
                    pinned_home.canonical_path().join(&journal_relative).display()
                ))
            }
        },
    }

    pinned_home.remove_file(&journal_relative, || Ok(()))?;
    Ok(())
}

// 数据库已在目标目录时不能直接早退：rollout 首行可能仍指旧目录（历史漂移），
// 一旦放过，漂移会被永久化，此后任何移动都会被准备阶段的漂移检查锁死且没有
// 产品内出口。这里读首行核对，不一致就按恢复语义原位治愈。
fn finish_noop_move_with_drift_heal(
    pinned_home: &PinnedHome,
    codex_home: &Path,
    record: &ThreadRecord,
    thread_id: &str,
    target: String,
) -> Result<WorkspaceMoveResult, String> {
    if !record.rollout_path.trim().is_empty() {
        let rollout = trusted_rollout_path(codex_home, &record.rollout_path)?;
        let rollout_relative =
            trusted_relative_path(pinned_home.canonical_path(), &rollout)?;
        let current_line = read_first_line(pinned_home, &rollout_relative)?;
        let current_cwd = workspace_metadata_cwd(&current_line, thread_id)?;
        if current_cwd != target {
            replace_workspace_cwd(
                pinned_home,
                &rollout_relative,
                &current_line,
                thread_id,
                &target,
            )?;
            return Ok(WorkspaceMoveResult {
                message: "会话已在目标项目目录；已修复 rollout 项目目录漂移".into(),
                previous_cwd: record.cwd.clone(),
                target_cwd: target,
            });
        }
    }
    Ok(WorkspaceMoveResult {
        message: "会话已在目标项目目录".into(),
        previous_cwd: record.cwd.clone(),
        target_cwd: target,
    })
}

fn recover_after_workspace_move_error(
    pinned_home: &PinnedHome,
    database_path: &Path,
    thread_id: &str,
    context: &str,
    error: String,
) -> Result<WorkspaceMoveResult, String> {
    match recover_interrupted_workspace_move(pinned_home, database_path, thread_id) {
        Ok(()) => Err(format!("{context}，已自动恢复：{error}")),
        Err(recovery_error) => Err(format!(
            "{context}且自动恢复未完成：{error}；{recovery_error}"
        )),
    }
}

fn validate_workspace_move_journal(
    pinned_home: &PinnedHome,
    database_path: &Path,
    thread_id: &str,
    journal: &WorkspaceMoveJournal,
) -> Result<(), String> {
    let expected_database = database_path.canonicalize().map_err(|error| {
        format!(
            "解析 Codex 本地数据库路径失败 {}：{error}",
            database_path.display()
        )
    })?;
    let rollout_relative = Path::new(&journal.rollout_relative_path);
    let expected_retained = rollout_relative
        .parent()
        .ok_or_else(|| "项目移动事务中的 rollout 缺少父目录".to_string())?
        .join(format!(".provider-session-prefix-workspace-{thread_id}"));
    if journal.schema_version != WORKSPACE_MOVE_SCHEMA_VERSION
        || journal.thread_id != thread_id
        || journal.codex_home
            != pinned_home
                .canonical_path()
                .to_string_lossy()
                .as_ref()
        || journal.state_database != expected_database.to_string_lossy().as_ref()
        || Path::new(&journal.retained_original_relative_path) != expected_retained
    {
        return Err(format!(
            "项目移动事务与当前 Codex 数据源不匹配：{}",
            pinned_home
                .canonical_path()
                .join(workspace_move_journal_relative_path(thread_id))
                .display()
        ));
    }
    Ok(())
}

fn compare_and_set_thread_cwd(
    database_path: &Path,
    thread_id: &str,
    original_cwd: &str,
    target_cwd: &str,
) -> Result<(), String> {
    let connection = open_state_database_at(database_path, false)?;
    let changed = connection
        .execute(
            "
            UPDATE threads
            SET cwd = ?1
            WHERE id = ?2
              AND COALESCE(cwd, '') = ?3
            ",
            params![target_cwd, thread_id, original_cwd],
        )
        .map_err(|error| format!("恢复项目移动数据库状态失败：{error}"))?;
    if changed != 1 {
        return Err(format!(
            "恢复项目移动时检测到数据库并发变化：{thread_id}"
        ));
    }
    Ok(())
}

fn open_state_database_at(database: &Path, read_only: bool) -> Result<Connection, String> {
    if !database.is_file() {
        return Err(format!("Codex 本地数据库不可用：{}", database.display()));
    }
    let flags = if read_only {
        OpenFlags::SQLITE_OPEN_READ_ONLY
    } else {
        OpenFlags::SQLITE_OPEN_READ_WRITE
    } | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let connection = Connection::open_with_flags(database, flags)
        .map_err(|error| format!("打开 Codex 本地数据库失败：{error}"))?;
    connection
        .busy_timeout(DATABASE_BUSY_TIMEOUT)
        .map_err(|error| format!("设置 Codex 数据库等待时间失败：{error}"))?;
    Ok(connection)
}

fn read_managed_file_if_present(
    pinned_home: &PinnedHome,
    relative: &Path,
) -> Result<Option<Vec<u8>>, String> {
    let Some(mut file) = pinned_home.open_file(relative)? else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|error| format!("读取项目移动事务文件失败：{error}"))?;
    Ok(Some(bytes))
}

fn read_first_line(pinned_home: &PinnedHome, relative: &Path) -> Result<Vec<u8>, String> {
    let file = pinned_home
        .open_file(relative)?
        .ok_or_else(|| format!("rollout 文件不存在：{}", relative.display()))?;
    let mut line = Vec::new();
    let read = BufReader::new(file)
        .read_until(b'\n', &mut line)
        .map_err(|error| format!("读取 rollout 首行失败：{error}"))?;
    if read == 0 {
        return Err(format!("rollout 文件为空：{}", relative.display()));
    }
    Ok(line)
}

fn first_line_slice(bytes: &[u8]) -> &[u8] {
    match bytes.iter().position(|byte| *byte == b'\n') {
        Some(index) => &bytes[..=index],
        None => bytes,
    }
}

fn workspace_metadata_cwd(line: &[u8], thread_id: &str) -> Result<String, String> {
    let event = parse_workspace_metadata(line, thread_id)?;
    Ok(event
        .pointer("/payload/cwd")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .into())
}

fn parse_workspace_metadata(line: &[u8], thread_id: &str) -> Result<Value, String> {
    let json = line
        .strip_suffix(b"\r\n")
        .or_else(|| line.strip_suffix(b"\n"))
        .unwrap_or(line);
    let event = serde_json::from_slice::<Value>(json)
        .map_err(|error| format!("rollout 首行不是有效 JSON：{error}"))?;
    let is_match = event.get("type").and_then(Value::as_str) == Some("session_meta")
        && event
            .pointer("/payload/id")
            .and_then(Value::as_str)
            == Some(thread_id);
    if !is_match {
        return Err(format!(
            "rollout 首行不是会话 {thread_id} 的规范 session_meta"
        ));
    }
    Ok(event)
}

fn rewrite_workspace_metadata_line(
    line: &[u8],
    thread_id: &str,
    target_cwd: &str,
) -> Result<Vec<u8>, String> {
    let newline = if line.ends_with(b"\r\n") {
        b"\r\n".as_slice()
    } else if line.ends_with(b"\n") {
        b"\n".as_slice()
    } else {
        b"".as_slice()
    };
    let mut event = parse_workspace_metadata(line, thread_id)?;
    let payload = event
        .get_mut("payload")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| "rollout 首行缺少 session_meta payload".to_string())?;
    payload.insert("cwd".into(), Value::String(target_cwd.into()));
    let mut replacement = serde_json::to_vec(&event)
        .map_err(|error| format!("编码 rollout 首行失败：{error}"))?;
    replacement.extend_from_slice(newline);
    Ok(replacement)
}

fn replace_workspace_first_line(
    pinned_home: &PinnedHome,
    rollout_relative: &Path,
    expected_current: &[u8],
    replacement: &[u8],
) -> Result<(), String> {
    let changed = pinned_home.transform_first_line_atomically(
        rollout_relative,
        |current| {
            if current != expected_current {
                return Err(
                    "rollout 首行在项目移动恢复期间发生变化，已拒绝覆盖".into(),
                );
            }
            Ok(Some(replacement.to_vec()))
        },
        |_, _| Ok(()),
    )?;
    if changed {
        Ok(())
    } else {
        Err("项目移动恢复未产生预期的 rollout 更新".into())
    }
}

fn replace_workspace_cwd(
    pinned_home: &PinnedHome,
    rollout_relative: &Path,
    expected_current: &[u8],
    thread_id: &str,
    target_cwd: &str,
) -> Result<(), String> {
    let replacement =
        rewrite_workspace_metadata_line(expected_current, thread_id, target_cwd)?;
    replace_workspace_first_line(
        pinned_home,
        rollout_relative,
        expected_current,
        &replacement,
    )
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
        database: PathBuf,
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
        let mut markdown = String::new();
        let result = export_markdown(
            &fixture.home,
            &fixture.thread_id,
            "备用标题",
            &mut |fragment| {
                markdown.push_str(fragment);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(
            result.filename,
            format!("真实会话-{}.md", fixture.thread_id)
        );
        assert!(markdown.starts_with("# 真实会话\n\n"));
        assert!(markdown.contains("### User"));
        assert!(markdown.contains("你好，Codex"));
        assert!(markdown.contains("### Assistant"));
        assert!(markdown.contains("已经完成"));
        assert!(markdown.contains("2026-07-20 12:01:00"));
        // 与 Swift streamMarkdown 对齐：消息之间以空行分隔，文末保留单个换行。
        assert!(markdown.contains("\n\n### Assistant"));
        assert!(markdown.ends_with('\n'));
        assert!(!markdown.ends_with("\n\n"));
    }

    #[test]
    fn markdown_export_stops_at_first_emit_failure() {
        let fixture = fixture();
        let mut calls = 0usize;
        let error = export_markdown(
            &fixture.home,
            &fixture.thread_id,
            "备用标题",
            &mut |_fragment| {
                calls += 1;
                if calls >= 2 {
                    Err("写入失败".into())
                } else {
                    Ok(())
                }
            },
        )
        .unwrap_err();
        assert!(error.contains("写入失败"));
        assert_eq!(calls, 2);
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
        let connection = Connection::open(&fixture.database).unwrap();
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
        let connection = Connection::open(&fixture.database).unwrap();
        let cwd: String = connection
            .query_row(
                "SELECT cwd FROM threads WHERE id = ?1",
                params![fixture.thread_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(PathBuf::from(cwd), fixture.original_cwd);
    }

    #[test]
    fn workspace_move_lease_blocks_overlap_and_releases() {
        let fixture = fixture();
        let pinned_home = PinnedHome::open(&fixture.home).unwrap();
        let first = WorkspaceMoveLease::acquire(&pinned_home, &fixture.thread_id).unwrap();
        let error =
            WorkspaceMoveLease::acquire(&pinned_home, &fixture.thread_id)
                .err()
                .unwrap();
        assert!(error.contains("正在进行"));
        drop(first);
        WorkspaceMoveLease::acquire(&pinned_home, &fixture.thread_id).unwrap();
    }

    #[test]
    fn workspace_move_lock_path_matches_swift_contract() {
        assert_eq!(
            workspace_move_lock_relative_path("thread-1"),
            PathBuf::from(
                "backups_state/codex-token-bar/workspace-move/thread-1.lock"
            )
        );
    }

    #[test]
    fn persisted_windows_paths_drop_only_extended_namespace_prefixes() {
        assert_eq!(
            strip_windows_extended_prefix(r"\\?\C:\Users\Codex Project"),
            r"C:\Users\Codex Project"
        );
        assert_eq!(
            strip_windows_extended_prefix(r"\\?\UNC\server\share\Codex"),
            r"\\server\share\Codex"
        );
        assert_eq!(
            strip_windows_extended_prefix(r"C:\Users\Codex Project"),
            r"C:\Users\Codex Project"
        );
    }

    #[test]
    fn session_enhancements_respect_configured_sqlite_home() {
        let fixture = fixture_with_separate_sqlite_home(true);
        assert!(!fixture.home.join("state_5.sqlite").exists());
        let target = fixture.home.join("Separate SQLite Target");
        std::fs::create_dir_all(&target).unwrap();

        let mut exported_markdown = String::new();
        export_markdown(&fixture.home, &fixture.thread_id, "备用标题", &mut |fragment| {
            exported_markdown.push_str(fragment);
            Ok(())
        })
        .unwrap();
        assert!(exported_markdown.contains("你好，Codex"));
        move_thread_workspace(
            &fixture.home,
            &fixture.thread_id,
            target.to_string_lossy().as_ref(),
        )
        .unwrap();

        let connection = Connection::open(&fixture.database).unwrap();
        let cwd: String = connection
            .query_row(
                "SELECT cwd FROM threads WHERE id = ?1",
                params![fixture.thread_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(PathBuf::from(cwd), target.canonicalize().unwrap());
    }

    #[test]
    fn project_move_changes_only_canonical_first_session_meta() {
        let fixture = fixture();
        let embedded = format!(
            "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{}\",\"cwd\":\"embedded-fork\"}}}}\n",
            fixture.thread_id
        );
        let mut file = OpenOptions::new()
            .append(true)
            .open(&fixture.rollout)
            .unwrap();
        file.write_all(embedded.as_bytes()).unwrap();
        file.sync_all().unwrap();
        let before = std::fs::read(&fixture.rollout).unwrap();
        let before_tail = before
            .splitn(2, |byte| *byte == b'\n')
            .nth(1)
            .unwrap()
            .to_vec();
        let target = fixture.home.join("Canonical Only Target");
        std::fs::create_dir_all(&target).unwrap();

        move_thread_workspace(
            &fixture.home,
            &fixture.thread_id,
            target.to_string_lossy().as_ref(),
        )
        .unwrap();

        let after = std::fs::read(&fixture.rollout).unwrap();
        let after_tail = after
            .splitn(2, |byte| *byte == b'\n')
            .nth(1)
            .unwrap();
        assert_eq!(after_tail, before_tail);
        assert!(std::str::from_utf8(after_tail)
            .unwrap()
            .contains("\"cwd\":\"embedded-fork\""));
    }

    #[test]
    fn recovery_rolls_back_rollout_when_database_was_not_committed() {
        let fixture = fixture();
        let target = fixture.home.join("Recovery Rollback Target");
        std::fs::create_dir_all(&target).unwrap();
        let target = target.canonicalize().unwrap().to_string_lossy().into_owned();
        let (pinned, journal) = prepared_workspace_move(&fixture, &target);

        recover_interrupted_workspace_move(
            &pinned,
            &fixture.database,
            &fixture.thread_id,
        )
        .unwrap();

        assert_eq!(
            rollout_cwd(&fixture.rollout, &fixture.thread_id),
            fixture.original_cwd.to_string_lossy()
        );
        assert_eq!(
            database_cwd(&fixture.database, &fixture.thread_id),
            fixture.original_cwd.to_string_lossy()
        );
        assert_workspace_move_artifacts_removed(&fixture, &journal);
    }

    #[test]
    fn recovery_commits_rollout_when_database_was_already_advanced() {
        let fixture = fixture();
        let target = fixture.home.join("Recovery Commit Target");
        std::fs::create_dir_all(&target).unwrap();
        let target = target.canonicalize().unwrap().to_string_lossy().into_owned();
        let (pinned, journal) = prepared_workspace_move(&fixture, &target);
        compare_and_set_thread_cwd(
            &fixture.database,
            &fixture.thread_id,
            fixture.original_cwd.to_string_lossy().as_ref(),
            &target,
        )
        .unwrap();

        recover_interrupted_workspace_move(
            &pinned,
            &fixture.database,
            &fixture.thread_id,
        )
        .unwrap();

        assert_eq!(rollout_cwd(&fixture.rollout, &fixture.thread_id), target);
        assert_eq!(database_cwd(&fixture.database, &fixture.thread_id), target);
        assert_workspace_move_artifacts_removed(&fixture, &journal);
    }

    #[test]
    fn recovery_fails_closed_on_concurrent_database_change() {
        let fixture = fixture();
        let target = fixture.home.join("Recovery Conflict Target");
        let concurrent = fixture.home.join("Concurrent Target");
        std::fs::create_dir_all(&target).unwrap();
        std::fs::create_dir_all(&concurrent).unwrap();
        let target = target.canonicalize().unwrap().to_string_lossy().into_owned();
        let concurrent = concurrent
            .canonicalize()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let (pinned, journal) = prepared_workspace_move(&fixture, &target);
        Connection::open(&fixture.database)
            .unwrap()
            .execute(
                "UPDATE threads SET cwd = ?1 WHERE id = ?2",
                params![concurrent, fixture.thread_id],
            )
            .unwrap();

        let error = recover_interrupted_workspace_move(
            &pinned,
            &fixture.database,
            &fixture.thread_id,
        )
        .unwrap_err();

        assert!(error.contains("无法安全判定"));
        assert!(fixture
            .home
            .join(workspace_move_journal_relative_path(&fixture.thread_id))
            .exists());
        assert!(fixture
            .home
            .join(&journal.retained_original_relative_path)
            .exists());
    }

    #[test]
    fn large_rollout_move_keeps_tail_and_never_creates_full_backup() {
        let fixture = fixture();
        let tail_chunk = vec![b'x'; 1024 * 1024];
        let mut file = OpenOptions::new()
            .append(true)
            .open(&fixture.rollout)
            .unwrap();
        for _ in 0..8 {
            file.write_all(&tail_chunk).unwrap();
        }
        file.sync_all().unwrap();
        let before_size = file.metadata().unwrap().len();
        drop(file);
        let target = fixture.home.join("Large Rollout Target");
        std::fs::create_dir_all(&target).unwrap();

        move_thread_workspace(
            &fixture.home,
            &fixture.thread_id,
            target.to_string_lossy().as_ref(),
        )
        .unwrap();

        let after_size = std::fs::metadata(&fixture.rollout).unwrap().len();
        assert!(after_size.abs_diff(before_size) < 4096);
        assert!(std::fs::read_dir(fixture.rollout.parent().unwrap())
            .unwrap()
            .all(|entry| !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains("move-backup")));
    }

    #[test]
    fn workspace_move_rejects_v1_journal_with_explicit_diagnostic() {
        let fixture = fixture();
        let target = fixture.home.join("V1 Target");
        std::fs::create_dir_all(&target).unwrap();
        let journal_path = fixture
            .home
            .join(workspace_move_journal_relative_path(&fixture.thread_id));
        std::fs::create_dir_all(journal_path.parent().unwrap()).unwrap();
        // v1 时期 Swift 端产出的形状（threadID / retainedOriginalName 键）。
        std::fs::write(
            &journal_path,
            format!(
                "{{\"schemaVersion\":1,\"codexHome\":{home:?},\"stateDatabase\":{db:?},\
                 \"threadID\":\"{id}\",\"rolloutRelativePath\":\"sessions/x.jsonl\",\
                 \"retainedOriginalName\":\".provider-session-prefix-workspace-{id}\",\
                 \"originalCwd\":\"/a\",\"targetCwd\":\"/b\"}}",
                home = fixture.home.to_string_lossy(),
                db = fixture.database.to_string_lossy(),
                id = fixture.thread_id,
            ),
        )
        .unwrap();

        let error = move_thread_workspace(
            &fixture.home,
            &fixture.thread_id,
            target.to_string_lossy().as_ref(),
        )
        .unwrap_err();
        assert!(error.contains("schemaVersion=1"), "{error}");
        assert!(error.contains("人工核对"), "{error}");
        assert!(journal_path.exists(), "拒绝时必须保留 journal 供人工处理");
    }

    #[test]
    fn noop_move_heals_rollout_cwd_drift() {
        let fixture = fixture();
        let target = fixture.home.join("Drift Target");
        std::fs::create_dir_all(&target).unwrap();
        let canonical_target = target
            .canonicalize()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        // 模拟历史漂移：数据库已在目标目录，rollout 首行仍指原目录。
        Connection::open(&fixture.database)
            .unwrap()
            .execute(
                "UPDATE threads SET cwd = ?1 WHERE id = ?2",
                params![canonical_target, fixture.thread_id],
            )
            .unwrap();

        let result = move_thread_workspace(
            &fixture.home,
            &fixture.thread_id,
            target.to_string_lossy().as_ref(),
        )
        .unwrap();
        assert!(
            result.message.contains("已修复 rollout 项目目录漂移"),
            "{}",
            result.message
        );
        assert_eq!(
            rollout_cwd(&fixture.rollout, &fixture.thread_id),
            canonical_target
        );

        let result = move_thread_workspace(
            &fixture.home,
            &fixture.thread_id,
            target.to_string_lossy().as_ref(),
        )
        .unwrap();
        assert_eq!(result.message, "会话已在目标项目目录");
    }

    #[test]
    fn recovery_restores_first_line_from_whole_file_retained_and_keeps_tail() {
        // Swift 端 prepared 状态：retained 是整文件副本，rollout 首行已改目标，
        // 数据库未提交。恢复必须只还原首行，保留 rollout 其余内容与追加事件。
        let fixture = fixture();
        let target = fixture.home.join("Swift Prepared Target");
        std::fs::create_dir_all(&target).unwrap();
        let canonical_target = target
            .canonicalize()
            .unwrap()
            .to_string_lossy()
            .into_owned();

        let retained = fixture.rollout.parent().unwrap().join(format!(
            ".provider-session-prefix-workspace-{}",
            fixture.thread_id
        ));
        std::fs::copy(&fixture.rollout, &retained).unwrap();
        let contents = std::fs::read_to_string(&fixture.rollout).unwrap();
        let mut lines: Vec<String> = contents.lines().map(str::to_owned).collect();
        let mut event: Value = serde_json::from_str(&lines[0]).unwrap();
        event["payload"]["cwd"] = Value::String(canonical_target.clone());
        lines[0] = serde_json::to_string(&event).unwrap();
        lines.push("{\"type\":\"event_msg\",\"payload\":{\"appended\":true}}".into());
        std::fs::write(&fixture.rollout, lines.join("\n") + "\n").unwrap();

        let pinned = PinnedHome::open(&fixture.home).unwrap();
        pinned
            .ensure_parent_directories(&workspace_move_journal_relative_path(
                &fixture.thread_id,
            ))
            .unwrap();
        let relative = trusted_relative_path(
            pinned.canonical_path(),
            &fixture.rollout.canonicalize().unwrap(),
        )
        .unwrap();
        let journal = WorkspaceMoveJournal::new(
            &pinned,
            &fixture.database,
            &fixture.thread_id,
            &relative,
            fixture.original_cwd.to_string_lossy().as_ref(),
            &canonical_target,
        )
        .unwrap();
        std::fs::write(
            fixture
                .home
                .join(workspace_move_journal_relative_path(&fixture.thread_id)),
            serde_json::to_vec(&journal).unwrap(),
        )
        .unwrap();
        drop(pinned);

        move_thread_workspace(
            &fixture.home,
            &fixture.thread_id,
            target.to_string_lossy().as_ref(),
        )
        .unwrap();

        assert_eq!(
            database_cwd(&fixture.database, &fixture.thread_id),
            canonical_target
        );
        assert_eq!(
            rollout_cwd(&fixture.rollout, &fixture.thread_id),
            canonical_target
        );
        let after = std::fs::read_to_string(&fixture.rollout).unwrap();
        assert!(after.contains("\"appended\":true"), "追加事件必须保留：{after}");
        assert!(after.contains("你好，Codex"), "既有事件必须保留：{after}");
        assert!(!retained.exists());
        assert_workspace_move_artifacts_removed(&fixture, &journal);
    }

    #[test]
    fn recovery_discards_swapped_retained_when_nothing_committed() {
        // Swift 端 SWAP 中断残留：retained 首行指向目标目录，rollout 与数据库
        // 都还是原状。恢复应丢弃残留并允许移动继续完成。
        let fixture = fixture();
        let target = fixture.home.join("Swap Remnant Target");
        std::fs::create_dir_all(&target).unwrap();
        let canonical_target = target
            .canonicalize()
            .unwrap()
            .to_string_lossy()
            .into_owned();

        let retained = fixture.rollout.parent().unwrap().join(format!(
            ".provider-session-prefix-workspace-{}",
            fixture.thread_id
        ));
        let contents = std::fs::read_to_string(&fixture.rollout).unwrap();
        let mut lines: Vec<String> = contents.lines().map(str::to_owned).collect();
        let mut event: Value = serde_json::from_str(&lines[0]).unwrap();
        event["payload"]["cwd"] = Value::String(canonical_target.clone());
        lines[0] = serde_json::to_string(&event).unwrap();
        std::fs::write(&retained, lines.join("\n") + "\n").unwrap();

        let pinned = PinnedHome::open(&fixture.home).unwrap();
        pinned
            .ensure_parent_directories(&workspace_move_journal_relative_path(
                &fixture.thread_id,
            ))
            .unwrap();
        let relative = trusted_relative_path(
            pinned.canonical_path(),
            &fixture.rollout.canonicalize().unwrap(),
        )
        .unwrap();
        let journal = WorkspaceMoveJournal::new(
            &pinned,
            &fixture.database,
            &fixture.thread_id,
            &relative,
            fixture.original_cwd.to_string_lossy().as_ref(),
            &canonical_target,
        )
        .unwrap();
        std::fs::write(
            fixture
                .home
                .join(workspace_move_journal_relative_path(&fixture.thread_id)),
            serde_json::to_vec(&journal).unwrap(),
        )
        .unwrap();
        drop(pinned);

        move_thread_workspace(
            &fixture.home,
            &fixture.thread_id,
            target.to_string_lossy().as_ref(),
        )
        .unwrap();

        assert_eq!(
            database_cwd(&fixture.database, &fixture.thread_id),
            canonical_target
        );
        assert_eq!(
            rollout_cwd(&fixture.rollout, &fixture.thread_id),
            canonical_target
        );
        assert_workspace_move_artifacts_removed(&fixture, &journal);
    }

    fn prepared_workspace_move(
        fixture: &Fixture,
        target: &str,
    ) -> (PinnedHome, WorkspaceMoveJournal) {
        let pinned = PinnedHome::open(&fixture.home).unwrap();
        pinned
            .ensure_parent_directories(&workspace_move_journal_relative_path(
                &fixture.thread_id,
            ))
            .unwrap();
        let relative = trusted_relative_path(
            pinned.canonical_path(),
            &fixture.rollout.canonicalize().unwrap(),
        )
        .unwrap();
        let journal = WorkspaceMoveJournal::new(
            &pinned,
            &fixture.database,
            &fixture.thread_id,
            &relative,
            fixture.original_cwd.to_string_lossy().as_ref(),
            target,
        )
        .unwrap();
        prepare_workspace_rollout_move(&pinned, &journal).unwrap();
        (pinned, journal)
    }

    fn database_cwd(database: &Path, thread_id: &str) -> String {
        Connection::open(database)
            .unwrap()
            .query_row(
                "SELECT cwd FROM threads WHERE id = ?1",
                params![thread_id],
                |row| row.get(0),
            )
            .unwrap()
    }

    fn rollout_cwd(rollout: &Path, thread_id: &str) -> String {
        let first = std::fs::read(rollout)
            .unwrap()
            .splitn(2, |byte| *byte == b'\n')
            .next()
            .unwrap()
            .to_vec();
        workspace_metadata_cwd(&first, thread_id).unwrap()
    }

    fn assert_workspace_move_artifacts_removed(
        fixture: &Fixture,
        journal: &WorkspaceMoveJournal,
    ) {
        assert!(!fixture
            .home
            .join(workspace_move_journal_relative_path(&fixture.thread_id))
            .exists());
        assert!(!fixture
            .home
            .join(&journal.retained_original_relative_path)
            .exists());
    }

    fn fixture() -> Fixture {
        fixture_with_separate_sqlite_home(false)
    }

    fn fixture_with_separate_sqlite_home(separate_sqlite_home: bool) -> Fixture {
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
        let sqlite_home = if separate_sqlite_home {
            let sqlite_home = home.join("sqlite-state");
            std::fs::create_dir_all(&sqlite_home).unwrap();
            let mut config = toml::Table::new();
            config.insert(
                "sqlite_home".into(),
                toml::Value::String(sqlite_home.to_string_lossy().into_owned()),
            );
            std::fs::write(
                home.join("config.toml"),
                toml::to_string(&config).unwrap(),
            )
            .unwrap();
            sqlite_home
        } else {
            home.clone()
        };
        let database = sqlite_home.join("state_5.sqlite");
        let connection = Connection::open(&database).unwrap();
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
            database,
            rollout,
            thread_id,
            original_cwd,
        }
    }
}
