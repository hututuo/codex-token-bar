//! Windows Hub, IDE LSP and agy --hub discovery. No client launch, remote
//! CIM session, account credentials, forceRefresh, or arbitrary request URL.
use super::{parse_quota_summary, unavailable, QuotaProviderSnapshot, MAX_BYTES};
use serde::Deserialize;
use serde_json::Value;
use std::path::Path;

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
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Method {
    Summary,
}
impl Method {
    fn name(self) -> &'static str {
        "RetrieveUserQuotaSummary"
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
        // agy can also be running foreground CLI commands. A recognized image
        // without a server mode is not a quota endpoint or another account.
        if !mode {
            continue;
        }
        let app_data = flag(&args, "--app_data_dir")?;
        if kind == Kind::Ide
            && !app_data.is_some_and(|s| ["antigravity", "antigravity-ide"].contains(&s))
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
    let _ = method;
    let reading = parse_quota_summary(value, now)?;
    (!reading.windows.is_empty()).then_some(reading)
}

fn probe(
    server: Server,
    now: f64,
    mut query: impl FnMut(Target, Method, &str) -> Option<Value>,
    rediscover: impl FnOnce() -> Result<Option<Server>, ()>,
) -> QuotaProviderSnapshot {
    for target in server.targets() {
        for method in [Method::Summary] {
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
    fn summary() -> Value {
        serde_json::json!({"response":{"groups":[{"buckets":[
            {"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2027-01-16T09:00:00Z"},
            {"bucketId":"gemini-weekly","remaining":{"remainingFraction":0.6},"resetTimeUtc":"2027-01-16T09:00:00Z"},
            {"bucketId":"3p-5h","remaining":{"case":"remainingFraction","value":0.4},"resetTime":"2027-01-16T09:00:00Z"},
            {"id":"3p-weekly","remainingFraction":0.25,"resetTime":"2027-01-16T09:00:00Z"},
            {"bucketId":"model-percentage","remainingFraction":0.01}
        ]}]}})
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
            let url = reqwest::Url::parse(&target.url(Method::Summary)).unwrap();
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
        let mut with_cli = mixed.clone();
        with_cli["processes"].as_array_mut().unwrap().push(
            snapshot(&agy, vec![agy.executable.clone(), "--help".into()])["processes"][0].clone(),
        );
        assert_eq!(
            planned(&with_cli, &[hub.clone(), agy.clone()], &roots, &home)
                .unwrap()
                .unwrap()
                .binding
                .pid,
            hub.pid
        );
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
    fn windows_quota_uses_only_summary_and_revalidates_identity() {
        let (roots, home, binding) = context();
        let data = snapshot(&binding, args(&binding.executable, "--standalone"));
        let server = || {
            planned(&data, std::slice::from_ref(&binding), &roots, &home)
                .unwrap()
                .unwrap()
        };
        let now = 1_800_000_000.0;
        let summary = summary();
        let mut methods = Vec::new();
        let reading = probe(
            server(),
            now,
            |_, method, _| {
                methods.push(method);
                Some(summary.clone())
            },
            || Ok(Some(server())),
        );
        assert_eq!(methods, vec![Method::Summary]);
        assert_eq!(Method::Summary.name(), "RetrieveUserQuotaSummary");
        assert_eq!(reading.state, "available");
        assert_eq!(
            reading.windows.iter().map(|window| window.id.as_deref().unwrap()).collect::<Vec<_>>(),
            vec!["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"]
        );
        assert_eq!(
            reading.windows.iter().map(|window| window.label.as_str()).collect::<Vec<_>>(),
            vec!["Gemini · 5h", "Gemini · 7d", "第三方模型 · 5h", "第三方模型 · 7d"]
        );
        assert_eq!(
            reading.windows.iter().map(|window| window.used_percent.unwrap()).collect::<Vec<_>>(),
            vec![25.0, 40.0, 60.0, 75.0]
        );
        assert!(reading.history.is_empty());
        assert!(!serde_json::to_string(&reading).unwrap().contains("DO-NOT-PROJECT"));

        let target = Target { port: 53100, host: Loopback::V4 };
        let request = reqwest::blocking::Client::new()
            .post(target.url(Method::Summary))
            .header("X-Codeium-Csrf-Token", NONCE)
            .json(&Method::Summary.body())
            .build()
            .unwrap();
        assert!(Method::Summary.body().get("forceRefresh").is_none());
        assert!(request.headers().get("Authorization").is_none());
        assert!(request.headers().get("Cookie").is_none());

        let dropped = probe(
            server(),
            now,
            |_, _, _| Some(summary.clone()),
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
            |_, _, _| Some(summary.clone()),
            || {
                let mut changed = server();
                changed.sockets.clear();
                Ok(Some(changed))
            },
        );
        assert_eq!(dropped.state, "unavailable");

        let mut methods = Vec::new();
        let failed = probe(
            server(),
            now,
            |_, method, _| {
                methods.push(method);
                Some(serde_json::json!({"response":{"groups":[]}}))
            },
            || Ok(Some(server())),
        );
        assert_eq!(failed.state, "unavailable");
        assert_eq!(methods, vec![Method::Summary]);

        let legacy = serde_json::json!({"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[
            {"label":"Gemini","quotaInfo":{"remainingFraction":0.75}}
        ]}}});
        assert!(decode_reply(&legacy, Method::Summary, now).is_none());
        let mut error = summary.clone();
        error["code"] = 13.into();
        assert!(decode_reply(&error, Method::Summary, now).is_none());
        let mut bad_percent = summary.clone();
        bad_percent["response"]["groups"][0]["buckets"][0]["remainingFraction"] = true.into();
        assert_eq!(decode_reply(&bad_percent, Method::Summary, now).unwrap().windows.len(), 3);
        let mut disabled = summary.clone();
        disabled["response"]["groups"][0]["buckets"][0]["disabled"] = true.into();
        assert_eq!(decode_reply(&disabled, Method::Summary, now).unwrap().windows.len(), 3);
        let mut stale = summary.clone();
        stale["response"]["groups"][0]["buckets"][0]["resetTime"] = Value::Null;
        assert_eq!(decode_reply(&stale, Method::Summary, now).unwrap().state, "stale");
        let mut duplicate = summary.clone();
        let bucket = duplicate["response"]["groups"][0]["buckets"][0].clone();
        duplicate["response"]["groups"][0]["buckets"].as_array_mut().unwrap().push(bucket);
        assert!(decode_reply(&duplicate, Method::Summary, now).is_none());
    }

    #[test]
    fn windows_decode_matches_shared_quota_summary_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../fixtures/antigravity-quota-summary.json"
        ))
        .unwrap();
        for row in fixture["cases"].as_array().unwrap() {
            let value = parse_quota_summary(&row["data"], row["now"].as_f64().unwrap())
                .unwrap_or_else(unavailable);
            assert_eq!(value.state, row["expectedState"].as_str().unwrap(), "{}", row["name"]);
            assert_eq!(
                value.windows.iter().map(|window| window.id.as_deref().unwrap()).collect::<Vec<_>>(),
                row["ids"].as_array().unwrap().iter().map(|value| value.as_str().unwrap()).collect::<Vec<_>>(),
                "{}",
                row["name"]
            );
            for (window, used) in value.windows.iter().zip(row["used"].as_array().unwrap()) {
                assert!((window.used_percent.unwrap() - used.as_f64().unwrap()).abs() < 0.000001);
            }
        }
    }
}
