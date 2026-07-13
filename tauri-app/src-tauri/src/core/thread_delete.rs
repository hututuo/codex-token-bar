use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{ErrorKind, Read};
use std::net::TcpStream;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use tungstenite::client::IntoClientRequest;
use tungstenite::http::header::ORIGIN;
use tungstenite::http::HeaderValue;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{connect, Message, WebSocket};

const DEBUG_PORTS: [u16; 2] = [9229, 9222];
const BINDING_NAME: &str = "codexTokenBarDeleteTauri";
const OWNER: &str = "tauri";
const PROBE_INTERVAL: Duration = Duration::from_secs(3);
const READ_TIMEOUT: Duration = Duration::from_secs(1);
const REINJECT_INTERVAL: Duration = Duration::from_secs(5);
const DELETE_TIMEOUT: Duration = Duration::from_secs(20);
const INJECTION_TEMPLATE: &str =
    include_str!("../../../../Resources/CodexThreadDeleteInjection.js");

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
struct DeleteBindingRequest {
    id: String,
    owner: String,
    thread_id: String,
    #[allow(dead_code)]
    title: String,
}

#[derive(Debug, Serialize)]
struct DeleteBindingResult {
    status: &'static str,
    message: String,
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
    set_status(false, current.debug_port, "正在重新连接 Codex 删除按钮");
    bridge_status()
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
                set_status(false, Some(port), "正在重新连接 Codex 删除按钮");
                true
            }
            Err(error) => {
                set_status(
                    false,
                    Some(port),
                    format!("Codex 删除按钮连接中断：{error}"),
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
    let mut request = websocket_url
        .into_client_request()
        .map_err(|error| error.to_string())?;
    request.headers_mut().insert(
        ORIGIN,
        HeaderValue::from_str(&format!("http://127.0.0.1:{port}"))
            .map_err(|error| error.to_string())?,
    );
    let (mut socket, _) = connect(request).map_err(|error| error.to_string())?;
    set_read_timeout(&mut socket, READ_TIMEOUT)?;
    install_bridge(&mut socket)?;
    set_status(true, Some(port), "Codex 会话删除按钮已连接");
    let mut last_injection = Instant::now();

    loop {
        if RECONNECT_REQUESTED.swap(false, Ordering::AcqRel) {
            let _ = socket.close(None);
            return Ok(SessionExit::Reconnect);
        }
        if last_injection.elapsed() >= REINJECT_INTERVAL {
            send_command(
                &mut socket,
                "Runtime.evaluate",
                json!({ "expression": rendered_injection_script() }),
            )?;
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

fn install_bridge(socket: &mut WebSocket<MaybeTlsStream<TcpStream>>) -> Result<(), String> {
    send_command(socket, "Runtime.enable", json!({}))?;
    send_command(
        socket,
        "Runtime.removeBinding",
        json!({ "name": BINDING_NAME }),
    )?;
    send_command(
        socket,
        "Runtime.addBinding",
        json!({ "name": BINDING_NAME }),
    )?;
    let script = rendered_injection_script();
    send_command(
        socket,
        "Page.addScriptToEvaluateOnNewDocument",
        json!({ "source": script }),
    )?;
    send_command(socket, "Runtime.evaluate", json!({ "expression": script }))
}

fn rendered_injection_script() -> String {
    INJECTION_TEMPLATE
        .replace(
            "__CTB_OWNER_JSON__",
            &serde_json::to_string(OWNER).expect("static owner serializes"),
        )
        .replace(
            "__CTB_BINDING_JSON__",
            &serde_json::to_string(BINDING_NAME).expect("static binding serializes"),
        )
}

fn send_command(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    method: &str,
    params: Value,
) -> Result<(), String> {
    let id = MESSAGE_ID.fetch_add(1, Ordering::Relaxed) + 1;
    socket
        .send(Message::Text(
            json!({ "id": id, "method": method, "params": params })
                .to_string()
                .into(),
        ))
        .map_err(|error| error.to_string())
}

fn handle_cdp_message(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    text: &str,
) -> Result<(), String> {
    let message: Value = serde_json::from_str(text).map_err(|error| error.to_string())?;
    if message.get("method").and_then(Value::as_str) != Some("Runtime.bindingCalled") {
        return Ok(());
    }
    let Some(payload) = message
        .get("params")
        .and_then(|params| params.get("payload"))
        .and_then(Value::as_str)
    else {
        return Ok(());
    };
    let request: DeleteBindingRequest = match serde_json::from_str(payload) {
        Ok(request) => request,
        Err(error) => return Err(format!("删除请求格式错误：{error}")),
    };
    if request.owner != OWNER {
        return Ok(());
    }
    let result = match delete_thread(&request.thread_id) {
        Ok(message) => DeleteBindingResult {
            status: "deleted",
            message,
        },
        Err(message) => DeleteBindingResult {
            status: "failed",
            message,
        },
    };
    let expression = resolve_expression(&request.owner, &request.id, &result)?;
    send_command(
        socket,
        "Runtime.evaluate",
        json!({ "expression": expression }),
    )
}

fn resolve_expression(
    owner: &str,
    request_id: &str,
    result: &DeleteBindingResult,
) -> Result<String, String> {
    Ok(format!(
        "window.__codexTokenBarThreadDeleteResolve({}, {}, {})",
        serde_json::to_string(owner).map_err(|error| error.to_string())?,
        serde_json::to_string(request_id).map_err(|error| error.to_string())?,
        serde_json::to_string(result).map_err(|error| error.to_string())?,
    ))
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
        let script = rendered_injection_script();
        assert!(script.contains("const owner = \"tauri\";"));
        assert!(script.contains("const bindingName = \"codexTokenBarDeleteTauri\";"));
        assert!(!script.contains("__CTB_OWNER_JSON__"));
        assert!(!script.contains("__CTB_BINDING_JSON__"));
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
