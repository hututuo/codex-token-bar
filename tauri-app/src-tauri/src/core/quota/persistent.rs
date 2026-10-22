use super::{
    configure_quota_app_server_command, find_codex_binary_with_report, QuotaChildGuard,
    QuotaStdoutEvent,
};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Mutex, OnceLock,
};
use std::time::{Duration, Instant};

static SERVICE: OnceLock<Mutex<Service>> = OnceLock::new();
static STOPPING: AtomicBool = AtomicBool::new(false);
const SNAPSHOT_TTL: Duration = Duration::from_secs(5);
const MAX_LINE_BYTES: usize = 4 * 1024 * 1024;

pub(super) fn read(home: &Path, timeout: Duration) -> Result<Value, String> {
    if STOPPING.load(Ordering::Acquire) {
        return Err("额度服务已关闭".into());
    }
    let binary = find_codex_binary_with_report()?.path;
    let context = context(&binary, home);
    let mut service = SERVICE
        .get_or_init(|| Mutex::new(Service::default()))
        .lock()
        .map_err(|e| e.to_string())?;
    service
        .read(
            context.clone(),
            timeout,
            || {
                let mut command = Command::new(&binary);
                configure_quota_app_server_command(&mut command, Some(home));
                Session::start(command, timeout, &STOPPING)
            },
            &STOPPING,
        )
        .and_then(|value| {
            if context != self::context(&binary, home) {
                service.session = None;
                service.cached = None;
                Err("本地登录或数据源已切换，本次额度结果已丢弃".into())
            } else {
                Ok(value)
            }
        })
}

pub(super) fn shutdown() {
    STOPPING.store(true, Ordering::Release);
    if let Some(service) = SERVICE.get() {
        if let Ok(mut service) = service.lock() {
            service.session = None;
            service.cached = None;
        }
    }
}

fn context(binary: &Path, home: &Path) -> Vec<String> {
    let home = home.canonicalize().unwrap_or_else(|_| home.to_path_buf());
    let observation = super::auth::read_local_auth_observation(&home);
    let account = super::accounts::current_credential(&home)
        .map(|v| v.id())
        .unwrap_or_else(|_| format!("{:?}", observation.flight_fingerprint));
    vec![
        home.display().to_string(),
        binary.display().to_string(),
        stamp(binary),
        account,
        stamp(&home.join("config.toml")),
        stamp(&home.join(".env")),
    ]
}

fn stamp(path: &Path) -> String {
    std::fs::metadata(path)
        .map(|m| format!("{:?}:{}", m.modified().ok(), m.len()))
        .unwrap_or_default()
}

#[derive(Default)]
struct Service {
    context: Vec<String>,
    session: Option<Session>,
    cached: Option<(Instant, Result<Value, String>)>,
    retry_at: Option<Instant>,
    failures: u32,
}

impl Service {
    fn read<F>(
        &mut self,
        context: Vec<String>,
        timeout: Duration,
        start: F,
        stop: &AtomicBool,
    ) -> Result<Value, String>
    where
        F: FnOnce() -> Result<Session, String>,
    {
        if self.context != context {
            self.session = None;
            self.cached = None;
            self.retry_at = None;
            self.failures = 0;
            self.context = context;
        }
        if let Some((at, result)) = &self.cached {
            let ttl = if result.is_ok() {
                SNAPSHOT_TTL
            } else {
                Duration::from_secs(1)
            };
            if at.elapsed() < ttl {
                return result.clone();
            }
        }
        if self.retry_at.is_some_and(|at| Instant::now() < at) {
            return Err("Codex 本地额度服务正在等待重连".into());
        }
        if stop.load(Ordering::Acquire) {
            return Err("额度服务已关闭".into());
        }
        if self.session.is_none() {
            match start() {
                Ok(session) => self.session = Some(session),
                Err(error) => {
                    self.disconnected();
                    return Err(error);
                }
            }
        }
        let result =
            match self
                .session
                .as_mut()
                .unwrap()
                .rpc("account/rateLimits/read", None, timeout, stop)
            {
                Ok(value) => {
                    self.failures = 0;
                    Ok(value)
                }
                Err(RequestError::Remote(error)) => Err(error),
                Err(RequestError::Transport(error)) => {
                    self.disconnected();
                    Err(error)
                }
            };
        self.cached = Some((Instant::now(), result.clone()));
        result
    }

    fn disconnected(&mut self) {
        self.session = None;
        self.failures = (self.failures + 1).min(6);
        self.retry_at =
            Some(Instant::now() + Duration::from_secs((1u64 << (self.failures - 1)).min(30)));
    }
}

enum RequestError {
    Remote(String),
    Transport(String),
}

struct Session {
    child: QuotaChildGuard<std::process::Child>,
    stdin: Option<std::process::ChildStdin>,
    receiver: mpsc::Receiver<QuotaStdoutEvent>,
    next_id: u64,
    #[cfg(windows)]
    _job: std::os::windows::io::OwnedHandle,
}

impl Session {
    fn start(mut command: Command, timeout: Duration, stop: &AtomicBool) -> Result<Self, String> {
        let child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("启动 Codex 失败：{e}"))?;
        let mut child = QuotaChildGuard::new(child);
        #[cfg(windows)]
        let job = attach_job(child.child_mut())?;
        let stdin = child.child_mut().stdin.take().ok_or("Codex stdin 不可用")?;
        let stdout = child
            .child_mut()
            .stdout
            .take()
            .ok_or("Codex stdout 不可用")?;
        let stderr = child
            .child_mut()
            .stderr
            .take()
            .ok_or("Codex stderr 不可用")?;
        child.collect_stderr(stderr);
        let (sender, receiver) = mpsc::sync_channel(16);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let mut line = Vec::new();
                let event = match (&mut reader)
                    .take(MAX_LINE_BYTES as u64 + 1)
                    .read_until(b'\n', &mut line)
                {
                    Ok(0) => QuotaStdoutEvent::Eof,
                    Ok(_) if line.len() > MAX_LINE_BYTES => {
                        QuotaStdoutEvent::IoError("Codex 响应超过大小限制".into())
                    }
                    Ok(_) => match serde_json::from_slice::<Value>(&line) {
                        Ok(value) if value.get("id").is_some() => QuotaStdoutEvent::Message(value),
                        _ => continue, // No thread/model activity: notifications are not retained.
                    },
                    Err(e) => QuotaStdoutEvent::IoError(e.to_string()),
                };
                let terminal = !matches!(event, QuotaStdoutEvent::Message(_));
                if sender.try_send(event).is_err() || terminal {
                    break;
                }
            }
        });
        let mut session = Self {
            child,
            stdin: Some(stdin),
            receiver,
            next_id: 1,
            #[cfg(windows)]
            _job: job,
        };
        session.rpc("initialize", Some(json!({
            "clientInfo": {"name":"codex-token-bar-tauri", "version":env!("CARGO_PKG_VERSION")},
            "capabilities": {"experimentalApi":false, "requestAttestation":false}
        })), timeout, stop).map_err(|e| match e { RequestError::Remote(e) | RequestError::Transport(e) => e })?;
        session.write(&json!({"method":"initialized"}))?;
        Ok(session)
    }

    fn write(&mut self, message: &Value) -> Result<(), String> {
        let stdin = self.stdin.as_mut().ok_or("Codex stdin 已关闭")?;
        serde_json::to_writer(&mut *stdin, message).map_err(|e| e.to_string())?;
        stdin
            .write_all(b"\n")
            .and_then(|_| stdin.flush())
            .map_err(|e| format!("Codex 管道写入失败：{e}"))
    }

    fn rpc(
        &mut self,
        method: &str,
        params: Option<Value>,
        timeout: Duration,
        stop: &AtomicBool,
    ) -> Result<Value, RequestError> {
        let id = self.next_id;
        self.next_id += 1;
        let mut message = json!({"id":id, "method":method});
        if let Some(params) = params {
            message["params"] = params;
        }
        self.write(&message).map_err(RequestError::Transport)?;
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if stop.load(Ordering::Acquire) {
                return Err(RequestError::Transport("额度服务正在关闭".into()));
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            match self
                .receiver
                .recv_timeout(remaining.min(Duration::from_millis(100)))
            {
                Ok(QuotaStdoutEvent::Message(value))
                    if value.get("id").and_then(Value::as_u64) == Some(id) =>
                {
                    if let Some(error) = value.get("error") {
                        return Err(RequestError::Remote(
                            error["message"]
                                .as_str()
                                .unwrap_or("Codex 请求失败")
                                .to_string(),
                        ));
                    }
                    return value
                        .get("result")
                        .filter(|v| v.is_object())
                        .cloned()
                        .ok_or_else(|| RequestError::Transport("Codex 响应缺少 result".into()));
                }
                Ok(QuotaStdoutEvent::Message(_)) => continue,
                Ok(QuotaStdoutEvent::Eof) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(RequestError::Transport(
                        "Codex app-server 管道已关闭".into(),
                    ))
                }
                Ok(QuotaStdoutEvent::IoError(error)) => return Err(RequestError::Transport(error)),
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
            }
        }
        Err(RequestError::Transport("读取 Codex 额度超时".into()))
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.stdin = None;
        self.child.cleanup();
    }
}

#[cfg(windows)]
fn attach_job(child: &std::process::Child) -> Result<std::os::windows::io::OwnedHandle, String> {
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use windows_sys::Win32::System::JobObjects::*;
    unsafe {
        let raw = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        if raw.is_null() {
            return Err(format!(
                "无法创建 Codex 子进程保护：{}",
                std::io::Error::last_os_error()
            ));
        }
        let job = OwnedHandle::from_raw_handle(raw);
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if SetInformationJobObject(
            raw,
            JobObjectExtendedLimitInformation,
            &limits as *const _ as *const _,
            std::mem::size_of_val(&limits) as u32,
        ) == 0
            || AssignProcessToJobObject(raw, child.as_raw_handle()) == 0
        {
            return Err(format!(
                "无法保护 Codex 子进程生命周期：{}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(job)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn fixture() -> Command {
        let mut c = Command::new("sh");
        c.args(["-c", r#"while IFS= read -r line; do
case "$line" in
*'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}';;
*'"method":"account/rateLimits/read"'*) id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/'); printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":21}},"rateLimitResetCredits":{"availableCount":3,"credits":[]}}}\n' "$id";;
esac
done"#]);
        c
    }

    #[cfg(unix)]
    #[test]
    fn persistent_connection_initializes_once_and_reuses_ids_and_snapshot() {
        let stop = AtomicBool::new(false);
        let mut service = Service::default();
        let scope = vec!["fixture-home".to_string()];
        let first = service
            .read(
                scope.clone(),
                Duration::from_secs(2),
                || Session::start(fixture(), Duration::from_secs(2), &stop),
                &stop,
            )
            .unwrap();
        let pid = service.session.as_ref().unwrap().child.child.id();
        let cached = service
            .read(
                scope.clone(),
                Duration::from_secs(2),
                || panic!("cache must not start a process"),
                &stop,
            )
            .unwrap();
        assert_eq!(first, cached);
        assert_eq!(service.session.as_ref().unwrap().next_id, 3);
        service.cached = None;
        let next = service
            .read(
                scope,
                Duration::from_secs(2),
                || panic!("initialized process must be reused"),
                &stop,
            )
            .unwrap();
        assert_eq!(next["rateLimitResetCredits"]["availableCount"], 3);
        assert_eq!(service.session.as_ref().unwrap().next_id, 4);
        assert_eq!(service.session.as_ref().unwrap().child.child.id(), pid);
    }

    #[cfg(unix)]
    #[test]
    fn persistent_eof_closes_child_and_reconnects_after_backoff() {
        let stop = AtomicBool::new(false);
        let mut service = Service::default();
        let scope = vec!["fixture-home".to_string()];
        service
            .read(
                scope.clone(),
                Duration::from_secs(2),
                || Session::start(fixture(), Duration::from_secs(2), &stop),
                &stop,
            )
            .unwrap();
        service
            .session
            .as_mut()
            .unwrap()
            .child
            .child
            .kill()
            .unwrap();
        service
            .session
            .as_mut()
            .unwrap()
            .child
            .child
            .wait()
            .unwrap();
        service.cached = None;
        assert!(service
            .read(
                scope.clone(),
                Duration::from_secs(2),
                || panic!("existing process is still owned until EOF"),
                &stop
            )
            .is_err());
        assert!(service.session.is_none());
        assert!(service.retry_at.is_some());
        service.cached = None;
        assert!(service
            .read(
                scope.clone(),
                Duration::from_secs(2),
                || panic!("backoff must prevent respawn"),
                &stop
            )
            .is_err());
        service.retry_at = None;
        assert!(service
            .read(
                scope,
                Duration::from_secs(2),
                || Session::start(fixture(), Duration::from_secs(2), &stop),
                &stop
            )
            .is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn remote_error_keeps_initialized_transport_alive() {
        let stop = AtomicBool::new(false);
        let mut session = Session::start(fixture(), Duration::from_secs(2), &stop).unwrap();
        // A different fixture explicitly returns a request error after initialize.
        let mut command = Command::new("sh");
        command.args(["-c", "IFS= read -r line; echo '{\"id\":1,\"result\":{}}'; IFS= read -r line; while IFS= read -r line; do id=$(printf '%s' \"$line\" | sed -E 's/.*\"id\":([0-9]+).*/\\1/'); printf '{\"id\":%s,\"error\":{\"message\":\"network unavailable\"}}\\n' \"$id\"; done"]);
        let error_session = Session::start(command, Duration::from_secs(2), &stop).unwrap();
        let mut service = Service {
            context: vec!["scope".into()],
            session: Some(error_session),
            ..Service::default()
        };
        assert!(service
            .read(
                vec!["scope".into()],
                Duration::from_secs(2),
                || panic!("must retain process"),
                &stop
            )
            .is_err());
        assert!(service.session.is_some());
        assert_eq!(service.failures, 0);
        // Independently verify a caller's session remains usable.
        assert!(session
            .rpc(
                "account/rateLimits/read",
                None,
                Duration::from_secs(2),
                &stop
            )
            .is_ok());
    }

    #[cfg(windows)]
    #[test]
    fn windows_quota_job_kills_only_its_owned_child_on_close() {
        let mut child = Command::new("cmd")
            .args(["/C", "ping -n 30 127.0.0.1 >NUL"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let job = attach_job(&child).unwrap();
        assert!(child.try_wait().unwrap().is_none());
        drop(job);
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline && child.try_wait().unwrap().is_none() {
            std::thread::sleep(Duration::from_millis(10));
        }
        let exited = child.try_wait().unwrap().is_some();
        if !exited {
            let _ = child.kill();
        }
        let _ = child.wait();
        assert!(exited, "closing the owned job must terminate the child");
    }
}
