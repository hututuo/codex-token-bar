use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use super::safe_fs::{AtomicInstallPhase, PinnedHome};

const MAX_SESSION_TRAVERSAL_DEPTH: usize = 64;
const MAX_SESSION_TRAVERSAL_ENTRIES: usize = 200_000;
const ATOMIC_TEMP_ATTEMPTS: usize = 64;
static ATOMIC_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SessionRewritePhase {
    BeforeTempCreate,
    BeforeReplace,
}

pub(super) struct SessionScan {
    pub(super) files_found: u32,
    pub(super) provider_counts: HashMap<String, u32>,
    pub(super) invalid_files: u32,
    pub(super) newest_provider: Option<String>,
}

impl SessionScan {
    pub(super) fn count_provider_mismatches(&self, target_provider: &str) -> u32 {
        self.provider_counts
            .iter()
            .filter(|(provider, _)| provider.as_str() != target_provider)
            .map(|(_, count)| *count)
            .sum()
    }
}

pub(super) fn find_session_files(
    codex_home: &Path,
    include_archived: bool,
) -> Result<Vec<PathBuf>, String> {
    let canonical_home = codex_home
        .canonicalize()
        .map_err(|error| format!("无法确认 Codex Home {}：{error}", codex_home.display()))?;
    let mut roots = vec![codex_home.join("sessions")];
    if include_archived {
        roots.push(codex_home.join("archived_sessions"));
    }
    let mut files = Vec::new();
    let mut visited = HashSet::new();
    let mut entries_seen = 0_usize;
    for root in roots {
        collect_jsonl_files(
            &canonical_home,
            &root,
            &mut files,
            &mut visited,
            &mut entries_seen,
            0,
        )?;
    }
    files.sort();
    Ok(files)
}

pub(super) fn collect_jsonl_files(
    canonical_root: &Path,
    path: &Path,
    files: &mut Vec<PathBuf>,
    visited: &mut HashSet<PathBuf>,
    entries_seen: &mut usize,
    depth: usize,
) -> Result<(), String> {
    if depth > MAX_SESSION_TRAVERSAL_DEPTH {
        return Err(format!("会话目录遍历超过最大深度：{}", path.display()));
    }
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("读取会话路径失败 {}：{error}", path.display())),
    };
    if metadata.file_type().is_symlink() {
        return Ok(());
    }

    let canonical_path = path
        .canonicalize()
        .map_err(|error| format!("无法确认会话路径 {}：{error}", path.display()))?;
    if !canonical_path.starts_with(canonical_root) {
        return Ok(());
    }
    if metadata.is_file() {
        if canonical_path
            .extension()
            .is_some_and(|extension| extension == "jsonl")
        {
            files.push(canonical_path);
        }
        return Ok(());
    }
    if !metadata.is_dir() || !visited.insert(canonical_path) {
        return Ok(());
    }

    let entries = fs::read_dir(path)
        .map_err(|error| format!("读取会话目录失败 {}：{error}", path.display()))?;
    for entry in entries {
        let entry = entry.map_err(|error| format!("读取会话目录项失败：{error}"))?;
        *entries_seen = entries_seen.saturating_add(1);
        if *entries_seen > MAX_SESSION_TRAVERSAL_ENTRIES {
            return Err(format!(
                "会话目录遍历超过最大条目数 {MAX_SESSION_TRAVERSAL_ENTRIES}"
            ));
        }
        collect_jsonl_files(
            canonical_root,
            &entry.path(),
            files,
            visited,
            entries_seen,
            depth + 1,
        )?;
    }
    Ok(())
}

pub(super) fn scan_session_providers(files: &[PathBuf]) -> SessionScan {
    let mut provider_counts = HashMap::<String, u32>::new();
    let mut invalid_files = 0;
    let mut newest_provider = None;
    let mut newest_modified = None;

    for file in files {
        match read_session_provider(file) {
            Ok(Some(provider)) => {
                *provider_counts.entry(provider.clone()).or_insert(0) += 1;
                let modified = fs::metadata(file)
                    .and_then(|metadata| metadata.modified())
                    .ok();
                if newest_modified.is_none_or(|current| modified.is_some_and(|next| next > current))
                {
                    newest_modified = modified;
                    newest_provider = Some(provider);
                }
            }
            Ok(None) | Err(_) => invalid_files += 1,
        }
    }

    SessionScan {
        files_found: u32::try_from(files.len()).unwrap_or(u32::MAX),
        provider_counts,
        invalid_files,
        newest_provider,
    }
}

#[cfg(test)]
pub(super) fn rewrite_session_provider(
    canonical_home: &Path,
    file: &Path,
    target_provider: &str,
) -> Result<bool, String> {
    let pinned_home = PinnedHome::open(canonical_home)?;
    rewrite_session_provider_in(&pinned_home, file, target_provider, |_, _| Ok(()))
}

#[cfg(test)]
pub(super) fn rewrite_session_provider_with_hook(
    canonical_home: &Path,
    file: &Path,
    target_provider: &str,
    hook: impl FnMut(SessionRewritePhase, &Path) -> Result<(), String>,
) -> Result<bool, String> {
    let pinned_home = PinnedHome::open(canonical_home)?;
    rewrite_session_provider_in(&pinned_home, file, target_provider, hook)
}

pub(super) fn rewrite_session_provider_in(
    pinned_home: &PinnedHome,
    file: &Path,
    target_provider: &str,
    hook: impl FnMut(SessionRewritePhase, &Path) -> Result<(), String>,
) -> Result<bool, String> {
    let canonical_file = file.canonicalize().map_err(|error| error.to_string())?;
    let relative = canonical_file
        .strip_prefix(pinned_home.canonical_path())
        .map_err(|_| {
            format!(
                "拒绝改写 Codex Home 外的会话文件：{}",
                canonical_file.display()
            )
        })?;
    rewrite_session_provider_relative_in(pinned_home, relative, target_provider, hook)
}

pub(super) fn rewrite_session_provider_relative_in(
    pinned_home: &PinnedHome,
    relative: &Path,
    target_provider: &str,
    mut hook: impl FnMut(SessionRewritePhase, &Path) -> Result<(), String>,
) -> Result<bool, String> {
    let display_path = pinned_home.canonical_path().join(relative);
    pinned_home.transform_file_atomically(
        relative,
        |bytes| {
            let text = String::from_utf8(bytes).map_err(|error| {
                format!("会话文件不是有效 UTF-8 {}：{error}", display_path.display())
            })?;
            let (first_line, rest) = match text.find('\n') {
                Some(index) => (&text[..index], &text[index..]),
                None => (text.as_str(), ""),
            };
            let mut value: Value = serde_json::from_str(first_line.trim_end())
                .map_err(|error| format!("{}: {error}", display_path.display()))?;
            if value.get("type").and_then(Value::as_str) != Some("session_meta") {
                return Ok(None);
            }
            let payload = value
                .get_mut("payload")
                .and_then(Value::as_object_mut)
                .ok_or_else(|| format!("{} 缺少 session_meta.payload", display_path.display()))?;
            if payload.get("model_provider").and_then(Value::as_str) == Some(target_provider) {
                return Ok(None);
            }
            payload.insert(
                "model_provider".into(),
                Value::String(target_provider.into()),
            );
            let first_line = serde_json::to_string(&value).map_err(|error| error.to_string())?;
            Ok(Some(format!("{first_line}{rest}").into_bytes()))
        },
        |phase, path| match phase {
            AtomicInstallPhase::BeforeTempCreate => {
                hook(SessionRewritePhase::BeforeTempCreate, path)
            }
            AtomicInstallPhase::BeforeReplace => hook(SessionRewritePhase::BeforeReplace, path),
            _ => Ok(()),
        },
    )
}

fn read_session_provider(file: &Path) -> Result<Option<String>, String> {
    let file = fs::File::open(file).map_err(|error| error.to_string())?;
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let read = reader
        .read_line(&mut line)
        .map_err(|error| error.to_string())?;
    if read == 0 {
        return Ok(None);
    }

    let value: Value = serde_json::from_str(line.trim_end()).map_err(|error| error.to_string())?;
    if value.get("type").and_then(Value::as_str) != Some("session_meta") {
        return Ok(None);
    }
    let provider = value
        .get("payload")
        .and_then(|payload| payload.get("model_provider"))
        .and_then(Value::as_str)
        .unwrap_or("(missing)")
        .to_string();
    Ok(Some(provider))
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("目标文件缺少父目录：{}", path.display()))?;
    let parent_metadata = fs::symlink_metadata(parent).map_err(|error| error.to_string())?;
    if parent_metadata.file_type().is_symlink() || !parent_metadata.is_dir() {
        return Err(format!("目标父路径不是普通目录：{}", parent.display()));
    }
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("目标文件名无效：{}", path.display()))?;

    for _ in 0..ATOMIC_TEMP_ATTEMPTS {
        let sequence = ATOMIC_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp = parent.join(format!(
            ".{file_name}.codex-token-bar-{}-{sequence:020}.tmp",
            std::process::id()
        ));
        let mut file = match OpenOptions::new().write(true).create_new(true).open(&temp) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.to_string()),
        };
        let write_result = file
            .write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|error| error.to_string());
        drop(file);
        if let Err(error) = write_result {
            let _ = fs::remove_file(&temp);
            return Err(error);
        }
        if let Err(error) = replace_file_atomically(&temp, path) {
            let _ = fs::remove_file(&temp);
            return Err(error);
        }
        return Ok(());
    }

    Err(format!("无法为 {} 创建唯一临时文件", path.display()))
}

pub(super) fn replace_file_atomically(source: &Path, destination: &Path) -> Result<(), String> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{ReplaceFileW, REPLACEFILE_WRITE_THROUGH};

        if destination.exists() {
            let replaced = destination
                .as_os_str()
                .encode_wide()
                .chain(std::iter::once(0))
                .collect::<Vec<_>>();
            let replacement = source
                .as_os_str()
                .encode_wide()
                .chain(std::iter::once(0))
                .collect::<Vec<_>>();
            // SAFETY: both UTF-16 buffers are NUL-terminated and live for the call;
            // the optional backup/exclusion pointers are intentionally null.
            let replaced_ok = unsafe {
                ReplaceFileW(
                    replaced.as_ptr(),
                    replacement.as_ptr(),
                    std::ptr::null(),
                    REPLACEFILE_WRITE_THROUGH,
                    std::ptr::null(),
                    std::ptr::null(),
                )
            };
            if replaced_ok == 0 {
                return Err(std::io::Error::last_os_error().to_string());
            }
            return Ok(());
        }
    }

    fs::rename(source, destination).map_err(|error| error.to_string())
}

pub(super) fn write_file_atomically(path: &Path, bytes: &[u8]) -> Result<(), String> {
    write_atomic(path, bytes)
}
