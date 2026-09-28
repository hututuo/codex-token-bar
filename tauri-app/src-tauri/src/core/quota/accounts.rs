//! Independent quota accounts. No provider rewriting, inference, or shared refresh-token rotation.
use base64::{engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD}, Engine as _};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs, path::{Path, PathBuf}, io::Write};

const SERVICE: &str = "com.codextokenbar.quota-accounts";
const AUTH_ERROR: &str = "未找到有效的 ChatGPT 登录凭据；请添加或更新额度账号。普通 API Key 不支持订阅额度查询。";
const MAX_BYTES: u64 = 1_048_576;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Credential {
    #[serde(rename = "accountID")]
    pub account_id: String,
    #[serde(rename = "userID")]
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
    fn expires_at(&self) -> i64 { jwt(&self.access_token)["exp"].as_i64().unwrap_or(0) }
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

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountEntry { pub id: String, pub label: String, pub source_path: Option<String> }

#[derive(Clone, Serialize, Deserialize)]
pub struct Registry {
    pub version: u32,
    pub revision: u64,
    #[serde(rename = "selectedID")]
    pub selected_id: Option<String>,
    pub accounts: Vec<AccountEntry>,
}
impl Default for Registry {
    fn default() -> Self { Self { version: 1, revision: 0, selected_id: None, accounts: vec![] } }
}

fn root() -> Result<PathBuf, String> {
    dirs::data_dir().map(|p| p.join("CodexTokenBar")).ok_or_else(|| "无法定位账号设置目录".into())
}
fn limited_read(path: &Path) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let file = fs::File::open(path).map_err(|_| AUTH_ERROR)?;
    let mut data = vec![];
    file.take(MAX_BYTES + 1).read_to_end(&mut data).map_err(|_| AUTH_ERROR)?;
    if data.len() as u64 > MAX_BYTES { return Err(AUTH_ERROR.into()); }
    Ok(data)
}
pub fn registry() -> Result<Registry, String> {
    let path = root()?.join("quota-accounts.json");
    if !path.exists() { return Ok(Registry::default()); }
    let state: Registry = serde_json::from_slice(&limited_read(&path)?).map_err(|_| "额度账号设置损坏")?;
    if state.version != 1 || state.selected_id.as_ref().is_some_and(|id| !state.accounts.iter().any(|a| &a.id == id)) { return Err("额度账号设置版本不兼容".into()); }
    Ok(state)
}

#[cfg(any(target_os="macos", target_os="windows"))]
fn read_secret(service: &str, id: &str) -> Result<Vec<u8>, String> {
    #[cfg(target_os="windows")]
    if service == SERVICE { return windows_vault::read(id); }
    keyring::Entry::new(service, id).and_then(|entry| entry.get_secret()).map_err(|_| "无法访问系统安全凭据存储".into())
}
#[cfg(not(any(target_os="macos", target_os="windows")))]
fn read_secret(_: &str, _: &str) -> Result<Vec<u8>, String> { Err("此平台尚未支持保存额度账号".into()) }
#[cfg(target_os="macos")]
fn write_secret(credential: &Credential) -> Result<(), String> {
    let data = serde_json::to_vec(credential).map_err(|_| "凭据编码失败")?;
    keyring::Entry::new(SERVICE, &credential.id()).and_then(|entry| entry.set_secret(&data))
        .map_err(|_| "无法保存至系统安全凭据存储".into())
}
#[cfg(target_os="windows")]
fn write_secret(credential: &Credential) -> Result<(), String> {
    windows_vault::write(&credential.id(), &serde_json::to_vec(credential).map_err(|_| "凭据编码失败")?)
}
#[cfg(not(any(target_os="macos", target_os="windows")))]
fn write_secret(_: &Credential) -> Result<(), String> { Err("此平台尚未支持保存额度账号".into()) }

#[cfg(target_os="macos")]
fn read_saved_secret(id: &str) -> Result<Option<Vec<u8>>, String> {
    let entry = keyring::Entry::new(SERVICE, id).map_err(|_| "无法访问系统安全凭据存储")?;
    match entry.get_secret() {
        Ok(data) => Ok(Some(data)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(_) => Err("无法访问系统安全凭据存储".into()),
    }
}
#[cfg(target_os="windows")]
fn read_saved_secret(id: &str) -> Result<Option<Vec<u8>>, String> { windows_vault::read_optional(id) }
#[cfg(not(any(target_os="macos", target_os="windows")))]
fn read_saved_secret(_: &str) -> Result<Option<Vec<u8>>, String> { Ok(None) }

#[cfg(target_os="macos")]
fn delete_saved_secret(id: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(SERVICE, id).map_err(|_| "无法访问系统安全凭据存储")?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(_) => Err("无法移除系统安全凭据".into()),
    }
}
#[cfg(target_os="windows")]
fn delete_saved_secret(id: &str) -> Result<(), String> { windows_vault::remove(id) }
#[cfg(not(any(target_os="macos", target_os="windows")))]
fn delete_saved_secret(_: &str) -> Result<(), String> { Ok(()) }

#[cfg(target_os="macos")]
fn restore_saved_secret(id: &str, data: &[u8]) -> Result<(), String> {
    keyring::Entry::new(SERVICE, id).and_then(|entry| entry.set_secret(data))
        .map_err(|_| "无法恢复系统安全凭据".into())
}
#[cfg(target_os="windows")]
fn restore_saved_secret(id: &str, data: &[u8]) -> Result<(), String> { windows_vault::write(id, data) }
#[cfg(not(any(target_os="macos", target_os="windows")))]
fn restore_saved_secret(_: &str, _: &[u8]) -> Result<(), String> { Err("此平台尚未支持保存额度账号".into()) }

fn update_secret_if_changed(credential: &Credential) -> Result<(), String> {
    if read_secret(SERVICE, &credential.id()).ok()
        .and_then(|data| serde_json::from_slice::<Credential>(&data).ok())
        .is_some_and(|saved| saved.access_token == credential.access_token) { return Ok(()); }
    with_registry_lock(|| {
        if !registry()?.accounts.iter().any(|a| a.id == credential.id()) { return Ok(()); }
        // Do not overwrite a newer token saved while waiting for the shared lock.
        if read_secret(SERVICE, &credential.id()).ok()
            .and_then(|data| serde_json::from_slice::<Credential>(&data).ok())
            .is_some_and(|saved| saved.id() == credential.id() &&
                (saved.access_token == credential.access_token || saved.expires_at() > credential.expires_at())) { return Ok(()); }
        write_secret(credential)

    })
}

pub fn current_credential(home: &Path) -> Result<Credential, String> {
    let canonical = fs::canonicalize(home).unwrap_or_else(|_| home.into());
    let config = fs::read_to_string(home.join("config.toml")).unwrap_or_default();
    let mode = config.parse::<toml::Value>().ok().and_then(|value| value.get("cli_auth_credentials_store")?.as_str().map(str::to_owned));
    if matches!(mode.as_deref(), Some("keyring" | "auto")) {
        let hash = format!("{:x}", Sha256::digest(canonical.to_string_lossy().as_bytes()));
        if let Ok(data) = read_secret("Codex Auth", &format!("cli|{}", &hash[..16])) { return Credential::parse(&data); }
        if mode.as_deref() == Some("keyring") { return Err(AUTH_ERROR.into()); }
    }
    Credential::parse(&limited_read(&home.join("auth.json"))?)
}

pub fn credential(home: &Path) -> Result<Credential, String> {
    let state = registry()?;
    let Some(id) = state.selected_id else { return current_credential(home); };
    let entry = state.accounts.iter().find(|entry| entry.id == id).ok_or(AUTH_ERROR)?;
    let mut candidates = vec![];
    if let Ok(current) = current_credential(home) { candidates.push(current); }
    if let Some(path) = &entry.source_path {
        if let Ok(linked) = limited_read(Path::new(path)).and_then(|data| Credential::parse(&data)) { candidates.push(linked); }
    }
    if let Ok(data) = read_secret(SERVICE, &id) {
        if let Ok(saved) = serde_json::from_slice::<Credential>(&data) { candidates.push(saved); }
    }
    let fresh = candidates.into_iter().filter(|c| c.id() == id).enumerate()
        .max_by(|(ai, a), (bi, b)| a.expires_at().cmp(&b.expires_at()).then_with(|| bi.cmp(ai)))
        .map(|(_, c)| c).ok_or(AUTH_ERROR)?;
    let _ = update_secret_if_changed(&fresh);
    Ok(fresh)
}

fn with_registry_lock<T>(body: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    use fs2::FileExt;
    let root = root()?;
    fs::create_dir_all(&root).map_err(|_| "无法创建账号设置目录")?;
    let lock = fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(root.join("quota-accounts.lock")).map_err(|_| "无法锁定账号设置")?;
    lock.lock_exclusive().map_err(|_| "无法锁定账号设置")?;
    body()
}

fn persist_registry(root: &Path, state: &Registry) -> Result<(), String> {
    let temp = root.join(format!("quota-accounts-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut options = fs::OpenOptions::new(); options.create_new(true).write(true);
        #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
        let mut file = options.open(&temp).map_err(|_| "无法保存账号设置")?;
        file.write_all(&serde_json::to_vec(state).map_err(|_| "账号设置编码失败")?).map_err(|_| "无法保存账号设置")?;
        file.sync_all().map_err(|_| "无法持久化账号设置")?;
        drop(file);
        fs::rename(&temp, root.join("quota-accounts.json")).map_err(|_| "无法提交账号设置")?;
        Ok::<_, String>(())
    })();
    if result.is_err() { let _ = fs::remove_file(&temp); }
    result
}

fn mutate(body: impl FnOnce(&mut Registry) -> Result<(), String>) -> Result<Registry, String> {
    with_registry_lock(|| {
    let root = root()?;
    let mut state = registry()?;
    body(&mut state)?;
    state.revision = state.revision.saturating_add(1);
    persist_registry(&root, &state)?;
    Ok(state)
    })
}

fn remove_transaction(
    mut state: Registry,
    id: &str,
    read_secret: impl FnOnce(&str) -> Result<Option<Vec<u8>>, String>,
    delete_secret: impl FnOnce(&str) -> Result<(), String>,
    persist: impl FnOnce(&Registry) -> Result<(), String>,
    restore_secret: impl FnOnce(&str, &[u8]) -> Result<(), String>,
) -> Result<Registry, String> {
    if !state.accounts.iter().any(|account| account.id == id) { return Err("额度账号不存在".into()); }
    let previous_secret = read_secret(id)?;
    delete_secret(id)?;
    state.accounts.retain(|account| account.id != id);
    if state.selected_id.as_deref() == Some(id) { state.selected_id = None; }
    state.revision = state.revision.saturating_add(1);
    if let Err(persist_error) = persist(&state) {
        if let Some(secret) = previous_secret {
            if let Err(restore_error) = restore_secret(id, &secret) {
                return Err(format!("{persist_error}；恢复已保存凭据失败：{restore_error}"));
            }
        }
        return Err(persist_error);
    }
    Ok(state)
}

pub fn save_current(home: &Path) -> Result<Registry, String> {
    save(current_credential(home)?, Some(home.join("auth.json").to_string_lossy().into()))
}
pub fn import_file(path: &Path) -> Result<Registry, String> {
    save(Credential::parse(&limited_read(path)?)?, Some(path.to_string_lossy().into()))
}
pub(crate) fn save(credential: Credential, source_path: Option<String>) -> Result<Registry, String> {
    mutate(|state| {
        write_secret(&credential)?;
        let entry = AccountEntry { id: credential.id(), label: credential.label, source_path };
        if let Some(index) = state.accounts.iter().position(|a| a.id == entry.id) { state.accounts[index] = entry.clone(); }
        else { state.accounts.push(entry.clone()); }
        state.selected_id = Some(entry.id);
        Ok(())
    })
}
pub fn select(id: Option<String>) -> Result<Registry, String> {
    mutate(|state| {
        if id.as_ref().is_some_and(|id| !state.accounts.iter().any(|a| &a.id == id)) { return Err("额度账号不存在".into()); }
        state.selected_id = id; Ok(())
    })
}
pub fn remove(id: &str) -> Result<Registry, String> {
    with_registry_lock(|| {
        let root = root()?;
        let state = registry()?;
        remove_transaction(
            state,
            id,
            read_saved_secret,
            delete_saved_secret,
            |state| persist_registry(&root, state),
            restore_saved_secret,
        )
    })
}

pub fn selection_key(home: &Path) -> String {
    let Ok(state) = registry() else { return "invalid-registry".into(); };
    format!("{}:{}:{}", state.revision, state.selected_id.as_deref().unwrap_or("local"), credential(home).map(|c| c.id()).unwrap_or_else(|_| "unavailable".into()))
}

/// OAuth JWTs can exceed Windows Credential Manager's 2560-byte limit.
/// DPAPI binds the encrypted payload to the current Windows user profile.
#[cfg(target_os="windows")]
mod windows_vault {
    use super::*;
    use windows_sys::Win32::{Foundation::LocalFree, Security::Cryptography::{
        CryptProtectData, CryptUnprotectData, CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN,
    }};
    fn path(id: &str) -> Result<PathBuf, String> {
        if id.len() != 64 || !id.bytes().all(|b| b.is_ascii_hexdigit()) { return Err(AUTH_ERROR.into()); }
        Ok(root()?.join("quota-credentials").join(format!("{id}.dpapi")))
    }
    fn transform(data: &[u8], encrypt: bool) -> Result<Vec<u8>, String> {
        let input = CRYPT_INTEGER_BLOB { cbData: data.len().try_into().map_err(|_| AUTH_ERROR)?, pbData: data.as_ptr() as *mut u8 };
        let mut output = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
        let entropy_bytes = SERVICE.as_bytes();
        let entropy = CRYPT_INTEGER_BLOB { cbData: entropy_bytes.len() as u32, pbData: entropy_bytes.as_ptr() as *mut u8 };
        unsafe {
            let success = if encrypt {
                CryptProtectData(&input, std::ptr::null(), &entropy, std::ptr::null(), std::ptr::null(), CRYPTPROTECT_UI_FORBIDDEN, &mut output)
            } else {
                CryptUnprotectData(&input, std::ptr::null_mut(), &entropy, std::ptr::null(), std::ptr::null(), CRYPTPROTECT_UI_FORBIDDEN, &mut output)
            };
            if success == 0 { return Err("Windows 安全凭据存储不可用".into()); }
            let result = if output.cbData as u64 <= MAX_BYTES && !output.pbData.is_null() {
                Ok(std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec())
            } else { Err("Windows 凭据格式异常".into()) };
            LocalFree(output.pbData as *mut core::ffi::c_void);
            result
        }
    }
    pub(super) fn read_optional(id: &str) -> Result<Option<Vec<u8>>, String> {
        use std::io::Read;
        let file = match fs::File::open(path(id)?) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err("无法访问 Windows 安全凭据存储".into()),
        };
        let mut data = vec![];
        file.take(MAX_BYTES + 1).read_to_end(&mut data).map_err(|_| "无法访问 Windows 安全凭据存储")?;
        if data.len() as u64 > MAX_BYTES { return Err("Windows 凭据格式异常".into()); }
        transform(&data, false).map(Some)
    }
    pub(super) fn read(id: &str) -> Result<Vec<u8>, String> { transform(&limited_read(&path(id)?)?, false) }
    pub(super) fn write(id: &str, data: &[u8]) -> Result<(), String> {
        let path = path(id)?;
        let parent = path.parent().ok_or(AUTH_ERROR)?;
        fs::create_dir_all(parent).map_err(|_| "无法创建安全凭据目录")?;
        let encrypted = transform(data, true)?;
        let temp = parent.join(format!("{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut file = fs::OpenOptions::new().create_new(true).write(true).open(&temp).map_err(|_| "无法保存安全凭据")?;
            file.write_all(&encrypted).map_err(|_| "无法写入安全凭据")?;
            file.sync_all().map_err(|_| "无法持久化安全凭据")?;
            drop(file);
            fs::rename(&temp, &path).map_err(|_| "无法提交安全凭据".to_string())
        })();
        if result.is_err() { let _ = fs::remove_file(temp); }
        result
    }
    pub(super) fn remove(id: &str) -> Result<(), String> {
        match fs::remove_file(path(id)?) { Ok(()) => Ok(()), Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()), Err(_) => Err("无法移除安全凭据".into()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::{Cell, RefCell}, rc::Rc};
    fn auth(account: &str, user: &str, signature: &str) -> Value {
        let claims = serde_json::json!({"https://api.openai.com/auth": {"chatgpt_account_id": account, "chatgpt_user_id": user}, "https://api.openai.com/profile": {"email": "same@example.invalid"}});
        let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
        serde_json::json!({"access_token": format!("e30.{payload}.{signature}"), "account_id": account})
    }
    fn parse(value: &Value) -> Credential { Credential::parse(&serde_json::to_vec(value).unwrap()).unwrap() }
    #[test] fn token_rotation_and_cross_language_identity() {
        let a = parse(&auth("account-1", "user-1", "one"));
        let b = parse(&auth("account-1", "user-1", "two"));
        assert_eq!(a.id(), b.id()); assert_ne!(a.access_token, b.access_token);
        assert_eq!(a.id(), "a6903db6ef51e158e82e0d8cac1984e301afbb9746a826285f4d0d3f4d15c313");
        let nested = serde_json::json!({"tokens": auth("account-1", "user-1", "one")});
        assert_eq!(a.id(), parse(&nested).id());
    }
    #[test] fn same_email_different_account_or_member_is_distinct() {
        let a = parse(&auth("account-1", "user-1", "one"));
        for value in [auth("account-2", "user-1", "one"), auth("account-1", "user-2", "one")] {
            let b = parse(&value); assert_eq!(a.label,b.label); assert_ne!(a.id(), b.id());
        }
    }
    #[test] fn conflicts_missing_user_and_api_keys_fail_closed() {
        let mut conflict = auth("account-1", "user-1", "one"); conflict["account_id"] = Value::from("other");
        for value in [conflict, auth("account-1", "", "one"), serde_json::json!({"access_token":"sk-synthetic", "account_id":"account-1"})] {
            assert!(Credential::parse(&serde_json::to_vec(&value).unwrap()).is_err());
        }
    }
    #[test] fn no_secret_enters_manifest() {
        let c = parse(&auth("account-1", "user-1", "one"));
        let state = Registry { accounts: vec![AccountEntry { id: c.id(), label: c.label.clone(), source_path: None }], selected_id: Some(c.id()), ..Registry::default() };
        let serialized = serde_json::to_string(&state).unwrap();
        assert!(!serialized.contains(&c.access_token)); assert!(!serialized.contains("accessToken"));
    }

    fn removal_registry() -> Registry {
        Registry {
            version: 1,
            revision: 7,
            selected_id: Some("target".into()),
            accounts: vec![
                AccountEntry { id: "target".into(), label: "Target".into(), source_path: None },
                AccountEntry { id: "other".into(), label: "Other".into(), source_path: None },
            ],
        }
    }

    #[test]
    fn remove_transaction_succeeds() {
        let persisted = RefCell::new(None);
        let state = remove_transaction(
            removal_registry(),
            "target",
            |_| Ok(Some(b"saved".to_vec())),
            |_| Ok(()),
            |state| { *persisted.borrow_mut() = Some(state.clone()); Ok(()) },
            |_, _| -> Result<(), String> { panic!("successful persistence must not restore the credential") },
        ).unwrap();
        assert_eq!(state.revision, 8);
        assert_eq!(state.selected_id, None);
        assert_eq!(state.accounts.len(), 1);
        assert_eq!(state.accounts[0].id, "other");
        let persisted = persisted.into_inner().unwrap();
        assert_eq!(persisted.revision, state.revision);
        assert_eq!(persisted.accounts[0].id, "other");
    }

    #[test]
    fn remove_delete_failure_leaves_manifest_unchanged() {
        let manifest = Rc::new(RefCell::new(removal_registry()));
        let original = manifest.borrow().clone();
        let persist_called = Cell::new(false);
        let error = remove_transaction(
            original.clone(),
            "target",
            |_| Ok(Some(b"saved".to_vec())),
            |_| Err("delete failed".into()),
            |state| { persist_called.set(true); *manifest.borrow_mut() = state.clone(); Ok(()) },
            |_, _| Ok(()),
        ).err().unwrap();
        assert_eq!(error, "delete failed");
        assert!(!persist_called.get());
        let manifest = manifest.borrow();
        assert_eq!(manifest.revision, original.revision);
        assert_eq!(manifest.selected_id, original.selected_id);
        assert_eq!(manifest.accounts.len(), original.accounts.len());
        assert_eq!(manifest.accounts[0].id, "target");
    }

    #[test]
    fn remove_persist_failure_restores_credential() {
        let secret = RefCell::new(Some(b"saved".to_vec()));
        let error = remove_transaction(
            removal_registry(),
            "target",
            |_| Ok(secret.borrow().clone()),
            |_| { secret.borrow_mut().take(); Ok(()) },
            |_| Err("persist failed".into()),
            |_, data| { *secret.borrow_mut() = Some(data.to_vec()); Ok(()) },
        ).err().unwrap();
        assert_eq!(error, "persist failed");
        assert_eq!(secret.into_inner(), Some(b"saved".to_vec()));
    }

    #[test]
    fn remove_restore_failure_reports_both_errors() {
        let secret = RefCell::new(Some(b"saved".to_vec()));
        let error = remove_transaction(
            removal_registry(),
            "target",
            |_| Ok(secret.borrow().clone()),
            |_| { secret.borrow_mut().take(); Ok(()) },
            |_| Err("persist failed".into()),
            |_, _| Err("restore failed".into()),
        ).err().unwrap();
        assert!(error.contains("persist failed"));
        assert!(error.contains("restore failed"));
        assert_eq!(secret.into_inner(), None);
    }
}
