use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

pub fn read_access_token(codex_home: &Path) -> Option<String> {
    let auth = read_auth_json(codex_home)?;
    let token = auth
        .get("tokens")
        .and_then(|tokens| tokens.get("access_token"))
        .and_then(Value::as_str)?
        .trim()
        .to_string();
    if token.is_empty() {
        None
    } else {
        Some(token)
    }
}

pub fn read_local_account_name(codex_home: &Path) -> Option<String> {
    let auth = read_auth_json(codex_home)?;
    let token = auth
        .get("tokens")
        .and_then(|tokens| tokens.get("id_token"))
        .and_then(Value::as_str)?;
    let payload = decode_jwt_payload(token)?;
    ["name", "nickname", "preferred_username", "email"]
        .iter()
        .filter_map(|key| payload.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .find(|value| !value.is_empty())
        .map(str::to_string)
}

pub fn read_local_account_key(codex_home: &Path) -> Option<String> {
    let auth = read_auth_json(codex_home)?;
    let token = auth
        .get("tokens")
        .and_then(|tokens| tokens.get("id_token"))
        .and_then(Value::as_str)?;
    stable_account_key(&decode_jwt_payload(token)?)
}

fn stable_account_key(payload: &BTreeMap<String, Value>) -> Option<String> {
    [
        ("sub", "sub:"),
        ("account_id", "account:"),
        ("accountId", "account:"),
    ]
    .into_iter()
    .find_map(|(key, prefix)| {
        payload
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| format!("{prefix}{value}"))
    })
}

fn read_auth_json(codex_home: &Path) -> Option<Value> {
    let data = std::fs::read(codex_home.join("auth.json")).ok()?;
    serde_json::from_slice(&data).ok()
}

fn decode_jwt_payload(token: &str) -> Option<BTreeMap<String, Value>> {
    let payload = token.split('.').nth(1)?;
    let bytes = URL_SAFE_NO_PAD.decode(payload).ok()?;
    serde_json::from_slice(&bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_account_name_from_auth_jwt() {
        let payload =
            URL_SAFE_NO_PAD.encode(r#"{"name":"本地用户","email":"local-account@codex.local"}"#);
        let decoded = decode_jwt_payload(&format!("header.{payload}.signature")).unwrap();
        assert_eq!(decoded.get("name").and_then(Value::as_str), Some("本地用户"));
    }

    #[test]
    fn decodes_stable_account_key_from_id_token_subject() {
        let payload =
            URL_SAFE_NO_PAD.encode(r#"{"sub":"account-subject","account_id":"fallback"}"#);
        let decoded = decode_jwt_payload(&format!("header.{payload}.signature")).unwrap();

        assert_eq!(
            stable_account_key(&decoded).as_deref(),
            Some("sub:account-subject")
        );
    }

    #[test]
    fn stable_account_key_requires_a_nonempty_subject_or_account_id() {
        let payload = URL_SAFE_NO_PAD.encode(r#"{"sub":"  ","account_id":"account-fallback"}"#);
        let decoded = decode_jwt_payload(&format!("header.{payload}.signature")).unwrap();

        assert_eq!(
            stable_account_key(&decoded).as_deref(),
            Some("account:account-fallback")
        );
        assert_eq!(stable_account_key(&BTreeMap::new()), None);
    }
}
