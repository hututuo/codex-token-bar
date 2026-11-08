use super::{run_blocking_command,window_auth::require_window_label};
use crate::core::diagnostics::{self,Area,Phase,Configuration};
use std::sync::atomic::{AtomicBool,Ordering};
static EXPORTING:AtomicBool=AtomicBool::new(false);

#[tauri::command]
pub async fn export_diagnostics(window:tauri::WebviewWindow)->Result<String,String> {
    require_window_label(&window,"export_diagnostics")?;
    if EXPORTING.swap(true,Ordering::AcqRel){return Err("诊断包正在生成，请稍候".into())}
    struct Guard;impl Drop for Guard{fn drop(&mut self){EXPORTING.store(false,Ordering::Release);}}
    let guard=Guard;
    run_blocking_command(move||{
        let _guard=guard;
        let configuration=Configuration::production();
        let folder=dirs::download_dir().unwrap_or_else(||configuration.home.join("Downloads"));
        let output=folder.join(format!("TokenBar-Diagnostics-{}.zip",uuid::Uuid::new_v4()));
        let exe=std::env::current_exe().map_err(|_|"无法定位独立采集入口")?;
        // The command never waits for the startup gate or a business lease.
        diagnostics::export_in_child(&output,&configuration,&exe)
            .map_err(|_|"导出失败，请使用独立诊断工具并选择可写的新文件位置".to_string())?;
        Ok(output.to_string_lossy().into_owned())
    }).await
}

#[tauri::command]
pub fn record_diagnostic_progress(window:tauri::WebviewWindow,completed:u64,total:u64,finished:bool,failed:bool)->Result<(),String> {
    require_window_label(&window,"record_diagnostic_progress")?;
    diagnostics::record(Area::UiProgress,if failed{Phase::Failed}else if finished{Phase::Completed}else{Phase::Progress},
        &[("completed",completed.min(i64::MAX as u64) as i64),("total",total.min(i64::MAX as u64) as i64)]);
    Ok(())
}
