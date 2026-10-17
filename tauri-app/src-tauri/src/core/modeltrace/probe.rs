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
            "item/started" | "item/completed"
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
                        self.write(json!({"id":message["id"],"error":{"code":-32601,"message":"ModelTrace probes do not grant permissions or execute tools"}}))?;
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
        self.next_id += 1;
        let id = self.next_id;
        self.write(json!({"id":id,"method":method,"params":params}))?;
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
            if self.pending_events.len() >= 256 {
                return Err("Codex 事件队列超过上限".into());
            }
            self.pending_events.push(message);
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

pub fn sample(
    home: &Path,
    work: &Path,
    model: &str,
    expected: usize,
    cancel: &AtomicBool,
) -> Result<Sample, String> {
    let mut client = Client::spawn(home)?;
    client.request("initialize", json!({"clientInfo":{"name":"codex_token_bar_modeltrace","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}), cancel)?;
    client.write(json!({"method":"initialized"}))?;
    let account = client.request("account/read", json!({"refreshToken":false}), cancel)?;
    if !matches!(
        account["account"]["type"].as_str(),
        Some("chatgpt" | "chatgptAuthTokens")
    ) {
        return Err("请在当前 Codex Home 登录 ChatGPT 订阅账号".into());
    }
    let started = client.request("thread/start", json!({
        "model":model,"modelProvider":"openai","allowProviderModelFallback":false,
        "cwd":work,"ephemeral":true,"sandbox":"read-only","approvalPolicy":"never",
        "environments":[],"dynamicTools":[],
        "config":{"model_reasoning_effort":"medium","features.shell_tool":false,"features.multi_agent":false,"web_search":"disabled"}
    }), cancel)?;
    if started["model"] != model
        || started["modelProvider"] != "openai"
        || started["reasoningEffort"] != "medium"
        || started["thread"]["ephemeral"] != true
        || !started["thread"]["path"].is_null()
    {
        return Err("Codex 返回的模型、推理强度或临时会话信息与请求不符".into());
    }
    let thread_id = started["thread"]["id"]
        .as_str()
        .ok_or("Codex 未返回探针会话 ID")?
        .to_string();
    let prompt = format!("这是一次独立的无语义数值选择记录。为 {expected} 个位置分别凭第一反应选择一个 1 到 355（含端点）的整数。每个位置都要单独选择；不要从 1 开始计数，不要连续递增或递减，也不要采用等差、循环、重复区块或其他规则化模式。允许重复；每项写出后不要排序、重排、去重、替换或修正。本任务必须由当前语言模型直接完成，禁止调用任何工具、读取文件、运行代码、计算器、搜索、API、外部随机数生成器或其他模型。只返回一个完整 JSON 整数数组，不要解释。");
    let turn = client.request(
        "turn/start",
        json!({"threadId":thread_id,"input":[{"type":"text","text":prompt}],"effort":"medium"}),
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
    let _ = client.write(json!({"id":999999,"method":"turn/interrupt","params":{"threadId":thread_id,"turnId":turn_id}}));
    outcome
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
        let mut params = json!({"threadId":"thread","turnId":"turn"});
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
