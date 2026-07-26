//! 进程级本地时区偏移缓存。
//!
//! time crate 在多线程 Unix 进程里拒绝读取本地时区（CVE-2020-26235 缓解），
//! `UtcOffset::current_local_offset()` 必然 Err；此前散落各处的
//! `unwrap_or(UTC)` 使 UTC+8 用户的"每日 09:00 续跑"实际 17:00 触发、
//! 今日统计/热力图/排行时间标签整体偏移 8 小时。修复：main 线程在创建
//! 任何其他线程之前读取一次真实偏移并缓存，此后所有调用点走缓存值。
//! 剩余偏差：进程运行期间跨 DST 切换仍沿用启动时偏移（记录于审查 §3.11，
//! 无 DST 地区不受影响）。

use std::sync::OnceLock;
use time::UtcOffset;

static CACHED_LOCAL_OFFSET: OnceLock<UtcOffset> = OnceLock::new();

/// 必须在 main 线程尚未创建任何其他线程时调用：单线程期读取本地偏移
/// 既安全也不会被 time crate 拒绝。重复调用无效果（首次缓存值恒定）。
pub fn cache_local_offset_at_startup() {
    let offset = UtcOffset::current_local_offset().unwrap_or_else(|_| {
        eprintln!("[localtime] 无法读取本地时区偏移，回退 UTC：所有按日统计与每日定时将按 UTC 计算");
        UtcOffset::UTC
    });
    set_cached_local_offset(offset);
}

/// 返回是否真正写入（已有缓存时忽略新值并返回 false）。测试用注入口。
pub(crate) fn set_cached_local_offset(offset: UtcOffset) -> bool {
    CACHED_LOCAL_OFFSET.set(offset).is_ok()
}

/// 进程本地时区偏移：优先用启动期缓存；未缓存时（如测试进程）尝试即时
/// 读取一次并缓存，失败回退 UTC——与修复前各调用点的回退语义一致。
pub fn local_offset() -> UtcOffset {
    *CACHED_LOCAL_OFFSET
        .get_or_init(|| UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_offset_is_cached_once_and_stable() {
        let first = local_offset();
        let different = if first == UtcOffset::UTC {
            UtcOffset::from_hms(8, 0, 0).unwrap()
        } else {
            UtcOffset::UTC
        };
        assert!(
            !set_cached_local_offset(different),
            "首次读取后缓存必须已固定，后写必须被忽略"
        );
        assert_eq!(local_offset(), first, "缓存值不得被后续写入改变");
    }
}
