//! Authorized loopback query to an already-running Antigravity client.
//! No OAuth, provider URL, client launch, forceRefresh or remote fallback.
use super::multi_client_product::{QuotaProviderSnapshot, QuotaProviderWindow};
use serde_json::Value;
use std::path::Path;
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

#[cfg(any(windows, test))]
mod windows;

pub const SOURCE: &str = "local-antigravity-rpc";
const MAX_BYTES: usize = 512 * 1024;

fn unavailable() -> QuotaProviderSnapshot {
    QuotaProviderSnapshot {
        client: "antigravity".into(),
        state: "unavailable".into(),
        source: SOURCE.into(),
        captured_at: None,
        windows: vec![],
        history: Vec::new(),
        notice: "当前 Antigravity 本机语言服务额度不可用；不改用其他账号的旧缓存，不启动客户端。"
            .into(),
    }
}

pub fn decode(bytes: &[u8], now: f64) -> QuotaProviderSnapshot {
    if bytes.len() > MAX_BYTES || !now.is_finite() {
        return unavailable();
    }
    let Ok(root) = serde_json::from_slice::<Value>(bytes) else {
        return unavailable();
    };
    parse_quota_summary(&root, now).unwrap_or_else(unavailable)
}

pub(super) fn parse_quota_summary(
    envelope: &Value,
    now: f64,
) -> Option<QuotaProviderSnapshot> {
    if !now.is_finite() || !successful_code(envelope) {
        return None;
    }
    let summary = envelope
        .get("response")
        .or_else(|| envelope.get("summary"))
        .unwrap_or(envelope);
    if !successful_code(summary) {
        return None;
    }
    let groups = summary.get("groups")?.as_array()?;
    if groups.len() > 128 {
        return None;
    }
    let mut windows = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut bucket_count = 0;
    for group in groups {
        let buckets = match group.get("buckets") {
            None | Some(Value::Null) => continue,
            Some(value) => value.as_array()?,
        };
        bucket_count += buckets.len();
        if bucket_count > 128 {
            return None;
        }
        for bucket in buckets {
            if bucket.get("disabled").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            let Some(id) = bucket
                .get("bucketId")
                .or_else(|| bucket.get("bucket_id"))
                .or_else(|| bucket.get("id"))
                .and_then(Value::as_str)
            else {
                continue;
            };
            let label = match id {
                "gemini-5h" => "Gemini · 5h",
                "gemini-weekly" => "Gemini · 7d",
                "3p-5h" => "第三方模型 · 5h",
                "3p-weekly" => "第三方模型 · 7d",
                _ => continue,
            };
            if !seen.insert(id.to_owned()) {
                return None;
            }
            let Some(remaining) = bucket
                .get("remainingFraction")
                .or_else(|| bucket.get("remaining_fraction"))
                .or_else(|| {
                    bucket.get("remaining").and_then(|value| {
                        value
                            .get("remainingFraction")
                            .or_else(|| value.get("remaining_fraction"))
                    })
                })
                .or_else(|| {
                    bucket
                        .get("remaining")
                        .filter(|value| value.get("case").and_then(Value::as_str) == Some("remainingFraction"))
                        .and_then(|value| value.get("value"))
                })
                .and_then(Value::as_f64)
                .filter(|value| value.is_finite() && (0.0..=1.0).contains(value))
            else {
                continue;
            };
            let reset = bucket
                .get("resetTime")
                .or_else(|| bucket.get("reset_time"))
                .or_else(|| bucket.get("resetTimeUtc"))
                .or_else(|| bucket.get("reset_time_utc"))
                .and_then(Value::as_str)
                .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok());
            windows.push(QuotaProviderWindow {
                id: Some(id.into()),
                label: label.into(),
                used_percent: Some((1.0 - remaining) * 100.0),
                resets_at: reset.and_then(|value| value.format(&Rfc3339).ok()),
            });
        }
    }
    if windows.is_empty() {
        return None;
    }
    let stale = windows.iter().any(|window| {
        window
            .resets_at
            .as_deref()
            .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
            .map_or(true, |value| value.unix_timestamp() as f64 <= now)
    });
    let captured_at = OffsetDateTime::from_unix_timestamp_nanos((now * 1_000_000_000.0) as i128)
        .ok()
        .and_then(|value| value.format(&Rfc3339).ok());
    Some(QuotaProviderSnapshot {
        client: "antigravity".into(),
        state: if stale { "stale" } else { "available" }.into(),
        source: SOURCE.into(),
        captured_at,
        windows,
        history: Vec::new(),
        notice: "当前运行的 Antigravity 本机语言服务返回值；未强制刷新。客户端可能自行联网。读取时间不代表上游采样时间，额度池分别展示。".into(),
    })
}

fn successful_code(value: &Value) -> bool {
    match value.get("code") {
        None => true,
        Some(Value::String(code)) => code == "OK",
        Some(Value::Number(code)) => {
            code.as_i64() == Some(0)
                || code.as_u64() == Some(0)
                || code.as_f64() == Some(0.0)
        }
        _ => false,
    }
}

#[derive(PartialEq, Eq)]
struct Endpoint {
    pid: i32,
    executable: String,
    port: u16,
    csrf: String,
}

fn csrf_valid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

fn running_servers(listing: &str, home: &Path) -> Vec<(i32, String)> {
    let paths = [
        "/Applications/Antigravity.app/Contents/Resources/bin/language_server".to_owned(),
        home.join("Applications/Antigravity.app/Contents/Resources/bin/language_server")
            .to_string_lossy()
            .into_owned(),
    ];
    listing
        .lines()
        .filter_map(|l| {
            let l = l.trim();
            let at = l.find(char::is_whitespace)?;
            let pid: i32 = l[..at].parse().ok()?;
            let path = l[at..].trim();
            (pid > 1 && paths.iter().any(|p| p == path)).then(|| (pid, path.to_owned()))
        })
        .collect()
}

fn endpoint(
    pid: i32,
    executable: &str,
    command: &str,
    listeners: &str,
    log: &str,
) -> Option<Endpoint> {
    let args: Vec<_> = command
        .strip_prefix(executable)?
        .strip_prefix(' ')?
        .split_ascii_whitespace()
        .collect();
    if !args.contains(&"--standalone") || !listeners.lines().any(|l| l == format!("p{pid}")) {
        return None;
    }
    let flag = |name: &str| -> Option<&str> {
        args.iter().enumerate().find_map(|(i, a)| {
            if *a == name {
                args.get(i + 1).copied()
            } else {
                a.strip_prefix(name)?.strip_prefix('=')
            }
        })
    };
    let csrf = flag("--csrf_token")?;
    if !csrf_valid(csrf) {
        return None;
    }
    let requested: u16 = flag("--https_server_port")?.parse().ok()?;
    let port = if requested != 0 {
        requested
    } else {
        log.lines()
            .filter_map(|l| {
                l.split_once("Language server listening on random port at ")?
                    .1
                    .trim()
                    .strip_suffix(" for HTTPS (gRPC)")?
                    .parse::<u16>()
                    .ok()
            })
            .last()?
    };
    if port < 1024
        || !listeners.lines().any(|l| {
            (l.starts_with("n127.0.0.1:") || l.starts_with("n[::1]:"))
                && l.rsplit(':').next() == Some(port.to_string().as_str())
        })
    {
        return None;
    }
    Some(Endpoint {
        pid,
        executable: executable.into(),
        port,
        csrf: csrf.into(),
    })
}

#[cfg(target_os = "macos")]
fn command(executable: &str, args: &[&str]) -> Option<String> {
    use std::{
        process::{Command, Stdio},
        time::{Duration, Instant},
    };
    let mut child = Command::new(executable)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("LC_ALL", "C")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let output = super::process_tail::ProcessPipeTail::spawn(
        child.stdout.take(),
        1_048_577,
        Duration::from_millis(100),
    );
    let deadline = Instant::now() + Duration::from_secs(3);
    let success = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.success(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break false;
            }
        }
    };
    let text = output.finish();
    (success && text.len() <= 1_048_576).then_some(text)
}

#[cfg(target_os = "macos")]
fn discover(pid: i32, executable: &str, home: &Path) -> Option<Endpoint> {
    use std::io::Read;
    let mut path = [0_u8; 4096];
    let n = unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
    if n <= 0
        || std::ffi::CStr::from_bytes_until_nul(&path)
            .ok()?
            .to_str()
            .ok()?
            != executable
    {
        return None;
    }
    let args = command("/bin/ps", &["-p", &pid.to_string(), "-o", "command="])?;
    let listeners = command(
        "/usr/sbin/lsof",
        &[
            "-nP",
            "-a",
            "-p",
            &pid.to_string(),
            "-iTCP",
            "-sTCP:LISTEN",
            "-Fn",
        ],
    )?;
    let log_path = home.join("Library/Logs/Antigravity/language_server.log");
    let mut log = Vec::new();
    if std::fs::symlink_metadata(&log_path)
        .ok()
        .is_some_and(|m| m.is_file())
    {
        if let Ok(file) = std::fs::File::open(log_path) {
            let _ = file.take(131_072).read_to_end(&mut log);
        }
    }
    endpoint(
        pid,
        executable,
        &args,
        &listeners,
        &String::from_utf8_lossy(&log),
    )
}

#[cfg(target_os = "macos")]
pub fn read(home: &Path, now: f64) -> Option<QuotaProviderSnapshot> {
    use std::{io::Read, time::Duration};
    let uid = unsafe { libc::getuid() }.to_string();
    let Some(listing) = command("/bin/ps", &["-U", &uid, "-o", "pid=,comm="]) else {
        return Some(unavailable());
    };
    let servers = running_servers(&listing, home);
    if servers.is_empty() {
        return None;
    }
    let probe = || -> Option<QuotaProviderSnapshot> {
        if servers.len() != 1 {
            return None;
        }
        let (pid, executable) = &servers[0];
        let endpoint = discover(*pid, executable, home)?;
        let client = reqwest::blocking::Client::builder()
            .no_proxy()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .danger_accept_invalid_certs(true)
            .connect_timeout(Duration::from_secs(2))
            .timeout(Duration::from_secs(5))
            .build()
            .ok()?;
        let response = client.post(format!("https://127.0.0.1:{}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary", endpoint.port))
            .header("Connect-Protocol-Version", "1").header("X-Codeium-Csrf-Token", &endpoint.csrf)
            .json(&serde_json::json!({"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}})).send().ok()?;
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
        if bytes.len() > MAX_BYTES || discover(*pid, executable, home)? != endpoint {
            return None;
        }
        Some(decode(&bytes, now))
    };
    Some(probe().unwrap_or_else(unavailable))
}

#[cfg(windows)]
pub fn read(home: &Path, now: f64) -> Option<QuotaProviderSnapshot> {
    windows::read(home, now)
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn read(_home: &Path, _now: f64) -> Option<QuotaProviderSnapshot> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_model_quota_responses_are_not_used_as_pool_history() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../fixtures/antigravity-local-rpc.json"
        ))
        .unwrap();
        for row in fixture["cases"].as_array().unwrap() {
            let value = decode(
                &serde_json::to_vec(&row["data"]).unwrap(),
                row["now"].as_f64().unwrap(),
            );
            assert_eq!(value.state, "unavailable", "{}", row["name"]);
        }
        assert_eq!(decode(&vec![b' '; MAX_BYTES + 1], 0.0).state, "unavailable");
    }

    #[test]
    fn shared_quota_summary_fixture_keeps_only_stable_pool_ids() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../fixtures/antigravity-quota-summary.json"
        ))
        .unwrap();
        for row in fixture["cases"].as_array().unwrap() {
            let value = decode(
                &serde_json::to_vec(&row["data"]).unwrap(),
                row["now"].as_f64().unwrap(),
            );
            assert_eq!(
                value.state,
                row["expectedState"].as_str().unwrap(),
                "{}",
                row["name"]
            );
            assert_eq!(
                value
                    .windows
                    .iter()
                    .map(|window| window.id.as_deref().unwrap())
                    .collect::<Vec<_>>(),
                row["ids"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|value| value.as_str().unwrap())
                    .collect::<Vec<_>>()
            );
            for (window, used) in value.windows.iter().zip(row["used"].as_array().unwrap()) {
                assert!((window.used_percent.unwrap() - used.as_f64().unwrap()).abs() < 0.000001);
            }
            assert!(value.history.is_empty());
        }
    }
    #[test]
    fn discovery_requires_installed_process_owned_loopback_port_and_current_csrf() {
        let path = "/Applications/Antigravity.app/Contents/Resources/bin/language_server";
        let args = format!("{path} --standalone --https_server_port 0 --csrf_token 00000000-0000-0000-0000-000000000001");
        let log = "I server.go] Language server listening on random port at 53100 for HTTPS (gRPC)";
        let listeners = "p42\nn127.0.0.1:53100\n";
        assert_eq!(
            running_servers(
                &format!("42 {path}\n43 /tmp/language_server"),
                Path::new("/fixture")
            )
            .len(),
            1
        );
        let endpoint = endpoint(42, path, &args, listeners, log).unwrap();
        assert_eq!(endpoint.port, 53100);
        assert!(super::endpoint(42, path, &args, "p42\nn*:53100", log).is_none());
        assert!(super::endpoint(42, path, &args, "p41\nn127.0.0.1:53100", log).is_none());
        assert!(super::endpoint(42, path, &args, listeners, "old log, no HTTPS port").is_none());
        assert!(super::endpoint(
            42,
            path,
            &args.replace("--standalone", "--other"),
            listeners,
            log
        )
        .is_none());
    }
}
