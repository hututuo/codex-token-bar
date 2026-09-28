use super::{run_blocking_command, window_auth::require_window_label};
use crate::core::quota::accounts;
use serde::Serialize;
use tauri::{AppHandle, Emitter};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountChoice { id: String, label: String }
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountChoices { revision: u64, selected_id: Option<String>, accounts: Vec<AccountChoice> }
impl From<accounts::Registry> for AccountChoices {
    fn from(state: accounts::Registry) -> Self {
        Self { revision: state.revision, selected_id: state.selected_id,
            accounts: state.accounts.into_iter().map(|a| AccountChoice { id: a.id, label: a.label }).collect() }
    }
}
fn announce(app: &AppHandle, state: accounts::Registry) -> AccountChoices {
    let choices = AccountChoices::from(state);
    let _ = app.emit("quota-accounts-changed", &choices);
    choices
}
#[tauri::command]
pub async fn list_quota_accounts(window: tauri::WebviewWindow) -> Result<AccountChoices, String> {
    require_window_label(&window, "list_quota_accounts")?;
    run_blocking_command(|| accounts::registry().map(AccountChoices::from)).await
}
#[tauri::command]
pub async fn select_quota_account(window: tauri::WebviewWindow, app: AppHandle, id: Option<String>) -> Result<AccountChoices, String> {
    require_window_label(&window, "select_quota_account")?;
    let state = run_blocking_command(move || accounts::select(id)).await?;
    Ok(announce(&app, state))
}
#[tauri::command]
pub async fn save_current_quota_account(window: tauri::WebviewWindow, app: AppHandle,
    source_token: super::dashboard::CodexHomeSourceToken) -> Result<AccountChoices, String> {
    require_window_label(&window, "save_current_quota_account")?;
    // Validate the pinned source before making any registry or vault mutation.
    let (credential, path) = super::dashboard::run_source_bound_dashboard_read(&app, source_token,
        |home| Ok((accounts::current_credential(&home)?, Some(home.join("auth.json").to_string_lossy().into_owned())))).await?;
    let state = run_blocking_command(move || accounts::save(credential, path)).await?;
    Ok(announce(&app, state))
}
#[tauri::command]
pub async fn import_quota_account(window: tauri::WebviewWindow, app: AppHandle, path: String) -> Result<AccountChoices, String> {
    require_window_label(&window, "import_quota_account")?;
    let state = run_blocking_command(move || {
        let path = std::path::Path::new(&path);
        if !path.is_absolute() || path.extension().and_then(|x| x.to_str()) != Some("json") {
            return Err("请选择 OAuth 登录 JSON 文件的完整路径".into());
        }
        accounts::import_file(path)
    }).await?;
    Ok(announce(&app, state))
}
#[tauri::command]
pub async fn remove_quota_account(window: tauri::WebviewWindow, app: AppHandle, id: String) -> Result<AccountChoices, String> {
    require_window_label(&window, "remove_quota_account")?;
    let state = run_blocking_command(move || accounts::remove(&id)).await?;
    Ok(announce(&app, state))
}
