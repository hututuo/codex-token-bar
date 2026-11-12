//! Windows Hub, IDE LSP and agy --hub discovery. No client launch, remote
//! CIM session, account credentials, forceRefresh, or arbitrary request URL.
use super::{
    decode, unavailable, valid_label, QuotaProviderSnapshot, QuotaProviderWindow, MAX_BYTES, SOURCE,
};
use serde::Deserialize;
use serde_json::Value;
use std::path::Path;
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

const MAX_SERVERS: usize = 16;
const MAX_SOCKETS: usize = 32;
const MAX_TARGETS: usize = 8;
const METADATA_SCRIPT: &str = include_str!("windows_metadata.ps1");

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Hub,
    AgyHub,
    Ide,
}

fn process_name(name: &str) -> bool {
    [
        "language_server.exe",
        "agy.exe",
        "language_server_windows_x64.exe",
        "language_server_windows_arm.exe",
        "language_server_windows_arm64.exe",
    ]
    .iter()
    .any(|known| name.eq_ignore_ascii_case(known))
}

// Pure normalization only: never canonicalize an untrusted/UNC path through I/O.
fn windows_path(path: &str) -> Option<String> {
    let path = path.replace('/', "\\");
    let path = path.strip_prefix("\\\\?\\").unwrap_or(&path);
    let bytes = path.as_bytes();
    if bytes.len() < 3
        || !bytes[0].is_ascii_alphabetic()
        || &bytes[1..3] != b":\\"
        || path.chars().any(char::is_control)
        || path[3..]
            .split('\\')
            .any(|p| p.is_empty() || p == "." || p == "..")
    {
        return None;
    }
    Some(path.to_owned())
}

fn kind(path: &str, roots: &[String], home: &Path) -> Option<Kind> {
    let path = windows_path(path)?;
    let agy = windows_path(&home.join(".gemini/bin/agy.exe").to_string_lossy());
    if agy.is_some_and(|p| path.eq_ignore_ascii_case(&p)) {
        return Some(Kind::AgyHub);
    }
    for root in roots {
        let Some(root) = windows_path(root) else {
            continue;
        };
        if path.eq_ignore_ascii_case(&format!("{root}\\resources\\bin\\language_server.exe")) {
            return Some(Kind::Hub);
        }
        for name in [
            "language_server_windows_x64.exe",
            "language_server_windows_arm.exe",
            "language_server_windows_arm64.exe",
        ] {
            if path.eq_ignore_ascii_case(&format!(
                "{root}\\resources\\app\\extensions\\antigravity\\bin\\{name}"
            )) {
                return Some(Kind::Ide);
            }
        }
    }
    None
}

#[derive(Clone)]
struct Binding {
    pid: u32,
    executable: String,
    identity: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawProcess {
    pid: u32,
    executable: String,
    command_line: String,
    same_user: bool,
    ports: Vec<RawSocket>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawSocket {
    address: String,
    port: u16,
    owner_pid: u32,
}
#[derive(Deserialize)]
struct Snapshot {
    complete: bool,
    processes: Vec<RawProcess>,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Loopback {
    V4,
    V6,
}
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct Target {
    port: u16,
    host: Loopback,
}
impl Target {
    fn url(self, method: Method) -> String {
        let host = if self.host == Loopback::V4 {
            "127.0.0.1"
        } else {
            "[::1]"
        };
        format!(
            "https://{host}:{}/exa.language_server_pb.LanguageServerService/{}",
            self.port,
            method.name()
        )
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Method {
    Status,
    Summary,
}
impl Method {
    fn name(self) -> &'static str {
        match self {
            Self::Status => "GetUserStatus",
            Self::Summary => "RetrieveUserQuotaSummary",
        }
    }
    fn body(self) -> Value {
        serde_json::json!({"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}})
    }
}

struct Server {
    binding: Binding,
    kind: Kind,
    csrf: String,
    https_port: Option<u16>,
    ui_port: Option<u16>,
    sockets: Vec<Target>,
}
impl Server {
    fn targets(&self) -> Vec<Target> {
        let mut targets: Vec<_> = self
            .sockets
            .iter()
            .copied()
            .filter(|t| self.https_port.is_none_or(|p| t.port == p))
            .collect();
        targets.sort_unstable_by_key(|t| (Some(t.port) == self.ui_port, t.port, t.host));
        targets.dedup();
        targets.truncate(MAX_TARGETS);
        targets
    }
    fn matches(&self, after: &Self, target: Target) -> bool {
        self.binding.pid == after.binding.pid
            && self.binding.identity == after.binding.identity
            && self
                .binding
                .executable
                .eq_ignore_ascii_case(&after.binding.executable)
            && self.kind == after.kind
            && self.csrf == after.csrf
            && after.sockets.contains(&target)
    }
}

fn flag<'a>(args: &'a [String], name: &str) -> Result<Option<&'a str>, ()> {
    let mut found = None;
    for (i, a) in args.iter().enumerate().skip(1) {
        let value = if a == name {
            Some(
                args.get(i + 1)
                    .filter(|v| !v.starts_with("--"))
                    .ok_or(())?
                    .as_str(),
            )
        } else {
            a.strip_prefix(name).and_then(|v| v.strip_prefix('='))
        };
        if let Some(value) = value {
            if found.replace(value).is_some() {
                return Err(());
            }
        }
    }
    Ok(found)
}

fn decode_snapshot(
    bytes: &[u8],
    bindings: &[Binding],
    roots: &[String],
    home: &Path,
    parse_args: impl Fn(&str) -> Option<Vec<String>>,
) -> Result<Option<Server>, ()> {
    if bytes.len() > 1_048_576 {
        return Err(());
    }
    let text = std::str::from_utf8(bytes)
        .map_err(|_| ())?
        .trim_start_matches('\u{feff}');
    let snapshot: Snapshot = serde_json::from_str(text).map_err(|_| ())?;
    if !snapshot.complete || snapshot.processes.len() > MAX_SERVERS {
        return Err(());
    }
    let mut servers = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for process in snapshot.processes {
        let binding = bindings.iter().find(|b| b.pid == process.pid).ok_or(())?;
        let executable = windows_path(&process.executable).ok_or(())?;
        if !process.same_user
            || !seen.insert(process.pid)
            || !executable.eq_ignore_ascii_case(&binding.executable)
            || process.command_line.len() > 131_072
            || process.ports.len() > MAX_SOCKETS
        {
            return Err(());
        }
        let Some(kind) = kind(&executable, roots, home) else {
            return Err(());
        };
        let args = parse_args(&process.command_line)
            .filter(|a| !a.is_empty() && a.len() <= 512)
            .ok_or(())?;
        let mode = match kind {
            Kind::Hub => {
                args.iter().any(|s| s == "--standalone")
                    || flag(&args, "--subclient_type")? == Some("hub")
            }
            Kind::AgyHub => args.iter().any(|s| s == "--hub"),
            Kind::Ide => {
                flag(&args, "--extension_server_port")?.is_some()
                    || args.iter().any(|s| s == "--enable_lsp")
            }
        };
        let app_data = flag(&args, "--app_data_dir")?;
        if !mode
            || (kind == Kind::Ide
                && !app_data.is_some_and(|s| ["antigravity", "antigravity-ide"].contains(&s)))
        {
            return Err(());
        }
        let csrf = flag(&args, "--csrf_token")?.ok_or(())?;
        if !(16..=128).contains(&csrf.len())
            || !csrf.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
        {
            return Err(());
        }
        let port_flag = |name| -> Result<Option<u16>, ()> {
            flag(&args, name)?
                .map(|s| s.parse::<u16>().map_err(|_| ()))
                .transpose()
        };
        let https_port = port_flag("--https_server_port")?.filter(|p| *p != 0);
        let ui_port = port_flag("--hub-port")?.filter(|p| *p != 0);
        let mut sockets = Vec::new();
        for socket in process.ports {
            if socket.owner_pid != process.pid || socket.port < 1024 {
                return Err(());
            }
            let host = match socket.address.as_str() {
                "127.0.0.1" | "0.0.0.0" => Loopback::V4,
                "::1" | "::" => Loopback::V6,
                _ => return Err(()),
            };
            sockets.push(Target {
                port: socket.port,
                host,
            });
        }
        sockets.sort_unstable();
        sockets.dedup();
        servers.push(Server {
            binding: binding.clone(),
            kind,
            csrf: csrf.into(),
            https_port,
            ui_port,
            sockets,
        });
    }
    // A standalone/new Hub is authoritative when an older IDE is also open.
    // Never choose arbitrarily among two Hubs or two unrelated IDE sessions.
    if servers.iter().any(|s| s.kind != Kind::Ide) {
        servers.retain(|s| s.kind != Kind::Ide);
    }
    match servers.len() {
        0 => Ok(None),
        1 => Ok(servers.pop()),
        _ => Err(()),
    }
}

fn decode_reply(value: &Value, method: Method, now: f64) -> Option<QuotaProviderSnapshot> {
    if method == Method::Status {
        let user = value
            .get("userStatus")
            .or_else(|| value.get("user_status"))?;
        let config = user
            .get("cascadeModelConfigData")
            .or_else(|| user.get("cascade_model_config_data"))?;
        let models = config
            .get("clientModelConfigs")
            .or_else(|| config.get("client_model_configs"))?
            .as_array()?;
        if models.len() > 128 {
            return None;
        }
        let models: Vec<_> = models.iter().map(|model| {
            let empty = Value::Null;
            let quota = model.get("quotaInfo")
                .or_else(|| model.get("quota_info")).unwrap_or(&empty);
            serde_json::json!({
                "label": model.get("label"),
                "modelOrAlias": model.get("modelOrAlias").or_else(|| model.get("model_or_alias")),
                "quotaInfo": {
                    "remainingFraction": quota.get("remainingFraction").or_else(|| quota.get("remaining_fraction")),
                    "resetTime": quota.get("resetTime").or_else(|| quota.get("reset_time"))
                }
            })
        }).collect();
        let projected = serde_json::json!({"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":models}}});
        let reading = decode(&serde_json::to_vec(&projected).ok()?, now);
        return (!reading.windows.is_empty()).then_some(reading);
    }
    let root = value
        .get("response")
        .or_else(|| value.get("summary"))
        .unwrap_or(value);
    let groups = root.get("groups")?.as_array()?;
    if groups.len() > 128 {
        return None;
    }
    let mut windows = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut bucket_count = 0;
    for (index, group) in groups.iter().enumerate() {
        let buckets = group.get("buckets")?.as_array()?;
        bucket_count += buckets.len();
        if bucket_count > 128 {
            return None;
        }
        if group.get("disabled").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let group_name = group
            .get("displayName")
            .or_else(|| group.get("display_name"))
            .and_then(Value::as_str)
            .filter(|s| valid_label(s))
            .unwrap_or("额度");
        for bucket in buckets {
            if bucket.get("disabled").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            let raw = bucket
                .get("remainingFraction")
                .or_else(|| bucket.get("remaining_fraction"))
                .or_else(|| {
                    bucket.get("remaining").and_then(|r| {
                        r.get("remainingFraction")
                            .or_else(|| r.get("remaining_fraction"))
                    })
                })
                .or_else(|| {
                    bucket
                        .get("remaining")
                        .filter(|r| {
                            r.get("case").and_then(Value::as_str) == Some("remainingFraction")
                        })
                        .and_then(|r| r.get("value"))
                });
            let Some(fraction) = raw
                .and_then(Value::as_f64)
                .filter(|n| n.is_finite() && (0.0..=1.0).contains(n))
            else {
                continue;
            };
            let name = bucket
                .get("displayName")
                .or_else(|| bucket.get("display_name"))
                .or_else(|| bucket.get("window"))
                .and_then(Value::as_str)
                .filter(|s| valid_label(s))
                .unwrap_or("额度");
            let id = bucket
                .get("bucketId")
                .or_else(|| bucket.get("bucket_id"))
                .and_then(Value::as_str)
                .filter(|s| valid_label(s))
                .unwrap_or(name);
            let id = format!("bucket:{index}:{id}");
            if !seen.insert(id.clone()) {
                continue;
            }
            let label = format!("{group_name} · {name}");
            let label = if valid_label(&label) {
                label
            } else {
                group_name.into()
            };
            let reset = bucket
                .get("resetTime")
                .or_else(|| bucket.get("reset_time"))
                .and_then(Value::as_str)
                .and_then(|s| OffsetDateTime::parse(s, &Rfc3339).ok());
            windows.push(QuotaProviderWindow {
                id: Some(id),
                label,
                used_percent: Some((1.0 - fraction) * 100.0),
                resets_at: reset.and_then(|d| d.format(&Rfc3339).ok()),
            });
        }
    }
    if windows.is_empty() {
        return None;
    }
    let stale = windows.iter().any(|w| {
        w.resets_at
            .as_deref()
            .and_then(|s| OffsetDateTime::parse(s, &Rfc3339).ok())
            .is_none_or(|d| d.unix_timestamp() as f64 <= now)
    });
    Some(QuotaProviderSnapshot {
        client: "antigravity".into(),
        state: if stale { "stale" } else { "available" }.into(),
        source: SOURCE.into(),
        windows,
        captured_at: OffsetDateTime::from_unix_timestamp(now as i64).ok()
            .and_then(|d| d.format(&Rfc3339).ok()),
        notice: "当前运行的 Antigravity 本机语言服务返回值；未强制刷新。客户端可能自行联网。读取时间不代表上游采样时间，按额度池展示，不合计余额。".into(),
    })
}

fn probe(
    server: Server,
    now: f64,
    mut query: impl FnMut(Target, Method, &str) -> Option<Value>,
    rediscover: impl FnOnce() -> Result<Option<Server>, ()>,
) -> QuotaProviderSnapshot {
    for target in server.targets() {
        // Modern clients expose independent quota windows in Summary. A legacy
        // model percentage must not hide a supported weekly window.
        for method in [Method::Summary, Method::Status] {
            let Some(value) = query(target, method, &server.csrf) else {
                continue;
            };
            let Some(reading) = decode_reply(&value, method, now) else {
                continue;
            };
            return match rediscover() {
                Ok(Some(after)) if server.matches(&after, target) => reading,
                _ => unavailable(),
            };
        }
    }
    unavailable()
}

#[cfg(windows)]
fn installed_roots(home: &Path) -> Vec<String> {
    let local = std::env::var_os("LOCALAPPDATA")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| home.join("AppData/Local"));
    let mut bases = vec![local.join("Programs")];
    for key in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Some(p) = std::env::var_os(key) {
            bases.push(p.into());
        }
    }
    bases
        .into_iter()
        .flat_map(|base| {
            ["Antigravity", "Antigravity IDE", "Antigravity-IDE"]
                .map(|name| base.join(name).to_string_lossy().into_owned())
        })
        .filter_map(|s| windows_path(&s))
        .collect()
}

#[cfg(windows)]
fn bindings(roots: &[String], home: &Path) -> Result<Vec<Binding>, ()> {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, GetLastError, ERROR_NO_MORE_FILES, INVALID_HANDLE_VALUE},
        System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        },
    };
    struct Guard(windows_sys::Win32::Foundation::HANDLE);
    impl Drop for Guard {
        fn drop(&mut self) {
            unsafe { CloseHandle(self.0) };
        }
    }
    let handle = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if handle == INVALID_HANDLE_VALUE {
        return Err(());
    }
    let _guard = Guard(handle);
    let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
    entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
    if unsafe { Process32FirstW(handle, &mut entry) } == 0 {
        return Err(());
    }
    let mut found = Vec::new();
    for _ in 0..65536 {
        let len = entry
            .szExeFile
            .iter()
            .position(|c| *c == 0)
            .unwrap_or(entry.szExeFile.len());
        if process_name(&String::from_utf16_lossy(&entry.szExeFile[..len])) {
            let pid = entry.th32ProcessID;
            if let Ok(path) = crate::platform::managed_process_executable_path(pid) {
                if let Some(executable) =
                    windows_path(&path.to_string_lossy()).filter(|p| kind(p, roots, home).is_some())
                {
                    let identity =
                        crate::platform::managed_process_identity(pid).map_err(|_| ())?;
                    found.push(Binding {
                        pid,
                        executable,
                        identity,
                    });
                    if found.len() > MAX_SERVERS {
                        return Err(());
                    }
                }
            }
        }
        if unsafe { Process32NextW(handle, &mut entry) } == 0 {
            return if unsafe { GetLastError() } == ERROR_NO_MORE_FILES {
                Ok(found)
            } else {
                Err(())
            };
        }
    }
    Err(())
}

#[cfg(windows)]
fn parse_arguments(command: &str) -> Option<Vec<String>> {
    use windows_sys::Win32::{Foundation::LocalFree, UI::Shell::CommandLineToArgvW};
    if command.is_empty() || command.contains('\0') || command.encode_utf16().count() > 32766 {
        return None;
    }
    let wide: Vec<_> = command.encode_utf16().chain(Some(0)).collect();
    let mut count = 0;
    let argv = unsafe { CommandLineToArgvW(wide.as_ptr(), &mut count) };
    if argv.is_null() {
        return None;
    }
    struct Guard(*mut *mut u16);
    impl Drop for Guard {
        fn drop(&mut self) {
            unsafe { LocalFree(self.0.cast()) };
        }
    }
    let _guard = Guard(argv);
    if !(1..=512).contains(&count) {
        return None;
    }
    let mut args = Vec::new();
    for i in 0..count as usize {
        let ptr = unsafe { *argv.add(i) };
        if ptr.is_null() {
            return None;
        }
        let mut len = 0;
        while len < 32767 && unsafe { *ptr.add(len) } != 0 {
            len += 1;
        }
        if len == 32767 {
            return None;
        }
        args.push(String::from_utf16(unsafe { std::slice::from_raw_parts(ptr, len) }).ok()?);
    }
    Some(args)
}

#[cfg(windows)]
fn metadata(bindings: &[Binding]) -> Result<Vec<u8>, ()> {
    use base64::Engine;
    use std::{
        os::windows::process::CommandExt,
        process::{Command, Stdio},
        time::{Duration, Instant},
    };
    use windows_sys::Win32::System::{
        SystemInformation::GetSystemDirectoryW, Threading::CREATE_NO_WINDOW,
    };
    let mut directory = [0_u16; 32768];
    let length =
        unsafe { GetSystemDirectoryW(directory.as_mut_ptr(), directory.len() as u32) } as usize;
    if length == 0 || length >= directory.len() {
        return Err(());
    }
    let executable =
        std::path::PathBuf::from(String::from_utf16(&directory[..length]).map_err(|_| ())?)
            .join("WindowsPowerShell/v1.0/powershell.exe");
    let ids = bindings
        .iter()
        .map(|b| b.pid.to_string())
        .collect::<Vec<_>>()
        .join(",");
    let paths = serde_json::to_vec(&bindings.iter().map(|b| &b.executable).collect::<Vec<_>>())
        .map_err(|_| ())?;
    let encoded = base64::engine::general_purpose::STANDARD.encode(paths);
    let script = METADATA_SCRIPT
        .replace("__EXECUTABLES_BASE64__", &encoded)
        .replace("__PROCESS_IDS__", &ids);
    if script.encode_utf16().count() > 24000 || bindings.len() > MAX_SERVERS || bindings.is_empty()
    {
        return Err(());
    }
    let mut child = Command::new(executable)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            &script,
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| ())?;
    let output = super::super::process_tail::ProcessPipeTail::spawn(
        child.stdout.take(),
        1_048_577,
        Duration::from_millis(100),
    );
    let deadline = Instant::now() + Duration::from_secs(12);
    let success = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s.success(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break false;
            }
        }
    };
    let text = output.finish();
    if !success || text.len() > 1_048_576 {
        return Err(());
    }
    Ok(text.into_bytes())
}

#[cfg(windows)]
fn discover(roots: &[String], home: &Path) -> Result<Option<Server>, ()> {
    let bindings = bindings(roots, home)?;
    if bindings.is_empty() {
        return Ok(None);
    }
    let bytes = metadata(&bindings)?;
    // Bind the CIM command line and sockets to the kernel image/start identity.
    for b in &bindings {
        if crate::platform::managed_process_identity(b.pid).map_err(|_| ())? != b.identity {
            return Err(());
        }
        let path = crate::platform::managed_process_executable_path(b.pid).map_err(|_| ())?;
        if !windows_path(&path.to_string_lossy())
            .is_some_and(|p| p.eq_ignore_ascii_case(&b.executable))
        {
            return Err(());
        }
    }
    decode_snapshot(&bytes, &bindings, roots, home, parse_arguments)
}

#[cfg(windows)]
pub(super) fn read(home: &Path, now: f64) -> Option<QuotaProviderSnapshot> {
    use std::{
        io::Read,
        time::{Duration, Instant},
    };
    let roots = installed_roots(home);
    let server = match discover(&roots, home) {
        Ok(None) => return None,
        Ok(Some(s)) => s,
        Err(()) => return Some(unavailable()),
    };
    let client = match reqwest::blocking::Client::builder()
        .no_proxy()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .danger_accept_invalid_certs(true)
        .connect_timeout(Duration::from_millis(400))
        .timeout(Duration::from_secs(2))
        .build()
    {
        Ok(c) => c,
        Err(_) => return Some(unavailable()),
    };
    let deadline = Instant::now() + Duration::from_secs(8);
    let reading = probe(
        server,
        now,
        |target, method, csrf| {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return None;
            }
            let response = client
                .post(target.url(method))
                .timeout(remaining.min(Duration::from_secs(2)))
                .header("Connect-Protocol-Version", "1")
                .header("X-Codeium-Csrf-Token", csrf)
                .json(&method.body())
                .send()
                .ok()?;
            if response.status() != reqwest::StatusCode::OK
                || response
                    .content_length()
                    .is_some_and(|n| n > MAX_BYTES as u64)
            {
                return None;
            }
            let mut bytes = Vec::new();
            response
                .take(MAX_BYTES as u64 + 1)
                .read_to_end(&mut bytes)
                .ok()?;
            if bytes.len() > MAX_BYTES {
                return None;
            }
            serde_json::from_slice(&bytes).ok()
        },
        || discover(&roots, home),
    );
    Some(reading)
}

#[cfg(test)]
mod tests {
    use super::*;
    const NONCE: &str = "00000000-0000-0000-0000-000000000001";
    fn context() -> (Vec<String>, std::path::PathBuf, Binding) {
        (vec![r"C:\Users\Fixture User\AppData\Local\Programs\Antigravity".into()],
         r"C:\Users\Fixture User".into(),
         Binding{pid:42,executable:r"C:\Users\Fixture User\AppData\Local\Programs\Antigravity\resources\bin\language_server.exe".into(),identity:"start-one".into()})
    }
    fn snapshot(binding: &Binding, args: Vec<String>) -> Value {
        serde_json::json!({"complete":true,"processes":[{"pid":binding.pid,"executable":binding.executable,
            "sameUser":true,"commandLine":serde_json::to_string(&args).unwrap(),"ports":[
                {"address":"127.0.0.1","port":53100,"ownerPid":binding.pid},
                {"address":"::1","port":53100,"ownerPid":binding.pid}]}]})
    }
    fn args(exe: &str, mode: &str) -> Vec<String> {
        vec![
            exe.into(),
            mode.into(),
            "--app_data_dir=antigravity".into(),
            format!("--csrf_token={NONCE}"),
            "--https_server_port=0".into(),
        ]
    }
    fn planned(
        data: &Value,
        bindings: &[Binding],
        roots: &[String],
        home: &Path,
    ) -> Result<Option<Server>, ()> {
        decode_snapshot(
            &serde_json::to_vec(data).unwrap(),
            bindings,
            roots,
            home,
            |s| serde_json::from_str(s).ok(),
        )
    }
    fn status() -> Value {
        serde_json::json!({"userStatus":{"email":"DO-NOT-PROJECT","cascadeModelConfigData":{"clientModelConfigs":[
        {"label":"Fixture Gemini","modelOrAlias":{"model":"gemini-fixture"},"quotaInfo":{"remainingFraction":0.75,"resetTime":"2027-01-16T09:00:00Z"}}]}}})
    }

    #[test]
    fn windows_quota_discovery_checks_user_paths_sockets_and_real_os_metadata() {
        let (roots, home, binding) = context();
        let data = snapshot(&binding, args(&binding.executable, "--standalone"));
        let server = planned(&data, std::slice::from_ref(&binding), &roots, &home)
            .unwrap()
            .unwrap();
        assert_eq!(server.targets().len(), 2);
        for target in server.targets() {
            let url = reqwest::Url::parse(&target.url(Method::Status)).unwrap();
            assert_eq!(url.scheme(), "https");
            assert!(matches!(
                url.host_str(),
                Some("127.0.0.1") | Some("[::1]") | Some("::1")
            ));
        }
        for (field, value) in [
            ("sameUser", Value::Bool(false)),
            (
                "executable",
                Value::String(r"C:\Unrelated\language_server.exe".into()),
            ),
        ] {
            let mut bad = data.clone();
            bad["processes"][0][field] = value;
            assert!(planned(&bad, std::slice::from_ref(&binding), &roots, &home).is_err());
        }
        let mut bad = data.clone();
        bad["processes"][0]["ports"][0]["ownerPid"] = 43.into();
        assert!(planned(&bad, std::slice::from_ref(&binding), &roots, &home).is_err());
        let mut bad = data.clone();
        bad["processes"][0]["ports"][0]["address"] = "192.0.2.1".into();
        assert!(planned(&bad, std::slice::from_ref(&binding), &roots, &home).is_err());
        assert!(
            windows_path(r"\\server\share\Antigravity\resources\bin\language_server.exe").is_none()
        );
        assert!(kind(r"C:\Users\Fixture User\AppData\Local\Programs\Antigravity\..\Other\resources\bin\language_server.exe",&roots,&home).is_none());
        assert!(planned(
            &serde_json::json!({"complete":true,"processes":[]}),
            &[],
            &roots,
            &home
        )
        .unwrap()
        .is_none());
        #[cfg(windows)]
        {
            // Exercise Windows CIM owner filtering, UTF-8 output and PID-owned
            // listener discovery on this test process. No Antigravity or RPC.
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let pid = std::process::id();
            let path = crate::platform::managed_process_executable_path(pid).unwrap();
            let binding = Binding {
                pid,
                executable: windows_path(&path.to_string_lossy()).unwrap(),
                identity: crate::platform::managed_process_identity(pid).unwrap(),
            };
            let bytes = metadata(std::slice::from_ref(&binding))
                .expect("local Windows CIM metadata query must succeed");
            let row: Snapshot = serde_json::from_slice(&bytes).unwrap();
            assert!(row.complete);
            assert_eq!(row.processes.len(), 1);
            assert!(row.processes[0].same_user);
            assert_eq!(row.processes[0].pid, pid);
            assert!(row.processes[0].ports.iter().any(|p| p.owner_pid == pid
                && p.port == listener.local_addr().unwrap().port()
                && p.address == "127.0.0.1"));
            assert_eq!(
                crate::platform::managed_process_identity(pid).unwrap(),
                binding.identity
            );
            let parsed=parse_arguments(r#""C:\Program Files\Antigravity\resources\bin\language_server.exe" --standalone "--csrf_token" "00000000-0000-0000-0000-000000000001" --https_server_port=0"#).unwrap();
            assert_eq!(
                parsed[0],
                r"C:\Program Files\Antigravity\resources\bin\language_server.exe"
            );
            assert_eq!(flag(&parsed, "--csrf_token").unwrap(), Some(NONCE));
        }
    }

    #[test]
    fn windows_quota_supports_hub_legacy_and_agy_without_guessing_between_accounts() {
        let (mut roots, home, hub) = context();
        roots.push(r"C:\Program Files\Antigravity IDE".into());
        let legacy=Binding{pid:43,executable:r"C:\Program Files\Antigravity IDE\resources\app\extensions\antigravity\bin\language_server_windows_arm.exe".into(),identity:"start-two".into()};
        let legacy_args = args(&legacy.executable, "--extension_server_port=53000");
        assert!(planned(
            &snapshot(&hub, args(&hub.executable, "--subclient_type=hub")),
            std::slice::from_ref(&hub),
            &roots,
            &home
        )
        .unwrap()
        .is_some());
        assert!(planned(
            &snapshot(&legacy, legacy_args.clone()),
            std::slice::from_ref(&legacy),
            &roots,
            &home
        )
        .unwrap()
        .is_some());
        let agy = Binding {
            pid: 44,
            executable: r"C:\Users\Fixture User\.gemini\bin\agy.exe".into(),
            identity: "start-three".into(),
        };
        let mut agy_args = args(&agy.executable, "--hub");
        agy_args.push("--hub-port=53100".into());
        let mut data = snapshot(&agy, agy_args.clone());
        data["processes"][0]["ports"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!({"address":"0.0.0.0","port":53102,"ownerPid":44}));
        let server = planned(&data, std::slice::from_ref(&agy), &roots, &home)
            .unwrap()
            .unwrap();
        assert_eq!(server.targets()[0].port, 53102);
        let mut mixed = snapshot(&hub, args(&hub.executable, "--standalone"));
        mixed["processes"]
            .as_array_mut()
            .unwrap()
            .push(snapshot(&legacy, legacy_args)["processes"][0].clone());
        assert_eq!(
            planned(&mixed, &[hub.clone(), legacy.clone()], &roots, &home)
                .unwrap()
                .unwrap()
                .binding
                .pid,
            42
        );
        mixed["processes"]
            .as_array_mut()
            .unwrap()
            .push(data["processes"][0].clone());
        assert!(planned(&mixed, &[hub.clone(), legacy, agy], &roots, &home).is_err());
        let mut duplicate = args(&hub.executable, "--standalone");
        duplicate.push(format!("--csrf_token={NONCE}"));
        assert!(planned(
            &snapshot(&hub, duplicate),
            std::slice::from_ref(&hub),
            &roots,
            &home
        )
        .is_err());
        assert!(process_name("LANGUAGE_SERVER_WINDOWS_X64.EXE"));
        assert!(!process_name("some-language-server.exe"));
    }

    #[test]
    fn windows_quota_revalidates_identity_and_uses_nonforcing_quota_fallbacks() {
        let (roots, home, binding) = context();
        let data = snapshot(&binding, args(&binding.executable, "--standalone"));
        let server = || {
            planned(&data, std::slice::from_ref(&binding), &roots, &home)
                .unwrap()
                .unwrap()
        };
        let now = 1_800_000_000.0;
        let reading = probe(
            server(),
            now,
            |_, method, _| {
                if method == Method::Status {
                    Some(status())
                } else {
                    None
                }
            },
            || Ok(Some(server())),
        );
        assert_eq!(reading.state, "available");
        assert_eq!(reading.windows[0].used_percent, Some(25.0));
        assert!(!serde_json::to_string(&reading)
            .unwrap()
            .contains("DO-NOT-PROJECT"));
        let dropped = probe(
            server(),
            now,
            |_, _, _| Some(status()),
            || {
                let mut changed = server();
                changed.binding.identity = "new-process".into();
                Ok(Some(changed))
            },
        );
        assert_eq!(dropped.state, "unavailable");
        let dropped = probe(
            server(),
            now,
            |_, _, _| Some(status()),
            || {
                let mut changed = server();
                changed.sockets.clear();
                Ok(Some(changed))
            },
        );
        assert_eq!(dropped.state, "unavailable");
        for method in [Method::Status, Method::Summary] {
            assert!(method.body().get("forceRefresh").is_none());
            let target = Target {
                port: 53100,
                host: Loopback::V4,
            };
            let request = reqwest::blocking::Client::new()
                .post(target.url(method))
                .header("X-Codeium-Csrf-Token", NONCE)
                .json(&method.body())
                .build()
                .unwrap();
            assert!(request.headers().get("Authorization").is_none());
            assert!(request.headers().get("Cookie").is_none());
        }
        let summary = serde_json::json!({"response":{"groups":[{"displayName":"Fixture Gemini","buckets":[{"bucketId":"gemini-5h","window":"5h","remaining":{"case":"remainingFraction","value":0.75},"resetTime":"2027-01-16T09:00:00Z"}]}]}});
        let mut methods = Vec::new();
        let reading = probe(
            server(),
            now,
            |_, method, _| {
                methods.push(method);
                if method == Method::Summary {
                    Some(summary.clone())
                } else {
                    panic!("a valid summary must not issue a legacy request")
                }
            },
            || Ok(Some(server())),
        );
        assert_eq!(methods.len(), 1);
        assert!(methods[0] == Method::Summary);
        assert_eq!(reading.state, "available");
        assert_eq!(reading.windows[0].used_percent, Some(25.0));
        let mut methods = Vec::new();
        let fallback = probe(
            server(),
            now,
            |_, method, _| {
                methods.push(method);
                if method == Method::Summary {
                    Some(serde_json::json!({"response":{"groups":[]}}))
                } else {
                    Some(status())
                }
            },
            || Ok(Some(server())),
        );
        assert_eq!(fallback.windows[0].used_percent, Some(25.0));
        assert!(methods == [Method::Summary, Method::Status]);
        let snake = serde_json::json!({"user_status":{"cascade_model_config_data":{"client_model_configs":[{"label":"Fixture","quota_info":{"remaining_fraction":0.0,"reset_time":"2027-01-16T09:00:00Z"}}]}}});
        assert_eq!(
            decode_reply(&snake, Method::Status, now).unwrap().windows[0].used_percent,
            Some(100.0)
        );
        let mut bad = summary.clone();
        bad["response"]["groups"][0]["buckets"][0]["remaining"]["value"] = true.into();
        assert!(decode_reply(&bad, Method::Summary, now).is_none());
        let mut disabled = summary.clone();
        disabled["response"]["groups"][0]["buckets"][0]["disabled"] = true.into();
        assert!(decode_reply(&disabled, Method::Summary, now).is_none());
        let mut stale = summary.clone();
        stale["response"]["groups"][0]["buckets"][0]["resetTime"] = Value::Null;
        assert_eq!(
            decode_reply(&stale, Method::Summary, now).unwrap().state,
            "stale"
        );
    }
}
