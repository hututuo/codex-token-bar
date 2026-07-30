use super::dashboard::{
    capture_codex_home_source, emit_detected_source_transition, run_source_bound_dashboard_read,
    validate_codex_home_source, CodexHomeSourceToken,
};
use super::run_blocking_command;
use crate::core::session_management;
use crate::models::{
    SessionBatchActionResult, SessionContextPage, SessionDeleteConfirmation,
    SessionManagementCatalog,
};
use std::path::PathBuf;

#[tauri::command]
pub async fn list_session_management_catalog(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    source_token: CodexHomeSourceToken,
) -> Result<SessionManagementCatalog, String> {
    super::window_auth::require_window_label(&window, "list_session_management_catalog")?;
    run_source_bound_dashboard_read(&app, source_token, |home| {
        session_management::list_catalog(&home)
    })
    .await
}

#[tauri::command]
pub async fn read_session_context_page(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    source_token: CodexHomeSourceToken,
    thread_id: String,
    before_offset: Option<u64>,
    page_size: Option<usize>,
) -> Result<SessionContextPage, String> {
    super::window_auth::require_window_label(&window, "read_session_context_page")?;
    run_source_bound_dashboard_read(&app, source_token, move |home| {
        session_management::read_context_page(&home, &thread_id, before_offset, page_size)
    })
    .await
}

#[tauri::command]
pub async fn archive_session_threads(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    source_token: CodexHomeSourceToken,
    thread_ids: Vec<String>,
) -> Result<SessionBatchActionResult, String> {
    super::window_auth::require_window_label(&window, "archive_session_threads")?;
    let expected_source_key = source_token.physical_home_key.clone();
    run_source_bound_session_mutation(&app, source_token, move |home| {
        session_management::archive_threads(&home, thread_ids, &expected_source_key)
    })
    .await
}

#[tauri::command]
pub async fn unarchive_session_threads(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    source_token: CodexHomeSourceToken,
    thread_ids: Vec<String>,
) -> Result<SessionBatchActionResult, String> {
    super::window_auth::require_window_label(&window, "unarchive_session_threads")?;
    let expected_source_key = source_token.physical_home_key.clone();
    run_source_bound_session_mutation(&app, source_token, move |home| {
        session_management::unarchive_threads(&home, thread_ids, &expected_source_key)
    })
    .await
}

#[tauri::command]
pub async fn prepare_session_delete_confirmation(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    source_token: CodexHomeSourceToken,
    thread_ids: Vec<String>,
) -> Result<SessionDeleteConfirmation, String> {
    super::window_auth::require_window_label(&window, "prepare_session_delete_confirmation")?;
    let expected_source_key = source_token.physical_home_key.clone();
    run_source_bound_dashboard_read(&app, source_token, move |home| {
        session_management::prepare_delete_confirmation(&home, thread_ids, &expected_source_key)
    })
    .await
}

#[tauri::command]
pub async fn delete_session_threads(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    source_token: CodexHomeSourceToken,
    thread_ids: Vec<String>,
    create_recovery_archive: bool,
    confirmation: SessionDeleteConfirmation,
) -> Result<SessionBatchActionResult, String> {
    super::window_auth::require_window_label(&window, "delete_session_threads")?;
    session_management::require_delete_recovery_archive(create_recovery_archive)?;
    let recovery_source_key = source_token.physical_home_key.clone();
    run_source_bound_session_mutation(&app, source_token, move |home| {
        session_management::delete_threads(
            &home,
            thread_ids,
            create_recovery_archive,
            &recovery_source_key,
            confirmation,
        )
    })
    .await
}

#[tauri::command]
pub async fn create_session_recovery_archives(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    source_token: CodexHomeSourceToken,
    thread_ids: Vec<String>,
) -> Result<SessionBatchActionResult, String> {
    super::window_auth::require_window_label(&window, "create_session_recovery_archives")?;
    let recovery_source_key = source_token.physical_home_key.clone();
    run_source_bound_session_mutation(&app, source_token, move |home| {
        session_management::create_recovery_archives(&home, thread_ids, &recovery_source_key)
    })
    .await
}

async fn run_source_bound_session_mutation<Mutation>(
    app: &tauri::AppHandle,
    expected: CodexHomeSourceToken,
    mutation: Mutation,
) -> Result<SessionBatchActionResult, String>
where
    Mutation: FnOnce(PathBuf) -> SessionBatchActionResult + Send + 'static,
{
    emit_detected_source_transition(app)?;
    let captured = capture_codex_home_source(Some(&expected))?;
    let completed_source_token = captured.source_token.clone();
    let mut result = run_blocking_command(move || Ok(mutation(captured.codex_home))).await?;

    let mut source_warnings = Vec::new();
    if let Err(error) = emit_detected_source_transition(app) {
        source_warnings.push(format!(
            "写操作已经返回，但 Codex Home 来源切换事件发布失败：{error}"
        ));
    }
    if let Err(error) = validate_codex_home_source(&completed_source_token) {
        source_warnings.push(format!(
            "写操作可能已经执行，随后 Codex Home 来源发生变化：{error}；以上逐项结果与恢复包路径均予保留，请以新目录复核"
        ));
    }
    result.warnings.extend(source_warnings);
    Ok(result)
}
