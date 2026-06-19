use crate::models::LocalDataWarning;
use std::fs;
use std::path::{Path, PathBuf};

pub(super) fn jsonl_files(root: &Path, warnings: &mut Vec<LocalDataWarning>) -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect_jsonl_files(root, &mut files, warnings);
    files
}

fn collect_jsonl_files(root: &Path, files: &mut Vec<PathBuf>, warnings: &mut Vec<LocalDataWarning>) {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) => {
            warnings.push(jsonl_scan_warning(format!(
                "读取会话目录失败：{}（{}）",
                root.display(),
                error
            )));
            return;
        }
    };

    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                warnings.push(jsonl_scan_warning(format!(
                    "读取会话目录项失败：{}（{}）",
                    root.display(),
                    error
                )));
                continue;
            }
        };
        let path = entry.path();
        if path.is_dir() {
            collect_jsonl_files(&path, files, warnings);
        } else if path.extension().is_some_and(|extension| extension == "jsonl") {
            files.push(path);
        }
    }
}

pub(super) fn session_id_from_file(file: &Path) -> String {
    let stem = file
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    let parts: Vec<&str> = stem.split('-').collect();
    let start = parts.len().saturating_sub(5);
    parts[start..].join("-")
}

fn jsonl_scan_warning(message: String) -> LocalDataWarning {
    LocalDataWarning {
        source: "jsonl_scan".into(),
        message,
    }
}
