use serde_json::Value;
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};

pub(super) fn jsonl_files(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect_jsonl_files(root, &mut files);
    files
}

fn collect_jsonl_files(root: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_jsonl_files(&path, files);
        } else if path.extension().is_some_and(|extension| extension == "jsonl") {
            files.push(path);
        }
    }
}

pub(super) fn session_meta_payload(file: &Path) -> Option<Value> {
    let line = first_line(file)?;
    let object: Value = serde_json::from_str(&line).ok()?;
    if object.get("type")?.as_str()? != "session_meta" {
        return None;
    }
    object.get("payload").cloned()
}

fn first_line(file: &Path) -> Option<String> {
    let handle = fs::File::open(file).ok()?;
    let mut reader = BufReader::new(handle.take(262_144));
    let mut line = String::new();
    let bytes = reader.read_line(&mut line).ok()?;
    if bytes == 0 {
        None
    } else {
        Some(line.trim_end_matches(['\r', '\n']).to_string())
    }
}

pub(super) fn contains_subagent_text(value: &str) -> bool {
    value.to_ascii_lowercase().contains("subagent")
}

pub(super) fn value_contains_subagent(value: Option<&Value>) -> bool {
    match value {
        Some(Value::String(text)) => contains_subagent_text(text),
        Some(Value::Array(items)) => items.iter().any(|item| value_contains_subagent(Some(item))),
        Some(Value::Object(map)) => {
            map.keys().any(|key| contains_subagent_text(key))
                || map.values().any(|item| value_contains_subagent(Some(item)))
        }
        _ => false,
    }
}
