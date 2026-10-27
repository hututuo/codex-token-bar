use super::scoring;
use crate::core::quota::codex_binary::find_codex_binary_with_report;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc,
};
use std::time::{Duration, Instant};

const MAX_PROTOCOL_LINE: u64 = 2 * 1024 * 1024;
const MAX_PENDING_EVENTS: usize = 256;
const GENERATION_TIMEOUT: Duration = Duration::from_secs(240);

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sample {
    pub expected_count: usize,
    pub returned_count: usize,
    pub out_of_range_count: usize,
    pub numbers: Vec<i64>,
    pub usage: Option<Value>,
}

#[derive(Default)]
struct ProbeOutput {
    final_text: Option<String>,
    unphased: Vec<String>,
    usage: Option<Value>,
}

struct ActiveProbe {
    thread_id: String,
    turn_id: Option<String>,
    expected: usize,
    output: ProbeOutput,
    sample: Option<Sample>,
}

fn retain_pending(pending: &mut Vec<Value>, message: Value) -> Result<(), String> {
    if pending.len() >= MAX_PENDING_EVENTS {
        return Err("Codex 事件队列超过上限".into());
    }
    pending.push(message);
    Ok(())
}

fn route_event<F>(
    message: Value,
    probes: &mut [ActiveProbe],
    pending: &mut Vec<Value>,
    retain_unmatched: bool,
    progress: &mut F,
) -> Result<(), String>
where
    F: FnMut(usize, Option<Sample>) -> Result<(), String>,
{
    let Some(thread_id) = message["params"]["threadId"].as_str() else {
        return Ok(());
    };
    let Some((index, probe)) = probes
        .iter_mut()
        .enumerate()
        .find(|(_, probe)| probe.thread_id == thread_id)
    else {
        if retain_unmatched {
            return retain_pending(pending, message);
        }
        return Ok(());
    };
    if probe.turn_id.is_none() {
        let turn_id = message["params"]["turnId"]
            .as_str()
            .or_else(|| message["params"]["turn"]["id"].as_str());
        if let Some(turn_id) = turn_id {
            probe.turn_id = Some(turn_id.to_owned());
        } else {
            return retain_pending(pending, message);
        }
    }
    if probe.sample.is_some() {
        if message["method"] == "thread/tokenUsage/updated" {
            probe.sample.as_mut().unwrap().usage =
                Some(message["params"]["tokenUsage"]["last"].clone());
            return Ok(());
        }
        return Err("探针在轮次完成后继续发送事件".into());
    }
    if let Some(sample) = probe.output.accept(
        message,
        &probe.thread_id,
        probe.turn_id.as_deref().expect("turn ID was just captured"),
        probe.expected,
    )? {
        probe.sample = Some(sample.clone());
        progress(index + 1, Some(sample))?;
    }
    Ok(())
}

fn route_pending_events<F>(
    probes: &mut [ActiveProbe],
    pending: &mut Vec<Value>,
    progress: &mut F,
) -> Result<(), String>
where
    F: FnMut(usize, Option<Sample>) -> Result<(), String>,
{
    let queued = std::mem::take(pending);
    for message in queued {
        route_event(message, probes, pending, true, progress)?;
    }
    Ok(())
}

impl ProbeOutput {
    fn accept(
        &mut self,
        message: Value,
        thread_id: &str,
        turn_id: &str,
        expected: usize,
    ) -> Result<Option<Sample>, String> {
        let p = &message["params"];
        if p["threadId"] != thread_id {
            return Ok(None);
        }
        if let Some(id) = p["turnId"].as_str() {
            if id != turn_id {
                return Err("探针出现了未请求的轮次".into());
            }
        }
        match message["method"].as_str().unwrap_or("") {
            "turn/started" if p["turn"]["id"] != turn_id => {
                return Err("探针出现了未请求的轮次".into())
            }
            "item/started" | "item/updated" | "item/completed"
                if !matches!(
                    p["item"]["type"].as_str(),
                    Some("userMessage" | "agentMessage" | "reasoning")
                ) =>
            {
                return Err("探针调用了工具，样本已拒绝".into())
            }
            "item/completed" if p["item"]["type"] == "agentMessage" => {
                if let Some(text) = p["item"]["text"].as_str() {
                    if text.len() > 5000 {
                        return Err("探针回答超过长度上限".into());
                    }
                    match p["item"]["phase"].as_str() {
                        Some("final_answer" | "final") => {
                            if self.final_text.is_some() {
                                return Err("探针出现了多个最终回答".into());
                            }
                            self.final_text = Some(text.into());
                        }
                        None => {
                            if self.unphased.len() >= 2 {
                                return Err("探针回答阶段不明确".into());
                            }
                            self.unphased.push(text.into());
                        }
                        _ => {}
                    }
                }
            }
            "thread/tokenUsage/updated" => self.usage = Some(p["tokenUsage"]["last"].clone()),
            "error" if p["willRetry"] != true => {
                return Err("Codex 推理失败，请检查账号额度与连接".into())
            }
            "turn/completed" => {
                if p["turn"]["id"] != turn_id || p["turn"]["status"] != "completed" {
                    return Err("探针未成功完成".into());
                }
                let text = self
                    .final_text
                    .take()
                    .or_else(|| {
                        if self.unphased.len() == 1 {
                            self.unphased.pop()
                        } else {
                            None
                        }
                    })
                    .ok_or("未收到完整探针回答")?;
                let (numbers, returned_count, out_of_range_count) =
                    scoring::parse_output(&text, expected)?;
                return Ok(Some(Sample {
                    expected_count: expected,
                    returned_count,
                    out_of_range_count,
                    numbers,
                    usage: self.usage.take(),
                }));
            }
            _ => {}
        }
        Ok(None)
    }
}

struct Client {
    child: Child,
    input: ChildStdin,
    messages: mpsc::Receiver<Result<Value, String>>,
    next_id: u64,
    pending_events: Vec<Value>,
    #[cfg(windows)]
    _job: Job,
}

impl Client {
    fn spawn(home: &Path) -> Result<Self, String> {
        let mut command = Command::new(find_codex_binary_with_report()?.path);
        command
            .args(["app-server", "--listen", "stdio://", "--disable", "plugins"])
            .env("CODEX_HOME", home)
            .env_remove("ELECTRON_RUN_AS_NODE")
            .env_remove("NODE_OPTIONS")
            .env_remove("TAURI_SIGNING_PRIVATE_KEY")
            .env_remove("TAURI_SIGNING_PRIVATE_KEY_PATH")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        let mut child = command
            .spawn()
            .map_err(|e| format!("无法启动 Codex：{e}"))?;
        #[cfg(windows)]
        let job = match Job::attach(&child) {
            Ok(job) => job,
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(e);
            }
        };
        let input = child.stdin.take().ok_or("Codex 输入不可用")?;
        let stdout = child.stdout.take().ok_or("Codex 输出不可用")?;
        let (send, messages) = mpsc::sync_channel(128);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let mut line = Vec::new();
                let outcome = (&mut reader)
                    .take(MAX_PROTOCOL_LINE + 1)
                    .read_until(b'\n', &mut line);
                let value = match outcome {
                    Ok(0) => break,
                    Ok(_) if line.len() as u64 > MAX_PROTOCOL_LINE => {
                        Err("Codex 消息超过上限".into())
                    }
                    Ok(_) => {
                        serde_json::from_slice(&line).map_err(|_| "Codex 返回了无效协议消息".into())
                    }
                    Err(_) => Err("读取 Codex 消息失败".into()),
                };
                let failed = value.is_err();
                if send.send(value).is_err() || failed {
                    break;
                }
            }
        });
        Ok(Self {
            child,
            input,
            messages,
            next_id: 0,
            pending_events: Vec::new(),
            #[cfg(windows)]
            _job: job,
        })
    }
    fn write(&mut self, message: Value) -> Result<(), String> {
        serde_json::to_writer(&mut self.input, &message).map_err(|_| "写入 Codex 请求失败")?;
        self.input
            .write_all(b"\n")
            .and_then(|_| self.input.flush())
            .map_err(|_| "写入 Codex 请求失败".into())
    }
    fn receive(&mut self, cancel: &AtomicBool, deadline: Instant) -> Result<Value, String> {
        loop {
            if cancel.load(Ordering::SeqCst) {
                return Err("检测已取消".into());
            }
            if Instant::now() >= deadline {
                return Err("检测请求超时".into());
            }
            match self.messages.recv_timeout(Duration::from_millis(100)) {
                Ok(Ok(message)) => {
                    if message.get("method").is_some() && message.get("id").is_some() {
                        self.write(json!({"jsonrpc":"2.0","id":message["id"],"error":{"code":-32601,"message":"ModelTrace probes do not grant permissions or execute tools"}}))?;
                        return Err("探针请求了工具或额外权限，已终止".into());
                    }
                    return Ok(message);
                }
                Ok(Err(e)) => return Err(e),
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err("Codex 检测进程已退出".into())
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
        }
    }
    fn request(
        &mut self,
        method: &str,
        params: Value,
        cancel: &AtomicBool,
    ) -> Result<Value, String> {
        let mut pending = Vec::new();
        let result = self.request_with_events(method, params, cancel, |message| {
            retain_pending(&mut pending, message)
        });
        self.pending_events.extend(pending);
        result
    }

    fn request_with_events<F>(
        &mut self,
        method: &str,
        params: Value,
        cancel: &AtomicBool,
        mut on_event: F,
    ) -> Result<Value, String>
    where
        F: FnMut(Value) -> Result<(), String>,
    {
        self.next_id += 1;
        let id = self.next_id;
        self.write(json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))?;
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let message = self.receive(cancel, deadline)?;
            if message["id"] == id {
                if message.get("error").is_some() {
                    return Err(format!(
                        "Codex {method} 请求失败，请检查登录、模型访问权限和本机版本"
                    ));
                }
                return Ok(message["result"].clone());
            }
            on_event(message)?;
        }
    }

    fn interrupt_active(&mut self, probes: &[ActiveProbe]) {
        for probe in probes
            .iter()
            .filter(|probe| probe.sample.is_none() && probe.turn_id.is_some())
        {
            let Some(turn_id) = probe.turn_id.as_deref() else {
                continue;
            };
            self.next_id = self.next_id.saturating_add(1);
            let _ = self.write(json!({
                "jsonrpc":"2.0",
                "id":self.next_id,
                "method":"turn/interrupt",
                "params":{"threadId":probe.thread_id,"turnId":turn_id}
            }));
        }
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        // Kill only this owned probe transport (and its process group on Unix).
        #[cfg(unix)]
        unsafe {
            libc::kill(-(self.child.id() as i32), libc::SIGKILL);
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub struct ProbeSession {
    client: Option<Client>,
}
impl ProbeSession {
    pub fn connect(home: &Path, cancel: &AtomicBool) -> Result<Self, String> {
        let mut client = Client::spawn(home)?;
        client.request("initialize", json!({"clientInfo":{"name":"codex_token_bar_modeltrace","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}), cancel)?;
        client.write(json!({"jsonrpc":"2.0","method":"initialized"}))?;
        Ok(Self {
            client: Some(client),
        })
    }
    pub fn sample(
        &mut self,
        work: &Path,
        model: &str,
        expected: usize,
        cancel: &AtomicBool,
    ) -> Result<Sample, String> {
        let client = self.client.as_mut().ok_or("探针连接已关闭")?;
        let started = client.request(
            "thread/start",
            json!({
                "model":model,"allowProviderModelFallback":false,
                "cwd":work,"ephemeral":true,"approvalPolicy":"never",
                "config":{"model_reasoning_effort":"low"}
            }),
            cancel,
        )?;
        if started["model"] != model
            || started["reasoningEffort"] != "low"
            || started["thread"]["ephemeral"] != true
            || !started["thread"]["path"].is_null()
        {
            return Err("Codex 返回的模型、思考强度或临时会话信息与请求不符".into());
        }
        let thread_id = started["thread"]["id"]
            .as_str()
            .ok_or("Codex 未返回探针会话 ID")?
            .to_string();
        let prompt = format!("这是一次独立的无语义数值选择记录。为 {expected} 个位置分别凭第一反应选择一个 1 到 355（含端点）的整数。每个位置都要单独选择；不要从 1 开始计数，不要连续递增或递减，也不要采用等差、循环、重复区块或其他规则化模式。允许重复；每项写出后不要排序、重排、去重、替换或修正。本任务必须由当前语言模型直接完成，禁止调用任何工具、读取文件、运行代码、计算器、搜索、API、外部随机数生成器或其他模型。只返回一个完整 JSON 整数数组，不要解释。");
        let turn = client.request(
            "turn/start",
            json!({"threadId":thread_id,"input":[{"type":"text","text":prompt}],"effort":"low"}),
            cancel,
        )?;
        let turn_id = turn["turn"]["id"]
            .as_str()
            .ok_or("Codex 未返回探针轮次 ID")?
            .to_string();
        let deadline = Instant::now() + GENERATION_TIMEOUT;
        let mut output = ProbeOutput::default();
        let mut pending = std::mem::take(&mut client.pending_events).into_iter();
        let outcome = (|| loop {
            if cancel.load(Ordering::SeqCst) {
                return Err("检测已取消".into());
            }
            let message = match pending.next() {
                Some(value) => value,
                None => client.receive(cancel, deadline)?,
            };
            if let Some(sample) = output.accept(message, &thread_id, &turn_id, expected)? {
                return Ok(sample);
            }
        })();
        // Best effort interrupt; Drop then reaps the owned transport even on timeout.
        let _ = client.write(json!({"jsonrpc":"2.0","id":999999,"method":"turn/interrupt","params":{"threadId":thread_id,"turnId":turn_id}}));
        outcome
    }

    pub fn sample_three<F>(
        &mut self,
        work: &Path,
        model: &str,
        cancel: &AtomicBool,
        mut progress: F,
    ) -> Result<Vec<Sample>, String>
    where
        F: FnMut(usize, Option<Sample>) -> Result<(), String>,
    {
        let mut client = self.client.take().ok_or("探针连接已关闭")?;
        let mut probes = Vec::with_capacity(super::PROBE_COUNTS.len());
        let mut pending = std::mem::take(&mut client.pending_events);
        let mut generation_deadline = None;
        let result = (|| {
            for (index, expected) in super::PROBE_COUNTS.iter().copied().enumerate() {
                if cancel.load(Ordering::SeqCst) {
                    return Err("检测已取消".into());
                }
                let started = client.request_with_events(
                    "thread/start",
                    json!({
                        "model":model,"allowProviderModelFallback":false,
                        "cwd":work,"ephemeral":true,"approvalPolicy":"never",
                        "config":{"model_reasoning_effort":"low"}
                    }),
                    cancel,
                    |message| route_event(message, &mut probes, &mut pending, true, &mut progress),
                )?;
                if started["model"] != model
                    || started["reasoningEffort"] != "low"
                    || started["thread"]["ephemeral"] != true
                    || !started["thread"]["path"].is_null()
                {
                    return Err("Codex 返回的模型、思考强度或临时会话信息与请求不符".into());
                }
                let thread_id = started["thread"]["id"]
                    .as_str()
                    .ok_or("Codex 未返回探针会话 ID")?
                    .to_owned();
                progress(index + 1, None)?;
                let probe_index = probes.len();
                probes.push(ActiveProbe {
                    thread_id: thread_id.clone(),
                    turn_id: None,
                    expected,
                    output: ProbeOutput::default(),
                    sample: None,
                });
                generation_deadline.get_or_insert_with(|| Instant::now() + GENERATION_TIMEOUT);
                let turn = client.request_with_events(
                    "turn/start",
                    json!({
                        "threadId":thread_id,
                        "input":[{"type":"text","text":prompt(expected)}],
                        "effort":"low"
                    }),
                    cancel,
                    |message| route_event(message, &mut probes, &mut pending, true, &mut progress),
                )?;
                let turn_id = turn["turn"]["id"]
                    .as_str()
                    .ok_or("Codex 未返回探针轮次 ID")?
                    .to_owned();
                if probes[probe_index]
                    .turn_id
                    .as_deref()
                    .is_some_and(|notified_id| notified_id != turn_id)
                {
                    return Err("Codex 的轮次响应与通知不一致".into());
                }
                probes[probe_index].turn_id = Some(turn_id);
                route_pending_events(&mut probes, &mut pending, &mut progress)?;
            }

            let deadline =
                generation_deadline.unwrap_or_else(|| Instant::now() + GENERATION_TIMEOUT);
            while probes.iter().any(|probe| probe.sample.is_none()) {
                if cancel.load(Ordering::SeqCst) {
                    return Err("检测已取消".into());
                }
                let message = if pending.is_empty() {
                    client.receive(cancel, deadline)?
                } else {
                    pending.remove(0)
                };
                route_event(message, &mut probes, &mut pending, false, &mut progress)?;
            }

            let samples = probes
                .iter_mut()
                .map(|probe| probe.sample.take().ok_or_else(|| "探针未完成".into()))
                .collect::<Result<Vec<_>, String>>()?;
            Ok(samples)
        })();

        if result.is_err() {
            client.interrupt_active(&probes);
            // Dropping this owned client terminates and reaps its process group/job.
        } else {
            self.client = Some(client);
        }
        result
    }
}

fn prompt(expected: usize) -> String {
    format!("这是一次独立的无语义数值选择记录。为 {expected} 个位置分别凭第一反应选择一个 1 到 355（含端点）的整数。每个位置都要单独选择；不要从 1 开始计数，不要连续递增或递减，也不要采用等差、循环、重复区块或其他规则化模式。允许重复；每项写出后不要排序、重排、去重、替换或修正。本任务必须由当前语言模型直接完成，禁止调用任何工具、读取文件、运行代码、计算器、搜索、API、外部随机数生成器或其他模型。只返回一个完整 JSON 整数数组，不要解释。")
}

#[cfg(test)]
pub fn sample(
    home: &Path,
    work: &Path,
    model: &str,
    expected: usize,
    cancel: &AtomicBool,
) -> Result<Sample, String> {
    ProbeSession::connect(home, cancel)?.sample(work, model, expected, cancel)
}

#[cfg(windows)]
struct Job(windows_sys::Win32::Foundation::HANDLE);
#[cfg(windows)]
impl Job {
    fn attach(child: &Child) -> Result<Self, String> {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::{Foundation::CloseHandle, System::JobObjects::*};
        // Each job owns only the newly spawned probe; no process lookup by name.
        unsafe {
            let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if handle.is_null() {
                return Err("无法创建探针进程清理范围".into());
            }
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                std::mem::size_of_val(&limits) as u32,
            ) == 0
                || AssignProcessToJobObject(handle, child.as_raw_handle()) == 0
            {
                CloseHandle(handle);
                return Err("无法绑定探针进程清理范围".into());
            }
            Ok(Self(handle))
        }
    }
}
#[cfg(windows)]
impl Drop for Job {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(self.0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn message(method: &str, extra: Value) -> Value {
        message_with_ids(method, "thread", "turn", extra)
    }

    fn message_with_ids(method: &str, thread_id: &str, turn_id: &str, extra: Value) -> Value {
        let mut params = json!({"threadId":thread_id,"turnId":turn_id});
        params
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        json!({"method":method,"params":params})
    }
    fn answer(phase: Value) -> Value {
        message(
            "item/completed",
            json!({"item":{"type":"agentMessage","phase":phase,"text":serde_json::to_string(&vec![42;300]).unwrap()}}),
        )
    }

    fn answer_for(thread_id: &str, turn_id: &str, expected: usize) -> Value {
        message_with_ids(
            "item/completed",
            thread_id,
            turn_id,
            json!({"item":{
                "type":"agentMessage",
                "phase":"final_answer",
                "text":serde_json::to_string(&vec![42;expected]).unwrap()
            }}),
        )
    }

    fn completed_for(thread_id: &str, turn_id: &str) -> Value {
        message_with_ids(
            "turn/completed",
            thread_id,
            turn_id,
            json!({"turn":{"id":turn_id,"status":"completed"}}),
        )
    }

    fn active_probe(index: usize, thread_id: &str, turn_id: &str) -> ActiveProbe {
        ActiveProbe {
            thread_id: thread_id.into(),
            turn_id: Some(turn_id.into()),
            expected: super::super::PROBE_COUNTS[index],
            output: ProbeOutput::default(),
            sample: None,
        }
    }

    #[test]
    fn turn_started_notification_registers_inflight_turn_before_start_reply() {
        let mut probes = vec![ActiveProbe {
            thread_id: "thread-1".into(),
            turn_id: None,
            expected: super::super::PROBE_COUNTS[0],
            output: ProbeOutput::default(),
            sample: None,
        }];
        let mut pending = Vec::new();
        let mut completed_attempts = Vec::new();
        let mut progress = |attempt, sample: Option<Sample>| {
            if sample.is_some() {
                completed_attempts.push(attempt);
            }
            Ok(())
        };

        route_event(
            message_with_ids(
                "turn/started",
                "thread-1",
                "turn-1",
                json!({"turn":{"id":"turn-1"}}),
            ),
            &mut probes,
            &mut pending,
            true,
            &mut progress,
        )
        .unwrap();
        route_event(
            answer_for("thread-1", "turn-1", super::super::PROBE_COUNTS[0]),
            &mut probes,
            &mut pending,
            true,
            &mut progress,
        )
        .unwrap();
        route_event(
            completed_for("thread-1", "turn-1"),
            &mut probes,
            &mut pending,
            true,
            &mut progress,
        )
        .unwrap();

        assert_eq!(probes[0].turn_id.as_deref(), Some("turn-1"));
        assert_eq!(probes[0].sample.as_ref().unwrap().expected_count, 307);
        assert_eq!(completed_attempts, vec![1]);
        assert!(pending.is_empty());
    }

    #[test]
    fn interleaved_turn_events_complete_once_and_return_in_probe_order() {
        let mut probes = vec![
            active_probe(0, "thread-1", "turn-1"),
            active_probe(1, "thread-2", "turn-2"),
            active_probe(2, "thread-3", "turn-3"),
        ];
        let mut pending = Vec::new();
        let mut completed_attempts = Vec::new();
        let mut progress = |attempt, sample: Option<Sample>| {
            if let Some(sample) = sample {
                completed_attempts.push((attempt, sample.expected_count));
            }
            Ok(())
        };

        for event in [
            answer_for("thread-3", "turn-3", super::super::PROBE_COUNTS[2]),
            answer_for("thread-1", "turn-1", super::super::PROBE_COUNTS[0]),
            completed_for("thread-3", "turn-3"),
            answer_for("thread-2", "turn-2", super::super::PROBE_COUNTS[1]),
            completed_for("thread-1", "turn-1"),
            message_with_ids(
                "thread/tokenUsage/updated",
                "thread-1",
                "turn-1",
                json!({"tokenUsage":{"last":{"inputTokens":123}}}),
            ),
            completed_for("thread-2", "turn-2"),
        ] {
            route_event(event, &mut probes, &mut pending, false, &mut progress).unwrap();
        }

        let samples = probes
            .iter()
            .map(|probe| probe.sample.as_ref().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            samples
                .iter()
                .map(|sample| sample.expected_count)
                .collect::<Vec<_>>(),
            super::super::PROBE_COUNTS.to_vec()
        );
        assert_eq!(completed_attempts, vec![(3, 331), (1, 307), (2, 319)]);
        assert_eq!(samples[0].usage, Some(json!({"inputTokens":123})));
        assert!(pending.is_empty());
    }

    #[test]
    fn early_completion_is_queued_until_its_turn_is_registered() {
        let mut probes = Vec::new();
        let mut pending = Vec::new();
        let mut completed_attempts = Vec::new();
        let mut progress = |attempt, sample: Option<Sample>| {
            if sample.is_some() {
                completed_attempts.push(attempt);
            }
            Ok(())
        };

        route_event(
            answer_for("thread-1", "turn-1", super::super::PROBE_COUNTS[0]),
            &mut probes,
            &mut pending,
            true,
            &mut progress,
        )
        .unwrap();
        route_event(
            completed_for("thread-1", "turn-1"),
            &mut probes,
            &mut pending,
            true,
            &mut progress,
        )
        .unwrap();
        assert_eq!(pending.len(), 2);

        probes.push(active_probe(0, "thread-1", "turn-1"));
        route_pending_events(&mut probes, &mut pending, &mut progress).unwrap();
        assert_eq!(probes[0].sample.as_ref().unwrap().expected_count, 307);
        assert!(pending.is_empty());

        let duplicate = route_event(
            completed_for("thread-1", "turn-1"),
            &mut probes,
            &mut pending,
            false,
            &mut progress,
        );
        assert!(duplicate.is_err());
        drop(progress);
        assert_eq!(completed_attempts, vec![1]);
    }

    #[test]
    fn accepts_only_complete_final_answer_for_the_requested_turn() {
        let mut output = ProbeOutput::default();
        assert!(output
            .accept(answer(json!("commentary")), "thread", "turn", 300)
            .unwrap()
            .is_none());
        output
            .accept(answer(json!("final_answer")), "thread", "turn", 300)
            .unwrap();
        let done = message(
            "turn/completed",
            json!({"turn":{"id":"turn","status":"completed"}}),
        );
        let sample = output.accept(done, "thread", "turn", 300).unwrap().unwrap();
        assert_eq!(sample.numbers.len(), 300);
        assert_eq!(sample.expected_count, 300);
        assert_eq!(sample.returned_count, 300);
    }
    #[test]
    fn rejects_tools_wrong_turn_duplicate_final_and_incomplete_turn() {
        for method in ["item/started", "item/completed"] {
            assert!(ProbeOutput::default()
                .accept(
                    message(method, json!({"item":{"type":"commandExecution"}})),
                    "thread",
                    "turn",
                    300
                )
                .is_err());
        }
        assert!(ProbeOutput::default()
            .accept(
                answer(json!("final_answer")),
                "thread",
                "different-turn",
                300
            )
            .is_err());
        let mut output = ProbeOutput::default();
        output
            .accept(answer(json!("final_answer")), "thread", "turn", 300)
            .unwrap();
        assert!(output
            .accept(answer(json!("final_answer")), "thread", "turn", 300)
            .is_err());
        assert!(ProbeOutput::default()
            .accept(
                message(
                    "turn/completed",
                    json!({"turn":{"id":"turn","status":"failed"}})
                ),
                "thread",
                "turn",
                300
            )
            .is_err());
    }
    #[test]
    #[ignore = "Starts one live Codex probe and consumes quota; opt in explicitly"]
    fn live_codex_probe() {
        let home =
            std::env::var_os("MODELTRACE_TEST_CODEX_HOME").expect("set MODELTRACE_TEST_CODEX_HOME");
        let work = std::env::temp_dir().join(format!("modeltrace-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&work).unwrap();
        let outcome = sample(
            Path::new(&home),
            &work,
            "gpt-5.6-sol",
            312,
            &AtomicBool::new(false),
        );
        let _ = std::fs::remove_dir(&work);
        let sample = outcome.unwrap();
        eprintln!(
            "Live probe: {} accepted integers, {} returned, {} out of range",
            sample.numbers.len(),
            sample.returned_count,
            sample.out_of_range_count
        );
        assert!(sample.numbers.len() >= 172);
    }
}
