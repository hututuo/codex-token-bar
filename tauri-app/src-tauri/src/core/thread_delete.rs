use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{ErrorKind, Read};
use std::net::TcpStream;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use tungstenite::client::IntoClientRequest;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{connect, Message, WebSocket};

const DEBUG_PORTS: [u16; 2] = [9229, 9222];
const BINDING_NAME: &str = "codexTokenBarDeleteTauri";
const OWNER: &str = "tauri";
const PROBE_INTERVAL: Duration = Duration::from_secs(3);
const READ_TIMEOUT: Duration = Duration::from_secs(1);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(4);
const REINJECT_INTERVAL: Duration = Duration::from_secs(5);
const DELETE_TIMEOUT: Duration = Duration::from_secs(20);
const INJECTION_TEMPLATE: &str =
    include_str!("../../../../Resources/CodexThreadDeleteInjection.js");
const SESSION_ENHANCEMENTS_TEMPLATE: &str =
    include_str!("../../../../Resources/CodexSessionEnhancementsInjection.js");

static STARTED: AtomicBool = AtomicBool::new(false);
static RECONNECT_REQUESTED: AtomicBool = AtomicBool::new(false);
static MESSAGE_ID: AtomicU64 = AtomicU64::new(100);
static STATUS: OnceLock<Mutex<ThreadDeleteBridgeStatus>> = OnceLock::new();

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadDeleteBridgeStatus {
    pub connected: bool,
    pub debug_port: Option<u16>,
    pub message: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CdpTarget {
    #[serde(rename = "type")]
    target_type: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    url: String,
    web_socket_debugger_url: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionEnhancementBindingRequest {
    id: String,
    owner: String,
    #[serde(default)]
    action: SessionEnhancementBindingAction,
    thread_id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    target_cwd: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum SessionEnhancementBindingAction {
    #[default]
    Delete,
    ExportMarkdown,
    MoveThreadWorkspace,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionEnhancementBindingResult {
    status: &'static str,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    filename: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    markdown: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    previous_cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    target_cwd: Option<String>,
}

pub fn start_supervisor() {
    if STARTED.swap(true, Ordering::AcqRel) {
        return;
    }
    set_status(false, None, "等待 Codex 调试连接（需以调试模式启动 Codex）");
    std::thread::spawn(supervisor_loop);
}

pub fn bridge_status() -> ThreadDeleteBridgeStatus {
    status_store()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .clone()
}

pub fn request_reconnect() -> ThreadDeleteBridgeStatus {
    RECONNECT_REQUESTED.store(true, Ordering::Release);
    let current = bridge_status();
    set_status(false, current.debug_port, "正在重新连接 Codex 会话增强");
    bridge_status()
}

pub fn enable_with_codex_restart() -> Result<ThreadDeleteBridgeStatus, String> {
    set_status(false, None, "正在重启 Codex 并启用会话增强");
    if let Err(error) = crate::platform::relaunch_codex_with_debug_port() {
        set_status(false, None, format!("启用 Codex 会话增强失败：{error}"));
        return Err(error);
    }
    RECONNECT_REQUESTED.store(true, Ordering::Release);
    set_status(false, Some(9229), "正在等待 Codex 调试连接");
    Ok(bridge_status())
}

fn supervisor_loop() {
    let client = match reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_millis(400))
        .timeout(Duration::from_secs(1))
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            set_status(false, None, format!("创建 Codex 调试客户端失败：{error}"));
            return;
        }
    };

    loop {
        RECONNECT_REQUESTED.store(false, Ordering::Release);
        let Some((port, websocket_url)) = find_target(&client) else {
            set_status(false, None, "等待 Codex 调试连接（需以调试模式启动 Codex）");
            wait_for_reconnect_or_timeout(PROBE_INTERVAL);
            continue;
        };
        let reconnecting = match run_cdp_session(port, &websocket_url) {
            Ok(SessionExit::Closed) => {
                set_status(false, None, "Codex 调试连接已关闭");
                false
            }
            Ok(SessionExit::Reconnect) => {
                set_status(false, Some(port), "正在重新连接 Codex 会话增强");
                true
            }
            Err(error) => {
                set_status(
                    false,
                    Some(port),
                    format!("Codex 会话增强连接中断：{error}"),
                );
                false
            }
        };
        if !reconnecting && !RECONNECT_REQUESTED.load(Ordering::Acquire) {
            wait_for_reconnect_or_timeout(PROBE_INTERVAL);
        }
    }
}

fn wait_for_reconnect_or_timeout(timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline && !RECONNECT_REQUESTED.load(Ordering::Acquire) {
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn find_target(client: &reqwest::blocking::Client) -> Option<(u16, String)> {
    for port in DEBUG_PORTS {
        let url = format!("http://127.0.0.1:{port}/json/list");
        let Ok(response) = client.get(url).send() else {
            continue;
        };
        let Ok(targets) = response.json::<Vec<CdpTarget>>() else {
            continue;
        };
        let target = targets.into_iter().find(|target| {
            target.target_type == "page"
                && !target.url.starts_with("devtools://")
                && target
                    .web_socket_debugger_url
                    .as_deref()
                    .is_some_and(is_loopback_websocket)
                && (target.url.starts_with("app://")
                    || target.title.to_ascii_lowercase().contains("codex")
                    || target.title.to_ascii_lowercase().contains("chatgpt"))
        });
        if let Some(websocket_url) = target.and_then(|target| target.web_socket_debugger_url) {
            return Some((port, websocket_url));
        }
    }
    None
}

fn is_loopback_websocket(url: &str) -> bool {
    let Ok(url) = reqwest::Url::parse(url) else {
        return false;
    };
    url.scheme() == "ws"
        && matches!(
            url.host_str(),
            Some("127.0.0.1" | "::1" | "[::1]" | "localhost")
        )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SessionExit {
    Closed,
    Reconnect,
}

fn run_cdp_session(port: u16, websocket_url: &str) -> Result<SessionExit, String> {
    if !is_loopback_websocket(websocket_url) {
        return Err("拒绝连接非本机 Codex 调试地址".into());
    }
    let request = websocket_url
        .into_client_request()
        .map_err(|error| error.to_string())?;
    let (mut socket, _) = connect(request).map_err(|error| error.to_string())?;
    set_read_timeout(&mut socket, READ_TIMEOUT)?;
    let health = install_bridge(&mut socket)?;
    publish_health_status(port, &health);
    let mut last_injection = Instant::now();

    loop {
        if RECONNECT_REQUESTED.swap(false, Ordering::AcqRel) {
            let _ = socket.close(None);
            return Ok(SessionExit::Reconnect);
        }
        if last_injection.elapsed() >= REINJECT_INTERVAL {
            send_command_and_wait(
                &mut socket,
                "Runtime.evaluate",
                json!({
                    "expression": rendered_injection_script()?,
                    "returnByValue": true,
                }),
            )?;
            let health = verify_injection_health(&mut socket)?;
            publish_health_status(port, &health);
            last_injection = Instant::now();
        }
        match socket.read() {
            Ok(Message::Text(text)) => handle_cdp_message(&mut socket, text.as_str())?,
            Ok(Message::Close(_)) => return Ok(SessionExit::Closed),
            Ok(Message::Ping(payload)) => socket
                .send(Message::Pong(payload))
                .map_err(|error| error.to_string())?,
            Ok(_) => {}
            Err(tungstenite::Error::Io(error))
                if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(error) => return Err(error.to_string()),
        }
    }
}

fn set_read_timeout(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    timeout: Duration,
) -> Result<(), String> {
    match socket.get_mut() {
        MaybeTlsStream::Plain(stream) => stream
            .set_read_timeout(Some(timeout))
            .map_err(|error| error.to_string()),
        _ => Err("Codex 调试连接不是本机明文 WebSocket".into()),
    }
}

fn install_bridge(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
) -> Result<InjectionHealth, String> {
    send_command_and_wait(socket, "Runtime.enable", json!({}))?;
    send_command_and_wait(
        socket,
        "Runtime.removeBinding",
        json!({ "name": BINDING_NAME }),
    )?;
    send_command_and_wait(
        socket,
        "Runtime.addBinding",
        json!({ "name": BINDING_NAME }),
    )?;
    let script = rendered_injection_script()?;
    send_command_and_wait(
        socket,
        "Page.addScriptToEvaluateOnNewDocument",
        json!({ "source": script }),
    )?;
    send_command_and_wait(
        socket,
        "Runtime.evaluate",
        json!({ "expression": script, "returnByValue": true }),
    )?;
    verify_injection_health(socket)
}

fn rendered_injection_script() -> Result<String, String> {
    let settings = crate::platform::read_app_settings()?.session_enhancements;
    Ok(rendered_injection_script_with_settings(&settings))
}

fn rendered_injection_script_with_settings(
    settings: &crate::models::SessionEnhancementSettingsSnapshot,
) -> String {
    let delete_script = INJECTION_TEMPLATE
        .replace(
            "__CTB_OWNER_JSON__",
            &serde_json::to_string(OWNER).expect("static owner serializes"),
        )
        .replace(
            "__CTB_BINDING_JSON__",
            &serde_json::to_string(BINDING_NAME).expect("static binding serializes"),
        );
    format!(
        "window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = {};\n{}\n{}",
        serde_json::to_string(settings).expect("session enhancement settings serialize"),
        delete_script,
        SESSION_ENHANCEMENTS_TEMPLATE,
    )
}

fn send_command_and_wait(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    method: &str,
    params: Value,
) -> Result<Value, String> {
    let id = send_command(socket, method, params)?;
    let deadline = Instant::now() + COMMAND_TIMEOUT;
    loop {
        if Instant::now() >= deadline {
            return Err(format!("等待 CDP 命令回执超时：{method}"));
        }
        match socket.read() {
            Ok(Message::Text(text)) => {
                let message: Value = serde_json::from_str(text.as_str())
                    .map_err(|error| format!("解析 CDP 回执失败：{error}"))?;
                if message.get("method").and_then(Value::as_str) == Some("Runtime.bindingCalled") {
                    handle_cdp_message(socket, text.as_str())?;
                    continue;
                }
                if message.get("id").and_then(Value::as_u64) != Some(id) {
                    continue;
                }
                if let Some(error) = message.get("error") {
                    return Err(format!("CDP 命令失败 {method}：{error}"));
                }
                let result = message.get("result").cloned().unwrap_or(Value::Null);
                if let Some(exception) = result.get("exceptionDetails") {
                    return Err(format!("CDP 页面执行失败 {method}：{exception}"));
                }
                return Ok(result);
            }
            Ok(Message::Ping(payload)) => socket
                .send(Message::Pong(payload))
                .map_err(|error| error.to_string())?,
            Ok(Message::Close(_)) => return Err(format!("等待 CDP 回执时连接关闭：{method}")),
            Ok(_) => {}
            Err(tungstenite::Error::Io(error))
                if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(error) => return Err(format!("读取 CDP 回执失败 {method}：{error}")),
        }
    }
}

fn send_command(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    method: &str,
    params: Value,
) -> Result<u64, String> {
    let id = MESSAGE_ID.fetch_add(1, Ordering::Relaxed) + 1;
    socket
        .send(Message::Text(
            json!({ "id": id, "method": method, "params": params })
                .to_string()
                .into(),
        ))
        .map_err(|error| error.to_string())?;
    Ok(id)
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct InjectionHealth {
    ready: bool,
    waiting_for_rows: bool,
    eligible_rows: u64,
    delete_buttons: u64,
    more_buttons: u64,
}

fn verify_injection_health(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
) -> Result<InjectionHealth, String> {
    let expression = format!(
        "(() => ({{ deleteHealth: window.__codexTokenBarThreadDeleteHealth?.({}, {}), sessionHealth: window.__codexTokenBarSessionEnhancementsHealth?.(), expectedSessionRuntimeVersion: window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS_RUNTIME_VERSION__ }}))()",
        serde_json::to_string(OWNER).expect("static owner serializes"),
        serde_json::to_string(BINDING_NAME).expect("static binding serializes"),
    );
    let result = send_command_and_wait(
        socket,
        "Runtime.evaluate",
        json!({ "expression": expression, "returnByValue": true }),
    )?;
    let value = result
        .pointer("/result/value")
        .ok_or_else(|| "CDP 会话增强健康检查没有返回页面值".to_string())?;
    parse_injection_health(value)
}

fn parse_injection_health(value: &Value) -> Result<InjectionHealth, String> {
    let delete = value
        .get("deleteHealth")
        .ok_or_else(|| "CDP 页面缺少删除桥健康结果".to_string())?;
    let session = value
        .get("sessionHealth")
        .ok_or_else(|| "CDP 页面缺少会话增强健康结果".to_string())?;
    let expected_runtime = value
        .get("expectedSessionRuntimeVersion")
        .and_then(Value::as_u64)
        .ok_or_else(|| "CDP 页面缺少会话增强运行时版本".to_string())?;
    let session_runtime = session
        .get("runtimeVersion")
        .and_then(Value::as_u64)
        .ok_or_else(|| "CDP 会话增强运行时没有版本".to_string())?;
    if session_runtime != expected_runtime {
        return Err(format!(
            "CDP 会话增强运行时版本不一致：{session_runtime} != {expected_runtime}"
        ));
    }
    if delete
        .get("sessionEnhancementsInstalled")
        .and_then(Value::as_bool)
        != Some(true)
    {
        return Err(format!("CDP 删除桥未确认会话增强：{delete}"));
    }
    let readiness = delete
        .get("readiness")
        .and_then(Value::as_str)
        .unwrap_or("failed");
    if !matches!(readiness, "ready" | "waitingForRows") {
        return Err(format!("CDP 页面会话增强结构校验失败：{delete}"));
    }
    let eligible_rows = delete
        .get("eligibleRowCount")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let delete_buttons = delete
        .get("buttonCount")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let more_buttons = session
        .get("moreButtonCount")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let session_settings = session.get("settings").unwrap_or(&Value::Null);
    let expects_more = session_settings
        .get("markdownExport")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || session_settings
            .get("projectMove")
            .and_then(Value::as_bool)
            .unwrap_or(false);
    if readiness == "ready" && eligible_rows > 0 {
        let expected_more = if expects_more { eligible_rows } else { 0 };
        if more_buttons != expected_more {
            return Err(format!(
                "CDP 会话更多按钮数量不一致：{more_buttons} != {expected_more}"
            ));
        }
    }
    Ok(InjectionHealth {
        ready: readiness == "ready",
        waiting_for_rows: readiness == "waitingForRows",
        eligible_rows,
        delete_buttons,
        more_buttons,
    })
}

fn publish_health_status(port: u16, health: &InjectionHealth) {
    if health.ready {
        set_status(
            true,
            Some(port),
            format!(
                "Codex 会话增强已连接，已验证 {} 个会话、{} 个删除入口、{} 个管理入口",
                health.eligible_rows, health.delete_buttons, health.more_buttons
            ),
        );
    } else if health.waiting_for_rows {
        set_status(false, Some(port), "Codex 会话增强已加载，等待会话列表");
    } else {
        set_status(false, Some(port), "Codex 会话增强页面校验未就绪");
    }
}

fn handle_cdp_message(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    text: &str,
) -> Result<(), String> {
    let message: Value = serde_json::from_str(text).map_err(|error| error.to_string())?;
    if message.get("method").and_then(Value::as_str) != Some("Runtime.bindingCalled") {
        return Ok(());
    }
    if message.pointer("/params/name").and_then(Value::as_str) != Some(BINDING_NAME) {
        return Ok(());
    }
    let Some(payload) = message
        .get("params")
        .and_then(|params| params.get("payload"))
        .and_then(Value::as_str)
    else {
        return Ok(());
    };
    let request: SessionEnhancementBindingRequest = match serde_json::from_str(payload) {
        Ok(request) => request,
        Err(error) => return Err(format!("会话增强请求格式错误：{error}")),
    };
    if request.owner != OWNER {
        return Ok(());
    }
    let result = session_enhancement_result(&request);
    let expression = resolve_expression(&request.owner, &request.id, &result)?;
    let context_id = message
        .pointer("/params/executionContextId")
        .and_then(Value::as_u64);
    let mut params = json!({ "expression": expression });
    if let Some(context_id) = context_id {
        params["contextId"] = json!(context_id);
    }
    send_command(socket, "Runtime.evaluate", params).map(|_| ())
}

fn resolve_expression(
    owner: &str,
    request_id: &str,
    result: &SessionEnhancementBindingResult,
) -> Result<String, String> {
    Ok(format!(
        "window.__codexTokenBarThreadDeleteResolve({}, {}, {})",
        serde_json::to_string(owner).map_err(|error| error.to_string())?,
        serde_json::to_string(request_id).map_err(|error| error.to_string())?,
        serde_json::to_string(result).map_err(|error| error.to_string())?,
    ))
}

fn session_enhancement_result(
    request: &SessionEnhancementBindingRequest,
) -> SessionEnhancementBindingResult {
    let result = (|| {
        let settings = crate::platform::read_app_settings()?.session_enhancements;
        let codex_home = crate::platform::default_codex_home();
        match request.action {
            SessionEnhancementBindingAction::Delete => {
                if !settings.session_delete {
                    return Err("会话删除未启用".into());
                }
                delete_thread(&request.thread_id).map(|message| SessionEnhancementBindingResult {
                    status: "deleted",
                    message,
                    filename: None,
                    markdown: None,
                    previous_cwd: None,
                    target_cwd: None,
                })
            }
            SessionEnhancementBindingAction::ExportMarkdown => {
                if !settings.markdown_export {
                    return Err("Markdown 导出未启用".into());
                }
                crate::core::session_enhancements::export_markdown(
                    &codex_home,
                    &request.thread_id,
                    &request.title,
                )
                .map(|result| SessionEnhancementBindingResult {
                    status: "exported",
                    message: result.message,
                    filename: Some(result.filename),
                    markdown: Some(result.markdown),
                    previous_cwd: None,
                    target_cwd: None,
                })
            }
            SessionEnhancementBindingAction::MoveThreadWorkspace => {
                if !settings.project_move {
                    return Err("会话项目移动未启用".into());
                }
                let target = request
                    .target_cwd
                    .as_deref()
                    .map(str::trim)
                    .filter(|target| !target.is_empty())
                    .ok_or_else(|| "目标项目目录不能为空".to_string())?;
                crate::core::session_enhancements::move_thread_workspace(
                    &codex_home,
                    &request.thread_id,
                    target,
                )
                .map(|result| SessionEnhancementBindingResult {
                    status: "moved",
                    message: result.message,
                    filename: None,
                    markdown: None,
                    previous_cwd: Some(result.previous_cwd),
                    target_cwd: Some(result.target_cwd),
                })
            }
        }
    })();
    result.unwrap_or_else(|message| SessionEnhancementBindingResult {
        status: "failed",
        message,
        filename: None,
        markdown: None,
        previous_cwd: None,
        target_cwd: None,
    })
}

fn delete_thread(thread_id: &str) -> Result<String, String> {
    if !is_uuid(thread_id) {
        return Err("会话 ID 不是有效 UUID".into());
    }
    let codex = crate::core::quota::codex_binary::find_codex_binary_with_report()?.path;
    run_delete_command(
        &codex,
        &crate::platform::default_codex_home(),
        thread_id,
        DELETE_TIMEOUT,
    )
}

fn run_delete_command(
    codex: &std::path::Path,
    codex_home: &std::path::Path,
    thread_id: &str,
    timeout: Duration,
) -> Result<String, String> {
    let mut child = Command::new(codex)
        .args(delete_command_args(thread_id))
        .env("CODEX_HOME", codex_home)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("启动 Codex 删除命令失败：{error}"))?;
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(25));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("Codex 删除命令超时".into());
            }
            Err(error) => return Err(format!("等待 Codex 删除命令失败：{error}")),
        }
    };
    let stdout = read_pipe(child.stdout.take());
    let stderr = read_pipe(child.stderr.take());
    if status.success() {
        let message = stdout.trim();
        return Ok(if message.is_empty() {
            "会话已永久删除".into()
        } else {
            message.to_string()
        });
    }
    let detail = if stderr.trim().is_empty() {
        stdout
    } else {
        stderr
    };
    Err(format!("Codex 删除失败：{}", detail.trim()))
}

fn read_pipe(pipe: Option<impl Read>) -> String {
    let Some(mut pipe) = pipe else {
        return String::new();
    };
    let mut bytes = Vec::new();
    let _ = pipe.read_to_end(&mut bytes);
    String::from_utf8_lossy(&bytes).into_owned()
}

fn delete_command_args(thread_id: &str) -> [&str; 3] {
    ["delete", "--force", thread_id]
}

fn is_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 36 {
        return false;
    }
    for (index, byte) in bytes.iter().copied().enumerate() {
        if matches!(index, 8 | 13 | 18 | 23) {
            if byte != b'-' {
                return false;
            }
        } else if !byte.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

fn status_store() -> &'static Mutex<ThreadDeleteBridgeStatus> {
    STATUS.get_or_init(|| {
        Mutex::new(ThreadDeleteBridgeStatus {
            connected: false,
            debug_port: None,
            message: "尚未启动".into(),
        })
    })
}

fn set_status(connected: bool, debug_port: Option<u16>, message: impl Into<String>) {
    *status_store()
        .lock()
        .unwrap_or_else(|error| error.into_inner()) = ThreadDeleteBridgeStatus {
        connected,
        debug_port,
        message: message.into(),
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn injection_template_is_rendered_for_the_tauri_owner() {
        let script = rendered_injection_script_with_settings(
            &crate::models::SessionEnhancementSettingsSnapshot::default(),
        );
        assert!(script.contains("const owner = \"tauri\";"));
        assert!(script.contains("const bindingName = \"codexTokenBarDeleteTauri\";"));
        assert!(script.contains("__codexTokenBarSessionEnhancementsHealth"));
        assert!(script.contains("\"markdownExport\":true"));
        assert!(!script.contains("__CTB_OWNER_JSON__"));
        assert!(!script.contains("__CTB_BINDING_JSON__"));
    }

    #[test]
    fn binding_request_supports_every_session_enhancement_action() {
        let export: SessionEnhancementBindingRequest = serde_json::from_str(
            r#"{"id":"1","owner":"tauri","action":"exportMarkdown","threadId":"019f5a7c-1234-7abc-8def-0123456789ab","title":"测试"}"#,
        )
        .unwrap();
        let moved: SessionEnhancementBindingRequest = serde_json::from_str(
            r#"{"id":"2","owner":"tauri","action":"moveThreadWorkspace","threadId":"019f5a7c-1234-7abc-8def-0123456789ab","targetCwd":"/tmp/project"}"#,
        )
        .unwrap();
        assert_eq!(
            export.action,
            SessionEnhancementBindingAction::ExportMarkdown
        );
        assert_eq!(
            moved.action,
            SessionEnhancementBindingAction::MoveThreadWorkspace
        );
        assert_eq!(moved.target_cwd.as_deref(), Some("/tmp/project"));
    }

    #[test]
    fn combined_page_health_requires_matching_runtime_and_more_button_counts() {
        let value = json!({
            "expectedSessionRuntimeVersion": 3,
            "deleteHealth": {
                "readiness": "ready",
                "sessionEnhancementsInstalled": true,
                "eligibleRowCount": 2,
                "buttonCount": 2
            },
            "sessionHealth": {
                "runtimeVersion": 3,
                "moreButtonCount": 2,
                "settings": { "markdownExport": true, "projectMove": true }
            }
        });
        assert_eq!(
            parse_injection_health(&value).unwrap(),
            InjectionHealth {
                ready: true,
                waiting_for_rows: false,
                eligible_rows: 2,
                delete_buttons: 2,
                more_buttons: 2,
            }
        );

        let mut stale = value.clone();
        stale["sessionHealth"]["runtimeVersion"] = json!(2);
        assert!(parse_injection_health(&stale)
            .unwrap_err()
            .contains("版本不一致"));

        let mut missing = value;
        missing["sessionHealth"]["moreButtonCount"] = json!(1);
        assert!(parse_injection_health(&missing)
            .unwrap_err()
            .contains("数量不一致"));
    }

    #[test]
    fn delete_request_accepts_only_uuid_thread_ids() {
        assert!(is_uuid("019f5a7c-1234-7abc-8def-0123456789ab"));
        assert!(is_uuid("019F5A7C-1234-7ABC-8DEF-0123456789AB"));
        assert!(!is_uuid("thr_019f5a7c"));
        assert!(!is_uuid("019f5a7c-1234-7abc-8def-0123456789ab;rm"));
    }

    #[test]
    fn official_delete_command_uses_positional_arguments_without_a_shell() {
        assert_eq!(
            delete_command_args("019f5a7c-1234-7abc-8def-0123456789ab"),
            ["delete", "--force", "019f5a7c-1234-7abc-8def-0123456789ab"]
        );
    }

    #[test]
    fn cdp_target_must_stay_on_loopback() {
        assert!(is_loopback_websocket("ws://127.0.0.1:9229/devtools/page/1"));
        assert!(is_loopback_websocket("ws://[::1]:9229/devtools/page/1"));
        assert!(!is_loopback_websocket(
            "ws://127.0.0.1:9229@evil.example/devtools/page/1"
        ));
        assert!(!is_loopback_websocket(
            "ws://192.168.1.10:9229/devtools/page/1"
        ));
        assert!(!is_loopback_websocket("wss://example.com/devtools/page/1"));
    }
}
