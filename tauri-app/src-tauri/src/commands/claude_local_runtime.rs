use super::run_blocking_command;
use crate::core::claude_local_runtime::{ClaudeLocalRuntimeRegistry, ClaudeLocalRuntimeSnapshot};
#[tauri::command]
pub(crate) async fn read_claude_local_runtime_snapshot(
    app: tauri::AppHandle,
    registry: tauri::State<'_, ClaudeLocalRuntimeRegistry>,
) -> Result<ClaudeLocalRuntimeSnapshot, String> {
    let registry = registry.inner().clone();
    run_blocking_command(move || Ok(registry.read_snapshot(&app))).await
}
