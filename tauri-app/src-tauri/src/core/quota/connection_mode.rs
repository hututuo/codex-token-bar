use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{io::Read, path::Path};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ConnectionMode {
    Api,
    Subscription,
    Unknown,
}

fn configuration(home: &Path) -> Option<String> {
    let file = match std::fs::File::open(home.join("config.toml")) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Some(String::new()),
        Err(_) => return None,
    };
    let mut bytes = Vec::new();
    file.take(1_048_577).read_to_end(&mut bytes).ok()?;
    if bytes.len() > 1_048_576 {
        return None;
    }
    String::from_utf8(bytes).ok()
}

pub(super) fn configuration_identity(home: &Path) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(
        configuration(home)
            .unwrap_or_else(|| "unreadable-config".into())
            .as_bytes(),
    );
    // API authentication can replace a subscription while leaving the old
    // account tokens in auth.json. Such a transition invalidates in-flight data.
    digest.update(format!("\0{:?}", read(home)).as_bytes());
    digest.finalize().into()
}

pub(super) fn read(home: &Path) -> ConnectionMode {
    let config = configuration(home);
    if classify(config.as_deref(), None) == ConnectionMode::Api {
        return ConnectionMode::Api;
    }
    let auth = super::accounts::current_auth_data(home)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok());
    classify(config.as_deref(), auth.as_ref())
}

fn classify(config: Option<&str>, auth: Option<&Value>) -> ConnectionMode {
    let Some(config) = config.and_then(|text| text.parse::<toml::Table>().ok()) else {
        return ConnectionMode::Unknown;
    };
    if config.get("profile").is_some_and(|value| !value.is_str()) {
        return ConnectionMode::Unknown;
    }
    let profile = config
        .get("profile")
        .and_then(toml::Value::as_str)
        .and_then(|name| config.get("profiles")?.get(name));
    let selected = |key: &str| profile.and_then(|p| p.get(key)).or_else(|| config.get(key));
    if ["model_provider", "forced_login_method"]
        .iter()
        .any(|key| selected(key).is_some_and(|value| !value.is_str()))
    {
        return ConnectionMode::Unknown;
    }
    let provider = selected("model_provider")
        .and_then(toml::Value::as_str)
        .unwrap_or("openai");
    let provider_config = config.get("model_providers").and_then(|p| p.get(provider));
    if provider_config
        .and_then(|p| p.get("requires_openai_auth"))
        .is_some_and(|value| !value.is_bool())
    {
        return ConnectionMode::Unknown;
    }
    let has = |key: &str| {
        provider_config
            .and_then(|p| p.get(key))
            .and_then(toml::Value::as_str)
            .is_some_and(|s| !s.is_empty())
    };
    if provider != "openai"
        || selected("forced_login_method").and_then(toml::Value::as_str) == Some("api")
        || provider_config
            .and_then(|p| p.get("requires_openai_auth"))
            .and_then(toml::Value::as_bool)
            == Some(false)
        || has("base_url")
        || has("env_key")
        || has("experimental_bearer_token")
    {
        return ConnectionMode::Api;
    }
    let mode = auth
        .and_then(|a| a.get("auth_mode"))
        .and_then(Value::as_str)
        .map(str::to_lowercase);
    match mode.as_deref() {
        Some("apikey" | "api_key") => return ConnectionMode::Api,
        Some("chatgpt" | "chatgptauthtokens") => return ConnectionMode::Subscription,
        _ => {}
    }
    if auth
        .and_then(|a| a.get("OPENAI_API_KEY"))
        .and_then(Value::as_str)
        .is_some_and(|s| !s.trim().is_empty())
    {
        return ConnectionMode::Api;
    }
    if auth
        .and_then(|a| a.get("tokens")?.get("access_token"))
        .and_then(Value::as_str)
        .is_some_and(|s| !s.is_empty() && !s.starts_with("sk-"))
    {
        return ConnectionMode::Subscription;
    }
    ConnectionMode::Unknown
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_connection_mode_cases() {
        let cases: Value = serde_json::from_str(include_str!(
            "../../../../../Tests/Fixtures/codex-connection-mode.json"
        ))
        .unwrap();
        for case in cases.as_array().unwrap() {
            let observed = classify(case["config"].as_str(), case.get("auth"));
            assert_eq!(
                format!("{observed:?}").to_lowercase(),
                case["expected"].as_str().unwrap(),
                "{}",
                case["name"]
            );
        }
    }
}
