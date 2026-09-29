//! Reads the identity for the Codex Home currently selected in app settings.
use base64::{engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD}, Engine as _};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs, io::Read, path::Path};

const AUTH_ERROR: &str = "未找到有效的 ChatGPT 登录凭据；请在 Codex 中重新登录后重试。普通 API Key 不支持订阅额度查询。";
const MAX_BYTES: u64 = 1_048_576;

#[derive(Clone)]
pub struct Credential {
    pub account_id: String,
    pub user_id: String,
    pub label: String,
    pub access_token: String,
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key)?.as_str().map(str::trim).filter(|s| !s.is_empty())
}

fn jwt(value: &str) -> Value {
    let parts: Vec<_> = value.split('.').collect();
    if parts.len() != 3 { return Value::Null; }
    URL_SAFE_NO_PAD.decode(parts[1]).or_else(|_| URL_SAFE.decode(parts[1])).ok()
        .and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or(Value::Null)
}

impl Credential {
    pub fn id(&self) -> String {
        format!("{:x}", Sha256::digest(format!("quota-account-v1\0{}\0{}", self.user_id, self.account_id).as_bytes()))
    }

    pub fn parse(data: &[u8]) -> Result<Self, String> {
        if data.len() as u64 > MAX_BYTES { return Err(AUTH_ERROR.into()); }
        let root: Value = serde_json::from_slice(data).map_err(|_| AUTH_ERROR)?;
        let tokens = root.get("tokens").unwrap_or(&root);
        let access = text(tokens, "access_token").ok_or(AUTH_ERROR)?;
        if access.len() >= 65_536 || !access.bytes().all(|b| b > 32 && b < 127) || access.starts_with("sk-") {
            return Err(AUTH_ERROR.into());
        }
        let access_claims = jwt(access);
        let id_claims = jwt(text(tokens, "id_token").unwrap_or(""));
        let access_auth = &access_claims["https://api.openai.com/auth"];
        let id_auth = &id_claims["https://api.openai.com/auth"];
        if text(access_auth, "chatgpt_account_id").zip(text(id_auth, "chatgpt_account_id")).is_some_and(|(a,b)| a != b) {
            return Err("登录凭据包含互相冲突的账号标识".into());
        }
        let explicit = text(tokens, "account_id").or_else(|| text(&root, "account_id"));
        let claim = text(access_auth, "chatgpt_account_id").or_else(|| text(id_auth, "chatgpt_account_id"));
        if explicit.zip(claim).is_some_and(|(a,b)| a != b) { return Err("账号标识与登录凭据不一致".into()); }
        let account = explicit.or(claim).ok_or(AUTH_ERROR)?;
        if account.len() >= 256 || !account.bytes().all(|b| b > 32 && b < 127) { return Err(AUTH_ERROR.into()); }
        let user = text(access_auth, "chatgpt_user_id").or_else(|| text(id_auth, "chatgpt_user_id"))
            .or_else(|| text(&id_claims, "sub")).or_else(|| text(&access_claims, "sub")).unwrap_or("");
        if user.is_empty() { return Err(AUTH_ERROR.into()); }
        let label = text(&id_claims, "email").or_else(|| text(&access_claims["https://api.openai.com/profile"], "email"))
            .or_else(|| text(&root, "email")).or_else(|| text(&id_claims, "name")).unwrap_or("ChatGPT 账号");
        Ok(Self { account_id: account.into(), user_id: user.into(), label: label.into(), access_token: access.into() })
    }
}

fn limited_read(path: &Path) -> Result<Vec<u8>, String> {
    let file = fs::File::open(path).map_err(|_| AUTH_ERROR)?;
    let mut data = vec![];
    file.take(MAX_BYTES + 1).read_to_end(&mut data).map_err(|_| AUTH_ERROR)?;
    if data.len() as u64 > MAX_BYTES { return Err(AUTH_ERROR.into()); }
    Ok(data)
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
fn read_codex_keyring(account: &str) -> Result<Vec<u8>, String> {
    keyring::Entry::new("Codex Auth", account)
        .and_then(|entry| entry.get_secret())
        .map_err(|_| AUTH_ERROR.into())
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn read_codex_keyring(_: &str) -> Result<Vec<u8>, String> {
    Err(AUTH_ERROR.into())
}

pub fn current_credential(home: &Path) -> Result<Credential, String> {
    let canonical = fs::canonicalize(home).unwrap_or_else(|_| home.into());
    let config = fs::read_to_string(home.join("config.toml")).unwrap_or_default();
    let mode = config.parse::<toml::Value>().ok()
        .and_then(|value| value.get("cli_auth_credentials_store")?.as_str().map(str::to_owned));
    if matches!(mode.as_deref(), Some("keyring" | "auto")) {
        let hash = format!("{:x}", Sha256::digest(canonical.to_string_lossy().as_bytes()));
        if let Ok(data) = read_codex_keyring(&format!("cli|{}", &hash[..16])) { return Credential::parse(&data); }
        if mode.as_deref() == Some("keyring") { return Err(AUTH_ERROR.into()); }
    }
    Credential::parse(&limited_read(&home.join("auth.json"))?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
    use serde_json::json;

    fn auth(account: &str, user: &str, signature: &str) -> Vec<u8> {
        let claims = json!({"https://api.openai.com/auth": {
            "chatgpt_account_id": account,
            "chatgpt_user_id": user,
        }});
        let token = format!("e30.{}.{}", URL_SAFE_NO_PAD.encode(claims.to_string()), signature);
        json!({"tokens": {"access_token": token, "account_id": account}}).to_string().into_bytes()
    }

    #[test]
    fn token_rotation_keeps_current_account_identity_stable() {
        let first = Credential::parse(&auth("account-a", "user-a", "first")).unwrap();
        let rotated = Credential::parse(&auth("account-a", "user-a", "rotated")).unwrap();
        let other = Credential::parse(&auth("account-b", "user-a", "other")).unwrap();
        assert_eq!(first.id(), rotated.id());
        assert_ne!(first.id(), other.id());
    }

    #[test]
    fn conflicting_account_identity_is_rejected() {
        let claims = json!({"https://api.openai.com/auth": {
            "chatgpt_account_id": "account-from-token",
            "chatgpt_user_id": "user-a",
        }});
        let token = format!("e30.{}.signature", URL_SAFE_NO_PAD.encode(claims.to_string()));
        let auth = json!({"tokens": {"access_token": token, "account_id": "different-account"}});
        assert!(Credential::parse(auth.to_string().as_bytes()).is_err());
    }

    #[test]
    fn ordinary_api_keys_are_not_subscription_credentials() {
        let auth = json!({"access_token": "sk-not-a-subscription-token", "account_id": "account-a"});
        assert!(Credential::parse(auth.to_string().as_bytes()).is_err());
    }
}
