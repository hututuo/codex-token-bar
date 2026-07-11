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
    let config = fs::read(codex_home.join("config.toml")).ok();
    detect_target_provider_from_config(config.as_deref(), sqlite_scan, session_scan)
}

pub(super) fn detect_target_provider_from_config(
    config: Option<&[u8]>,
    sqlite_scan: &SQLiteScan,
    session_scan: &SessionScan,
) -> TargetProvider {
    if let Some(provider) = config.and_then(config_provider) {
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

fn config_provider(bytes: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(bytes).ok()?;
    let config = toml::from_str::<toml::Table>(&text).ok()?;
    config
        .get("model_provider")
        .and_then(toml::Value::as_str)
        .and_then(validated_provider_candidate)
}
