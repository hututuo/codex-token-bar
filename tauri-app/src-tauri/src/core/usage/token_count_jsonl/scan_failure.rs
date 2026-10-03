//! Preserve bounded filesystem diagnostics when an exact refresh fails closed.
//! This only formats the error; publication and checkpoint decisions stay with
//! the exact index. Messages originate from scanner warnings, never JSONL bodies.

const MAX_DETAILS: usize = 8;
const MAX_DETAIL_CHARS: usize = 768;

pub(super) fn compressed_twin_hint(candidate: &std::path::Path, home: &std::path::Path) -> String {
    let mut path = candidate.as_os_str().to_os_string();
    path.push(".zst");
    let path = std::path::PathBuf::from(path);
    match std::fs::canonicalize(&path) {
        Ok(resolved) if resolved.starts_with(home) && resolved.is_file() => format!(
            "；存在对应压缩文件：{}。当前统计扫描器只读取普通 JSONL；请核查 Codex 的本地聊天历史压缩设置", resolved.display()),
        _ => String::new(),
    }
}

pub(super) fn with_context<M: AsRef<str>>(
    error: String,
    stage: &str,
    home: &str,
    version: &str,
    os: &str,
    arch: &str,
    messages: impl IntoIterator<Item = M>,
) -> String {
    let mut head = Vec::new();
    let mut tail = std::collections::VecDeque::new();
    let mut count = 0_usize;
    for message in messages {
        let message = message.as_ref();
        if message.is_empty() { continue; }
        count = count.saturating_add(1);
        let rendered = bounded(message);
        if head.len() < MAX_DETAILS / 2 {
            head.push(rendered);
        } else {
            if tail.len() == MAX_DETAILS / 2 { tail.pop_front(); }
            tail.push_back(rendered);
        }
    }
    let shown = head.len() + tail.len();
    head.extend(tail);
    let error = if error.chars().count() > 8192 { format!("{}…", error.chars().take(8192).collect::<String>()) } else { error };
    let mut result = format!(
        "{error}\n失败阶段：{stage}\n数据源：{home}\n运行版本：{version} · {os}/{arch}"
    );
    if !head.is_empty() {
        result.push_str(&format!("\n扫描诊断：\n{}", head.join("\n")));
    }
    if count > shown {
        result.push_str(&format!("\n另有 {} 条扫描诊断未展开（保留最早及最近各4条）", count - shown));
    }
    result
}

fn bounded(message: &str) -> String {
    let mut chars = message.chars();
    let mut detail: String = chars.by_ref().take(MAX_DETAIL_CHARS).collect();
    if chars.next().is_some() { detail.push('…'); }
    detail
}

#[cfg(test)]
mod tests {
    use super::*;

    const INCOMPLETE: &str = "会话源扫描不完整，已保留上一份可信索引和本轮断点，停止发布";

    #[test]
    fn compressed_twin_is_identified_without_reading_body_or_accepting_external_file() {
        let root = std::env::temp_dir().join(format!("tokenbar-compression-diagnostic-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let home = std::fs::canonicalize(&root).unwrap();
        let candidate = home.join("rollout.jsonl");
        std::fs::write(home.join("rollout.jsonl.zst"), b"not read by probe").unwrap();
        assert!(compressed_twin_hint(&candidate, &home).contains("对应压缩文件"));
        assert_eq!(compressed_twin_hint(&candidate, &home.join("other")), "");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn protection_message_and_unicode_os_details_are_preserved_and_bounded() {
        let detail = format!("无法读取文件 (os error 5) {}", "会话🧪".repeat(768));
        let result = with_context(INCOMPLETE.into(), "sync_error", "C:\\Codex", "0.9.3", "windows", "x86_64", [detail.as_str()]);
        assert!(result.starts_with(INCOMPLETE));
        assert!(result.contains("os error 5"));
        assert_eq!(result.lines().last().unwrap().chars().count(), MAX_DETAIL_CHARS + 1);
    }

    #[test]
    fn context_keeps_recent_blocking_cause_after_earlier_warnings() {
        let mut messages: Vec<String> = (0..100).map(|n| format!("warning-{n}")).collect();
        messages.push("missing active rollout: C:\\missing.jsonl (os error 2)".into());
        let result = with_context(INCOMPLETE.into(), "sync_error", "C:\\Codex", "0.9.3", "windows", "x86_64", messages.iter().map(String::as_str));
        assert!(result.contains("warning-0"));
        assert!(result.contains("missing active rollout"));
        assert!(result.contains("93 条"));
        assert!(result.contains("失败阶段：sync_error"));
        assert!(result.contains("数据源：C:\\Codex"));
        assert!(result.contains("windows/x86_64"));
    }

    #[test]
    fn database_failures_get_stage_and_home_even_without_scan_warnings() {
        let result = with_context("database is locked".into(), "open_error", "/codex", "0.9.3", "macos", "aarch64", std::iter::empty::<&str>());
        assert!(result.starts_with("database is locked"));
        assert!(result.contains("open_error"));
        assert!(result.contains("/codex"));
    }
}
