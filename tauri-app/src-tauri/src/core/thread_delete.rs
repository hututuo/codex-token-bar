use crate::core::process_tail::ProcessPipeTail;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::io::ErrorKind;
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
const PIPE_TAIL_LIMIT_BYTES: usize = 64 * 1024;
const PIPE_DRAIN_GRACE: Duration = Duration::from_millis(500);
const MARKDOWN_TRANSFER_CHUNK_BYTES: usize = 64 * 1024;
// 分块 ACK 等待页面把数据真实写入用户选择的文件（awaitPromise 背压），慢盘可能
// 远超普通 CDP 回执，因此使用独立的宽超时；页面侧每收到一块会刷新自身超时。
const MARKDOWN_CHUNK_ACK_TIMEOUT: Duration = Duration::from_secs(60);
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
    markdown_transfer: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    markdown_chunk_count: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    previous_cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    target_cwd: Option<String>,
}

pub fn start_supervisor() {
    if STARTED
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return;
    }
    set_status(false, None, "等待 Codex 调试连接（需以调试模式启动 Codex）");
    if let Err(error) = std::thread::Builder::new()
        .name("codex-token-bar-thread-delete".into())
        .spawn(|| {
            let _owner = SupervisorStartedOwner;
            let mut bootstrap_registrations = HashMap::new();
            loop {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    supervisor_loop(&mut bootstrap_registrations)
                }));
                if outcome.is_err() {
                    set_status(false, None, "Codex 会话增强监督器异常，正在自动恢复");
                    eprintln!(
                        "Codex Token Bar: thread-delete supervisor recovered after panic"
                    );
                }
                wait_for_reconnect_or_timeout(PROBE_INTERVAL);
            }
        })
    {
        STARTED.store(false, Ordering::Release);
        set_status(
            false,
            None,
            format!("启动 Codex 会话增强监督器失败：{error}"),
        );
    }
}

pub fn bridge_status() -> ThreadDeleteBridgeStatus {
    status_store()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .clone()
}

pub fn request_reconnect() -> ThreadDeleteBridgeStatus {
    start_supervisor();
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
    start_supervisor();
    RECONNECT_REQUESTED.store(true, Ordering::Release);
    set_status(false, Some(9229), "正在等待 Codex 调试连接");
    Ok(bridge_status())
}

struct SupervisorStartedOwner;

impl Drop for SupervisorStartedOwner {
    fn drop(&mut self) {
        STARTED.store(false, Ordering::Release);
    }
}

fn supervisor_loop(
    bootstrap_registrations: &mut HashMap<String, BootstrapScriptRegistration>,
) {
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
        let reconnecting = match run_cdp_session(
            port,
            &websocket_url,
            bootstrap_registrations,
        ) {
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

#[derive(Clone, Debug, PartialEq, Eq)]
struct BootstrapScriptRegistration {
    identifier: String,
}

fn run_cdp_session(
    port: u16,
    websocket_url: &str,
    bootstrap_registrations: &mut HashMap<String, BootstrapScriptRegistration>,
) -> Result<SessionExit, String> {
    if !is_loopback_websocket(websocket_url) {
        return Err("拒绝连接非本机 Codex 调试地址".into());
    }
    let request = websocket_url
        .into_client_request()
        .map_err(|error| error.to_string())?;
    let (mut socket, _) = connect(request).map_err(|error| error.to_string())?;
    set_read_timeout(&mut socket, READ_TIMEOUT)?;
    let mut pending_bindings = VecDeque::new();
    let health = install_bridge(
        &mut socket,
        websocket_url,
        bootstrap_registrations,
        &mut pending_bindings,
    )?;
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
                &mut pending_bindings,
            )?;
            let health = verify_injection_health(
                &mut socket,
                &mut pending_bindings,
            )?;
            publish_health_status(port, &health);
            last_injection = Instant::now();
        }
        if let Some(text) = pending_bindings.pop_front() {
            handle_cdp_message(
                &mut socket,
                &text,
                &mut pending_bindings,
            )?;
            continue;
        }
        match socket.read() {
            Ok(Message::Text(text)) => handle_cdp_message(
                &mut socket,
                text.as_str(),
                &mut pending_bindings,
            )?,
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
    websocket_url: &str,
    bootstrap_registrations: &mut HashMap<String, BootstrapScriptRegistration>,
    pending_bindings: &mut VecDeque<String>,
) -> Result<InjectionHealth, String> {
    send_command_and_wait(
        socket,
        "Runtime.enable",
        json!({}),
        pending_bindings,
    )?;
    send_command_and_wait(
        socket,
        "Runtime.removeBinding",
        json!({ "name": BINDING_NAME }),
        pending_bindings,
    )?;
    send_command_and_wait(
        socket,
        "Runtime.addBinding",
        json!({ "name": BINDING_NAME }),
        pending_bindings,
    )?;
    let script = rendered_injection_script()?;
    if let Some(previous) = bootstrap_registrations.get(websocket_url) {
        send_command_and_wait(
            socket,
            "Page.removeScriptToEvaluateOnNewDocument",
            json!({ "identifier": previous.identifier }),
            pending_bindings,
        )?;
        bootstrap_registrations.remove(websocket_url);
    }
    let registration = send_command_and_wait(
        socket,
        "Page.addScriptToEvaluateOnNewDocument",
        json!({ "source": script }),
        pending_bindings,
    )?;
    let identifier = registration
        .get("identifier")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            "Page.addScriptToEvaluateOnNewDocument 未返回脚本标识".to_string()
        })?;
    bootstrap_registrations.insert(
        websocket_url.to_string(),
        BootstrapScriptRegistration {
            identifier: identifier.to_string(),
        },
    );
    send_command_and_wait(
        socket,
        "Runtime.evaluate",
        json!({ "expression": script, "returnByValue": true }),
        pending_bindings,
    )?;
    let cleanup = send_command_and_wait(
        socket,
        "Runtime.evaluate",
        json!({
            "expression": abort_orphan_transfers_expression(OWNER)?,
            "returnByValue": true,
        }),
        pending_bindings,
    )?;
    require_page_ack(&cleanup, "清理重连前遗留 Markdown 传输")?;
    verify_injection_health(socket, pending_bindings)
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
    pending_bindings: &mut VecDeque<String>,
) -> Result<Value, String> {
    send_command_and_wait_with_timeout(
        socket,
        method,
        params,
        pending_bindings,
        COMMAND_TIMEOUT,
    )
}

fn send_command_and_wait_with_timeout(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    method: &str,
    params: Value,
    pending_bindings: &mut VecDeque<String>,
    timeout: Duration,
) -> Result<Value, String> {
    let id = send_command(socket, method, params)?;
    let deadline = Instant::now() + timeout;
    loop {
        if Instant::now() >= deadline {
            return Err(format!("等待 CDP 命令回执超时：{method}"));
        }
        match socket.read() {
            Ok(Message::Text(text)) => {
                let message: Value = serde_json::from_str(text.as_str())
                    .map_err(|error| format!("解析 CDP 回执失败：{error}"))?;
                if message.get("method").and_then(Value::as_str) == Some("Runtime.bindingCalled") {
                    pending_bindings.push_back(text.to_string());
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
    pending_bindings: &mut VecDeque<String>,
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
        pending_bindings,
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
    pending_bindings: &mut VecDeque<String>,
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
        Err(error) => {
            // 单个畸形请求不应拆毁整条 CDP 会话（会殃及页面上所有挂起回调），
            // 记录后忽略即可；页面侧对应回调由其自身超时收敛。
            eprintln!("Codex Token Bar: 会话增强请求格式错误，已忽略：{error}");
            return Ok(());
        }
    };
    if request.owner != OWNER {
        return Ok(());
    }
    let context_id = message
        .pointer("/params/executionContextId")
        .and_then(Value::as_u64);
    let result = match request.action {
        SessionEnhancementBindingAction::ExportMarkdown => {
            run_markdown_export(socket, &request, context_id, pending_bindings)
        }
        _ => session_enhancement_result(&request),
    };
    deliver_binding_result(
        socket,
        &request.owner,
        &request.id,
        result,
        context_id,
        pending_bindings,
    )
}

fn run_markdown_export(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    request: &SessionEnhancementBindingRequest,
    context_id: Option<u64>,
    pending_bindings: &mut VecDeque<String>,
) -> SessionEnhancementBindingResult {
    let settings = match crate::platform::read_app_settings() {
        Ok(settings) => settings.session_enhancements,
        Err(message) => return failed_binding_result(message),
    };
    if !settings.markdown_export {
        return failed_binding_result("Markdown 导出未启用".into());
    }
    let codex_home = crate::platform::default_codex_home();
    let mut evaluator = SocketCdpEvaluator {
        socket,
        pending_bindings,
    };
    let mut transfer =
        MarkdownCdpTransfer::new(&mut evaluator, OWNER, &request.id, context_id);
    let export = crate::core::session_enhancements::export_markdown(
        &codex_home,
        &request.thread_id,
        &request.title,
        &mut |fragment| transfer.write(fragment),
    );
    match export {
        Ok(result) => match transfer.finish() {
            Ok(chunk_count) => SessionEnhancementBindingResult {
                status: "exported",
                message: result.message,
                filename: Some(result.filename),
                markdown_transfer: Some(true),
                markdown_chunk_count: Some(chunk_count),
                previous_cwd: None,
                target_cwd: None,
            },
            Err(message) => failed_binding_result(message),
        },
        Err(message) => failed_binding_result(message),
    }
}

fn failed_binding_result(message: String) -> SessionEnhancementBindingResult {
    SessionEnhancementBindingResult {
        status: "failed",
        message,
        filename: None,
        markdown_transfer: None,
        markdown_chunk_count: None,
        previous_cwd: None,
        target_cwd: None,
    }
}

fn deliver_binding_result(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    owner: &str,
    request_id: &str,
    result: SessionEnhancementBindingResult,
    context_id: Option<u64>,
    pending_bindings: &mut VecDeque<String>,
) -> Result<(), String> {
    let expression = resolve_expression(owner, request_id, &result)?;
    let response = send_command_and_wait(
        socket,
        "Runtime.evaluate",
        runtime_evaluate_params(expression, context_id, false),
        pending_bindings,
    )?;
    if response.pointer("/result/value").and_then(Value::as_bool) != Some(true) {
        // 页面明确返回 false 表示对应回调已不存在（页面刷新、请求已超时或
        // 已被乱序分块判失败）。这是陈旧回执，不是传输故障；拆毁会话重连
        // 会殃及同页面其他挂起请求，因此只记录不上抛。
        eprintln!(
            "Codex Token Bar: 会话增强结果未被页面接收（回执可能已过期）：{request_id}"
        );
    }
    Ok(())
}

fn runtime_evaluate_params(
    expression: String,
    context_id: Option<u64>,
    await_promise: bool,
) -> Value {
    let mut params = json!({
        "expression": expression,
        "returnByValue": true,
    });
    if await_promise {
        params["awaitPromise"] = json!(true);
    }
    if let Some(context_id) = context_id {
        params["contextId"] = json!(context_id);
    }
    params
}

trait CdpEvaluator {
    fn evaluate(&mut self, params: Value) -> Result<Value, String>;
}

struct SocketCdpEvaluator<'a> {
    socket: &'a mut WebSocket<MaybeTlsStream<TcpStream>>,
    pending_bindings: &'a mut VecDeque<String>,
}

impl CdpEvaluator for SocketCdpEvaluator<'_> {
    fn evaluate(&mut self, params: Value) -> Result<Value, String> {
        send_command_and_wait_with_timeout(
            self.socket,
            "Runtime.evaluate",
            params,
            self.pending_bindings,
            MARKDOWN_CHUNK_ACK_TIMEOUT,
        )
    }
}

/// 把渲染层 emit 的 Markdown 片段聚合成有界分块，经 CDP `Runtime.evaluate`
/// （`awaitPromise:true`）逐块推给页面，并等待页面写入文件后的显式 `true` ACK
/// 才继续下一块——形成端到端背压。任一块失败即返回错误，调用方以 failed
/// resolve 通知页面 abort writer。整个过程中工作集只有一个未满的缓冲块。
struct MarkdownCdpTransfer<'a, E: CdpEvaluator> {
    evaluator: &'a mut E,
    owner: &'a str,
    request_id: &'a str,
    context_id: Option<u64>,
    buffer: String,
    chunk_count: usize,
}

impl<'a, E: CdpEvaluator> MarkdownCdpTransfer<'a, E> {
    fn new(
        evaluator: &'a mut E,
        owner: &'a str,
        request_id: &'a str,
        context_id: Option<u64>,
    ) -> Self {
        Self {
            evaluator,
            owner,
            request_id,
            context_id,
            buffer: String::new(),
            chunk_count: 0,
        }
    }

    fn write(&mut self, fragment: &str) -> Result<(), String> {
        self.buffer.push_str(fragment);
        while self.buffer.len() >= MARKDOWN_TRANSFER_CHUNK_BYTES {
            self.flush_chunk()?;
        }
        Ok(())
    }

    fn flush_chunk(&mut self) -> Result<(), String> {
        let mut end = MARKDOWN_TRANSFER_CHUNK_BYTES.min(self.buffer.len());
        while end > 0 && !self.buffer.is_char_boundary(end) {
            end -= 1;
        }
        debug_assert!(end > 0);
        let expression = markdown_chunk_expression(
            self.owner,
            self.request_id,
            self.chunk_count,
            &self.buffer[..end],
        )?;
        let response = self.evaluator.evaluate(runtime_evaluate_params(
            expression,
            self.context_id,
            true,
        ))?;
        require_page_ack(
            &response,
            &format!("Markdown 分块 {}", self.chunk_count),
        )?;
        self.chunk_count += 1;
        self.buffer.drain(..end);
        Ok(())
    }

    fn finish(mut self) -> Result<usize, String> {
        while !self.buffer.is_empty() {
            self.flush_chunk()?;
        }
        Ok(self.chunk_count)
    }
}

fn require_page_ack(result: &Value, operation: &str) -> Result<(), String> {
    if result.pointer("/result/value").and_then(Value::as_bool) == Some(true) {
        Ok(())
    } else {
        Err(format!("{operation}未被页面接收"))
    }
}

fn markdown_chunk_expression(
    owner: &str,
    request_id: &str,
    sequence: usize,
    chunk: &str,
) -> Result<String, String> {
    Ok(format!(
        "window.__codexTokenBarThreadDeleteMarkdownChunk({}, {}, {}, {})",
        serde_json::to_string(owner).map_err(|error| error.to_string())?,
        serde_json::to_string(request_id).map_err(|error| error.to_string())?,
        sequence,
        serde_json::to_string(chunk).map_err(|error| error.to_string())?,
    ))
}

fn abort_orphan_transfers_expression(owner: &str) -> Result<String, String> {
    let owner = serde_json::to_string(owner).map_err(|error| error.to_string())?;
    Ok(
        r#"(() => {
  const owner = __CTB_OWNER__;
  const state = window.__codexTokenBarThreadDeleteState;
  if (!state?.markdownTransfers) return true;
  const bridge = state.bridges?.get?.(owner);
  const prefix = owner + "\u0000";
  for (const [key, transfer] of [...state.markdownTransfers.entries()]) {
    if (!key.startsWith(prefix)) continue;
    state.markdownTransfers.delete(key);
    try {
      void Promise.resolve(transfer.sink?.abort?.()).catch(() => {});
    } catch {}
    bridge?.callbacks?.get?.(key.slice(prefix.length))
      ?.resolve?.({ status: "failed", message: "会话增强桥已重连，导出中止" });
  }
  return true;
})()"#
            .replace("__CTB_OWNER__", &owner),
    )
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
                if let Some(block) = multi_instance_mutation_guard() {
                    return Err(block);
                }
                delete_thread(&request.thread_id).map(|message| SessionEnhancementBindingResult {
                    status: "deleted",
                    message,
                    filename: None,
                    markdown_transfer: None,
                    markdown_chunk_count: None,
                    previous_cwd: None,
                    target_cwd: None,
                })
            }
            SessionEnhancementBindingAction::ExportMarkdown => {
                // 导出走 run_markdown_export 的流式路径；此分支只作为防御。
                Err("内部错误：Markdown 导出未走流式路径".into())
            }
            SessionEnhancementBindingAction::MoveThreadWorkspace => {
                if !settings.project_move {
                    return Err("会话项目移动未启用".into());
                }
                if let Some(block) = multi_instance_mutation_guard() {
                    return Err(block);
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
                    markdown_transfer: None,
                    markdown_chunk_count: None,
                    previous_cwd: Some(result.previous_cwd),
                    target_cwd: Some(result.target_cwd),
                })
            }
        }
    })();
    result.unwrap_or_else(failed_binding_result)
}

/// 多实例强校验：CDP 注入按钮发起的删除/移动作用于 Token Bar 选定的
/// CODEX_HOME，而点击按钮的窗口可能属于另一个 Codex Home。复用跨平台
/// 实例引擎的进程身份、Electron user-data marker 与 fail-closed 状态，
/// 不再由本模块维护一套 macOS-only 的字符串进程表。只有默认实例运行，
/// 或所有非默认实例均能证明已停止时，才允许继续。
fn multi_instance_mutation_guard() -> Option<String> {
    multi_instance_runtime_block(crate::core::codex_instances::list_instance_runtime_statuses())
}

fn multi_instance_runtime_block(
    statuses: Result<Vec<crate::models::CodexInstanceRuntimeStatus>, String>,
) -> Option<String> {
    let statuses = match statuses {
        Ok(statuses) => statuses,
        Err(error) => {
            return Some(format!(
                "无法确认 Codex 多实例状态，删除/移动已暂停以避免作用到错误的 Codex 目录：{error}"
            ))
        }
    };
    statuses
        .into_iter()
        .find(|status| status.id != "default" && status.running)
        .map(|status| {
            format!(
                "检测到非默认 Codex 实例正在运行，删除/移动已暂停：多实例下同一线程 ID 可能属于不同 Codex 目录。{}",
                status.message
            )
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
    let stdout = ProcessPipeTail::spawn(
        child.stdout.take(),
        PIPE_TAIL_LIMIT_BYTES,
        PIPE_DRAIN_GRACE,
    );
    let stderr = ProcessPipeTail::spawn(
        child.stderr.take(),
        PIPE_TAIL_LIMIT_BYTES,
        PIPE_DRAIN_GRACE,
    );
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(25));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                break Err("Codex 删除命令超时".to_string());
            }
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                break Err(format!("等待 Codex 删除命令失败：{error}"));
            }
        }
    };
    let stdout = stdout.finish();
    let stderr = stderr.finish();
    let status = status.map_err(|error| {
        let detail = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        if detail.is_empty() {
            error
        } else {
            format!("{error}：{detail}")
        }
    })?;
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

    fn runtime_status(
        id: &str,
        running: bool,
    ) -> crate::models::CodexInstanceRuntimeStatus {
        crate::models::CodexInstanceRuntimeStatus {
            id: id.into(),
            running,
            controlled: id != "default",
            pid: running.then_some(42),
            message: format!("{id}:{running}"),
        }
    }

    #[test]
    fn default_instance_alone_does_not_block_session_mutations() {
        assert_eq!(
            multi_instance_runtime_block(Ok(vec![runtime_status("default", true)])),
            None
        );
    }

    #[test]
    fn active_non_default_instance_blocks_session_mutations_on_every_platform() {
        let block = multi_instance_runtime_block(Ok(vec![
            runtime_status("default", true),
            runtime_status("clone-a", true),
        ]))
        .expect("非默认实例运行时必须拒绝删除/移动");
        assert!(block.contains("非默认"), "拒绝信息应说明实例边界：{block}");
        assert!(block.contains("clone-a:true"), "拒绝信息应保留诊断：{block}");
    }

    #[test]
    fn stopped_non_default_instances_allow_session_mutations() {
        assert_eq!(
            multi_instance_runtime_block(Ok(vec![
                runtime_status("default", true),
                runtime_status("clone-a", false),
            ])),
            None
        );
    }

    #[test]
    fn unreadable_instance_state_blocks_session_mutations() {
        let block = multi_instance_runtime_block(Err("registry corrupt".into()))
            .expect("状态不可证明时必须 fail closed");
        assert!(block.contains("registry corrupt"));
    }

    struct MockEvaluator {
        responses: Vec<Result<Value, String>>,
        calls: Vec<Value>,
    }

    impl MockEvaluator {
        fn acking_all() -> Self {
            Self {
                responses: Vec::new(),
                calls: Vec::new(),
            }
        }

        fn with_responses(responses: Vec<Result<Value, String>>) -> Self {
            Self {
                responses,
                calls: Vec::new(),
            }
        }

        fn chunks(&self) -> Vec<String> {
            self.calls
                .iter()
                .map(|params| {
                    let expression = params
                        .get("expression")
                        .and_then(Value::as_str)
                        .expect("chunk expression");
                    let arguments = expression
                        .strip_prefix("window.__codexTokenBarThreadDeleteMarkdownChunk(")
                        .and_then(|rest| rest.strip_suffix(')'))
                        .expect("chunk call shape");
                    let parsed: Value =
                        serde_json::from_str(&format!("[{arguments}]")).expect("chunk args");
                    parsed[3].as_str().expect("chunk text").to_string()
                })
                .collect()
        }
    }

    impl CdpEvaluator for MockEvaluator {
        fn evaluate(&mut self, params: Value) -> Result<Value, String> {
            let index = self.calls.len();
            self.calls.push(params);
            if index < self.responses.len() {
                self.responses[index].clone()
            } else {
                Ok(json!({"result": {"value": true}}))
            }
        }
    }

    #[test]
    fn markdown_transfer_streams_bounded_unicode_chunks_with_await_promise() {
        let markdown = format!(
            "{}中文🙂{}",
            "a".repeat(MARKDOWN_TRANSFER_CHUNK_BYTES - 2),
            "b".repeat(MARKDOWN_TRANSFER_CHUNK_BYTES + 9)
        );
        let mut evaluator = MockEvaluator::acking_all();
        let mut transfer =
            MarkdownCdpTransfer::new(&mut evaluator, "tauri", "request", Some(7));
        // 以小片段跨块边界写入，模拟渲染层逐段 emit。
        for fragment in [
            &markdown[..MARKDOWN_TRANSFER_CHUNK_BYTES - 2],
            &markdown[MARKDOWN_TRANSFER_CHUNK_BYTES - 2..],
        ] {
            transfer.write(fragment).unwrap();
        }
        let chunk_count = transfer.finish().unwrap();

        assert!(chunk_count >= 3);
        assert_eq!(evaluator.calls.len(), chunk_count);
        for params in &evaluator.calls {
            assert_eq!(params.get("awaitPromise"), Some(&json!(true)));
            assert_eq!(params.get("contextId"), Some(&json!(7)));
            let expression = params
                .get("expression")
                .and_then(Value::as_str)
                .unwrap();
            assert!(expression
                .starts_with("window.__codexTokenBarThreadDeleteMarkdownChunk(\"tauri\""));
            assert!(expression.len() < MARKDOWN_TRANSFER_CHUNK_BYTES + 256);
        }
        let chunks = evaluator.chunks();
        assert_eq!(chunks.concat(), markdown);
        assert!(chunks
            .iter()
            .all(|chunk| chunk.len() <= MARKDOWN_TRANSFER_CHUNK_BYTES));
    }

    #[test]
    fn markdown_transfer_keeps_buffer_bounded_while_streaming() {
        let mut evaluator = MockEvaluator::acking_all();
        let mut transfer =
            MarkdownCdpTransfer::new(&mut evaluator, "tauri", "request", None);
        for _ in 0..64 {
            transfer.write(&"x".repeat(MARKDOWN_TRANSFER_CHUNK_BYTES / 4)).unwrap();
            assert!(transfer.buffer.len() < MARKDOWN_TRANSFER_CHUNK_BYTES);
        }
        let chunk_count = transfer.finish().unwrap();
        assert_eq!(chunk_count, 16);
    }

    #[test]
    fn markdown_transfer_stops_sending_after_a_rejected_chunk() {
        let mut evaluator = MockEvaluator::with_responses(vec![
            Ok(json!({"result": {"value": true}})),
            Ok(json!({"result": {"value": false}})),
        ]);
        let mut transfer =
            MarkdownCdpTransfer::new(&mut evaluator, "tauri", "request", None);
        let error = transfer
            .write(&"y".repeat(MARKDOWN_TRANSFER_CHUNK_BYTES * 3))
            .unwrap_err();
        drop(transfer);
        assert!(error.contains("Markdown 分块 1"));
        assert_eq!(evaluator.calls.len(), 2);
    }

    #[test]
    fn markdown_transfer_finish_flushes_the_final_partial_chunk() {
        let mut evaluator = MockEvaluator::acking_all();
        let mut transfer =
            MarkdownCdpTransfer::new(&mut evaluator, "tauri", "request", None);
        transfer.write("# 标题\n\n正文🙂").unwrap();
        // 未满一块时 write 不发送，finish 冲刷余量。
        assert_eq!(transfer.chunk_count, 0);
        let count = transfer.finish().unwrap();
        assert_eq!(count, 1);
        assert_eq!(evaluator.chunks(), vec!["# 标题\n\n正文🙂".to_string()]);
    }

    #[test]
    fn reconnect_cleanup_aborts_only_the_current_owner_markdown_transfers() {
        let expression = abort_orphan_transfers_expression("tauri").unwrap();
        assert!(expression.contains(r#"const owner = "tauri";"#));
        assert!(expression.contains(r#"const prefix = owner + "\u0000";"#));
        assert!(expression.contains("if (!key.startsWith(prefix)) continue;"));
        assert!(expression.contains("state.markdownTransfers.delete(key);"));
        assert!(expression.contains("transfer.sink?.abort?.()"));
        assert!(expression.contains("bridge?.callbacks?.get?."));
        assert!(expression.contains("会话增强桥已重连，导出中止"));

        let source = include_str!("thread_delete.rs");
        assert!(
            source.contains("abort_orphan_transfers_expression(OWNER)?"),
            "install_bridge must execute owner-scoped orphan cleanup after reconnect"
        );
        assert!(
            source.contains(r#"require_page_ack(&cleanup, "清理重连前遗留 Markdown 传输")?"#),
            "install_bridge must reject a cleanup expression that was not acknowledged"
        );
    }

    #[test]
    fn page_ack_requires_an_explicit_true_value() {
        assert!(require_page_ack(
            &json!({"result": {"value": true}}),
            "chunk"
        )
        .is_ok());
        assert!(require_page_ack(
            &json!({"result": {"value": false}}),
            "chunk"
        )
        .is_err());
        assert!(require_page_ack(&json!({}), "chunk").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn delete_command_drains_large_stdout_and_stderr_before_exit() {
        use std::os::unix::fs::PermissionsExt;
        use std::time::{SystemTime, UNIX_EPOCH};

        struct TestDirectory(std::path::PathBuf);
        impl Drop for TestDirectory {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let directory = TestDirectory(std::env::temp_dir().join(format!(
            "codex-token-bar-thread-delete-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        )));
        std::fs::create_dir(&directory.0).unwrap();
        let script = directory.0.join("fake-codex");
        std::fs::write(
            &script,
            "#!/bin/sh\n\
             dd if=/dev/zero bs=1048576 count=1 2>/dev/null | tr '\\000' x\n\
             printf '\\nSTDOUT_DONE\\n'\n\
             dd if=/dev/zero bs=1048576 count=1 2>/dev/null | tr '\\000' y >&2\n\
             printf '\\nSTDERR_DONE\\n' >&2\n",
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();

        let output = run_delete_command(
            &script,
            &directory.0,
            "019f5a7c-1234-7abc-8def-0123456789ab",
            Duration::from_secs(5),
        )
        .unwrap();

        assert!(output.ends_with("STDOUT_DONE"));
        assert!(output.len() <= PIPE_TAIL_LIMIT_BYTES);
    }

    #[cfg(unix)]
    #[test]
    fn delete_command_does_not_wait_forever_for_descendant_inherited_pipe() {
        use std::os::unix::fs::PermissionsExt;
        use std::time::{SystemTime, UNIX_EPOCH};

        struct TestDirectory(std::path::PathBuf);
        impl Drop for TestDirectory {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let directory = TestDirectory(std::env::temp_dir().join(format!(
            "codex-token-bar-thread-delete-descendant-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        )));
        std::fs::create_dir(&directory.0).unwrap();
        // 后代永不退出（sleep 1000）并继承 stdout/stderr 写端：旧实现的
        // reader 会永久阻塞；新实现 finish 必须仍然快速返回并回收 reader。
        struct DescendantGuard(std::path::PathBuf);
        impl Drop for DescendantGuard {
            fn drop(&mut self) {
                if let Ok(pid) = std::fs::read_to_string(&self.0) {
                    let _ = Command::new("kill")
                        .args(["-9", pid.trim()])
                        .status();
                }
            }
        }
        let pid_file = directory.0.join("descendant.pid");
        let _descendant_guard = DescendantGuard(pid_file.clone());
        let script = directory.0.join("fake-codex");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nsleep 1000 &\necho $! > '{}'\nprintf 'PARENT_DONE\\n'\n",
                pid_file.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();

        let started_at = Instant::now();
        let output = run_delete_command(
            &script,
            &directory.0,
            "019f5a7c-1234-7abc-8def-0123456789ab",
            Duration::from_secs(2),
        )
        .unwrap();

        assert!(output.ends_with("PARENT_DONE"));
        assert!(started_at.elapsed() < Duration::from_millis(1_500));
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
