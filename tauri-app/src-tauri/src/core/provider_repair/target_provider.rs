use super::session_files::SessionScan;
use super::sqlite_state::SQLiteScan;
use super::validated_provider_candidate;
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
    if let Some(provider) = sqlite_scan
        .latest_unarchived_provider
        .as_deref()
        .and_then(validated_provider_candidate)
    {
        return TargetProvider {
            provider,
            source: "SQLite 最新会话".into(),
        };
    }
    if let Some(provider) = session_scan
        .newest_provider
        .as_deref()
        .and_then(validated_provider_candidate)
    {
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
    let config = toml::from_str::<toml::Table>(&text).ok()?;
    config
        .get("model_provider")
        .and_then(toml::Value::as_str)
        .and_then(validated_provider_candidate)
}
