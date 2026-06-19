use super::session_files::SessionScan;
use super::sqlite_state::SQLiteScan;
use std::fs;
use std::path::Path;

pub(super) struct TargetProvider {
    pub(super) provider: String,
    pub(super) source: String,
}

pub(super) fn detect_target_provider(
    codex_home: &Path,
    sqlite_scan: &SQLiteScan,
    session_scan: &SessionScan,
) -> TargetProvider {
    if let Some(provider) = config_provider(codex_home) {
        return TargetProvider {
            provider,
            source: "config.toml".into(),
        };
    }
    if let Some(provider) = sqlite_scan.latest_unarchived_provider.clone() {
        return TargetProvider {
            provider,
            source: "SQLite 最新会话".into(),
        };
    }
    if let Some(provider) = session_scan.newest_provider.clone() {
        return TargetProvider {
            provider,
            source: "最新 JSONL".into(),
        };
    }
    TargetProvider {
        provider: "openai".into(),
        source: "默认 openai".into(),
    }
}

fn config_provider(codex_home: &Path) -> Option<String> {
    let text = fs::read_to_string(codex_home.join("config.toml")).ok()?;
    for raw_line in text.lines() {
        let line = raw_line.split('#').next().unwrap_or("").trim();
        let Some(value) = line.strip_prefix("model_provider") else {
            continue;
        };
        let Some((_, assigned)) = value.split_once('=') else {
            continue;
        };
        let trimmed = assigned.trim();
        let provider = trimmed
            .strip_prefix('"')
            .and_then(|value| value.split('"').next())
            .map(str::trim)
            .filter(|value| !value.is_empty());
        if let Some(provider) = provider {
            return Some(provider.to_string());
        }
    }
    None
}
