use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

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

pub(super) fn find_session_files(codex_home: &Path, include_archived: bool) -> Vec<PathBuf> {
    let mut roots = vec![codex_home.join("sessions")];
    if include_archived {
        roots.push(codex_home.join("archived_sessions"));
    }
    let mut files = Vec::new();
    for root in roots {
        collect_jsonl_files(&root, &mut files);
    }
    files.sort();
    files
}

pub(super) fn collect_jsonl_files(root: &Path, files: &mut Vec<PathBuf>) {
    let Ok(metadata) = fs::metadata(root) else {
        return;
    };
    if metadata.is_file() {
        if root.extension().is_some_and(|extension| extension == "jsonl") {
            files.push(root.to_path_buf());
        }
        return;
    }

    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        collect_jsonl_files(&entry.path(), files);
    }
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
                let modified = fs::metadata(file).and_then(|metadata| metadata.modified()).ok();
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

pub(super) fn rewrite_session_provider(
    file: &Path,
    target_provider: &str,
) -> Result<bool, String> {
    let text = fs::read_to_string(file).map_err(|error| error.to_string())?;
    let (first_line, rest) = match text.find('\n') {
        Some(index) => (&text[..index], &text[index..]),
        None => (text.as_str(), ""),
    };
    let mut value: Value = serde_json::from_str(first_line.trim_end())
        .map_err(|error| format!("{}: {error}", file.display()))?;
    if value.get("type").and_then(Value::as_str) != Some("session_meta") {
        return Ok(false);
    }
    let payload = value
        .get_mut("payload")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| format!("{} 缺少 session_meta.payload", file.display()))?;
    if payload.get("model_provider").and_then(Value::as_str) == Some(target_provider) {
        return Ok(false);
    }
    payload.insert("model_provider".into(), Value::String(target_provider.into()));
    let first_line = serde_json::to_string(&value).map_err(|error| error.to_string())?;
    write_atomic(file, format!("{first_line}{rest}").as_bytes())?;
    Ok(true)
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
    let temp = path.with_extension("tmp-codex-token-bar");
    fs::write(&temp, bytes).map_err(|error| error.to_string())?;
    fs::rename(&temp, path).map_err(|error| error.to_string())
}
