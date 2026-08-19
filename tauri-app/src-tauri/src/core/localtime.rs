//! 本地时区访问。
//!
//! time crate 在多线程 Unix 进程里拒绝读取本地时区（CVE-2020-26235 缓解），
//! `UtcOffset::current_local_offset()` 在进程启动后可能 Err；此前散落各处的
//! `unwrap_or(UTC)` 使 UTC+8 用户的"每日 09:00 续跑"实际 17:00 触发、
//! 今日统计/热力图/排行时间标签整体偏移 8 小时。修复：main 线程在创建
//! 任何其他线程之前读取一次真实偏移并缓存，此后非历史调用点走缓存值。
//! 历史本地日分桶不能使用这个启动时快照：必须对每个事件时间查询系统
//! 的 IANA 时区规则。`time` crate 已提供线程安全的 `local_offset_at`，
//! 它在 Unix 上使用 `localtime_r`，在 Windows 上使用系统时区 API。

use std::sync::OnceLock;
use time::{Date, Duration, OffsetDateTime, UtcOffset};

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

/// 返回给定 Unix 秒在当前系统 IANA 时区下的 UTC 偏移。
///
/// 这条路径不能复用 [`local_offset`]：后者是为了兼容其他启动期调用点
/// 而保留的进程级快照。系统时区或 DST 在进程运行期间变化时，这里会
/// 立即按事件时间重新计算。读取失败时回退到启动期偏移，保持旧行为。
pub fn local_offset_at(unix_timestamp: i64) -> UtcOffset {
    let Some(timestamp) = OffsetDateTime::from_unix_timestamp(unix_timestamp).ok() else {
        return local_offset();
    };
    UtcOffset::local_offset_at(timestamp).unwrap_or_else(|_| local_offset())
}

/// 将 Unix 秒转换为当前系统 IANA 时区下的本地日期。
pub fn local_date_at(unix_timestamp: i64) -> Date {
    OffsetDateTime::from_unix_timestamp(unix_timestamp)
        .unwrap_or(OffsetDateTime::UNIX_EPOCH)
        .to_offset(local_offset_at(unix_timestamp))
        .date()
}

/// 返回一个本地日的 UTC 秒边界。
///
/// 不能用“日期 + 当前固定 offset”构造边界：DST 会使前后日期拥有不同
/// 偏移，部分 IANA 区域还会在午夜调整。通过本地日期函数二分查找日期
/// 变化的第一个 Unix 秒，既保留系统 tzdata 规则，也不改写任何精确事件。
pub fn local_day_bounds(date: Date) -> Result<(i64, i64), String> {
    let start = local_date_start(date)?;
    let end = local_date_start(
        date.checked_add(Duration::days(1))
            .ok_or_else(|| "本地日期边界超出 time crate 支持范围".to_string())?,
    )?;
    Ok((start, end))
}

fn local_date_start(date: Date) -> Result<i64, String> {
    let naive_epoch = date
        .with_hms(0, 0, 0)
        .map_err(|error| format!("无法计算本地日期边界：{error}"))?
        .assume_utc()
        .unix_timestamp();

    // No current IANA rule has a transition farther than a few hours from a
    // UTC date boundary. The widening loops keep this a safe fallback for
    // historical date-line changes (for example Pacific/Apia's skipped day).
    let mut span = 3_i64 * 86_400;
    let mut low = naive_epoch.saturating_sub(span);
    let mut high = naive_epoch.saturating_add(span);
    while local_date_at(low) >= date {
        span = span.saturating_mul(2);
        let next = naive_epoch.saturating_sub(span);
        if next == low {
            return Err("无法向前定位本地日期边界".to_string());
        }
        low = next;
    }
    while local_date_at(high) < date {
        span = span.saturating_mul(2);
        let next = naive_epoch.saturating_add(span);
        if next == high {
            return Err("无法向后定位本地日期边界".to_string());
        }
        high = next;
    }

    while high.saturating_sub(low) > 1 {
        let middle = low + (high - low) / 2;
        if local_date_at(middle) >= date {
            high = middle;
        } else {
            low = middle;
        }
    }
    Ok(high)
}

/// 当前时刻的动态系统偏移。用于缓存 scope/本地日视图的失效判断；
/// 精确事件仍然只读已有 SQLite rows，不会因时区变化而重扫或重写。
pub fn current_local_offset() -> UtcOffset {
    local_offset_at(OffsetDateTime::now_utc().unix_timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::sync::{Mutex, OnceLock};

    #[cfg(unix)]
    static LOCALTIME_TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

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

    #[test]
    fn local_day_bounds_round_trip_through_local_date() {
        #[cfg(unix)]
        let _lock = LOCALTIME_TEST_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap();
        let date = Date::from_calendar_date(2026, time::Month::July, 11).unwrap();
        let (start, end) = local_day_bounds(date).unwrap();
        assert_eq!(local_date_at(start), date);
        assert_eq!(local_date_at(end - 1), date);
        assert!(end > start);
        assert_eq!(local_date_at(end), date + Duration::days(1));
    }

    #[cfg(unix)]
    mod iana_rules {
        use super::*;
        use std::ffi::OsString;
        use time::format_description::well_known::Rfc3339;

        struct TimeZoneGuard {
            previous: Option<OsString>,
        }

        impl TimeZoneGuard {
            fn set(zone: &str) -> Self {
                let previous = std::env::var_os("TZ");
                std::env::set_var("TZ", zone);
                Self { previous }
            }
        }

        impl Drop for TimeZoneGuard {
            fn drop(&mut self) {
                if let Some(previous) = self.previous.take() {
                    std::env::set_var("TZ", previous);
                } else {
                    std::env::remove_var("TZ");
                }
            }
        }

        fn unix(value: &str) -> i64 {
            OffsetDateTime::parse(value, &Rfc3339)
                .unwrap()
                .unix_timestamp()
        }

        #[test]
        fn event_dates_follow_utc_plus_8_and_non_integral_hour_rules() {
            let _lock = super::LOCALTIME_TEST_LOCK
                .get_or_init(|| Mutex::new(()))
                .lock()
                .unwrap();

            let _shanghai = TimeZoneGuard::set("Asia/Shanghai");
            assert_eq!(
                local_date_at(unix("2026-01-01T16:30:00Z")),
                Date::from_calendar_date(2026, time::Month::January, 2).unwrap()
            );
            assert_eq!(
                local_offset_at(unix("2026-01-01T16:30:00Z")).whole_seconds(),
                8 * 3600
            );
            drop(_shanghai);

            let _kathmandu = TimeZoneGuard::set("Asia/Kathmandu");
            assert_eq!(
                local_offset_at(unix("2026-01-01T00:00:00Z")).whole_seconds(),
                5 * 3600 + 45 * 60
            );
            assert_eq!(
                local_date_at(unix("2026-01-01T18:30:00Z")),
                Date::from_calendar_date(2026, time::Month::January, 2).unwrap()
            );
        }

        #[test]
        fn los_angeles_spring_and_fall_transitions_use_event_time_rules() {
            let _lock = super::LOCALTIME_TEST_LOCK
                .get_or_init(|| Mutex::new(()))
                .lock()
                .unwrap();
            let _zone = TimeZoneGuard::set("America/Los_Angeles");

            let spring_day = Date::from_calendar_date(2026, time::Month::March, 8).unwrap();
            let (spring_start, spring_end) = local_day_bounds(spring_day).unwrap();
            assert_eq!(spring_end - spring_start, 23 * 3600);
            let fall_day = Date::from_calendar_date(2026, time::Month::November, 1).unwrap();
            let (fall_start, fall_end) = local_day_bounds(fall_day).unwrap();
            assert_eq!(fall_end - fall_start, 25 * 3600);

            assert_eq!(
                local_offset_at(unix("2026-03-08T09:59:00Z")).whole_seconds(),
                -8 * 3600
            );
            assert_eq!(
                local_offset_at(unix("2026-03-08T10:00:00Z")).whole_seconds(),
                -7 * 3600
            );
            assert_eq!(
                local_date_at(unix("2026-03-08T10:00:00Z")),
                Date::from_calendar_date(2026, time::Month::March, 8).unwrap()
            );

            assert_eq!(
                local_offset_at(unix("2026-11-01T08:59:00Z")).whole_seconds(),
                -7 * 3600
            );
            assert_eq!(
                local_offset_at(unix("2026-11-01T09:00:00Z")).whole_seconds(),
                -8 * 3600
            );
            assert_eq!(
                local_date_at(unix("2026-11-01T09:00:00Z")),
                Date::from_calendar_date(2026, time::Month::November, 1).unwrap()
            );
        }

        #[test]
        fn runtime_timezone_switch_reclassifies_only_the_local_projection() {
            let _lock = super::LOCALTIME_TEST_LOCK
                .get_or_init(|| Mutex::new(()))
                .lock()
                .unwrap();
            let timestamp = unix("2026-01-01T23:30:00Z");

            let _utc = TimeZoneGuard::set("UTC");
            let utc_date = local_date_at(timestamp);
            drop(_utc);
            let _tokyo = TimeZoneGuard::set("Asia/Tokyo");
            let tokyo_date = local_date_at(timestamp);

            assert_eq!(
                utc_date,
                Date::from_calendar_date(2026, time::Month::January, 1).unwrap()
            );
            assert_eq!(
                tokyo_date,
                Date::from_calendar_date(2026, time::Month::January, 2).unwrap()
            );
            assert_ne!(utc_date, tokyo_date);
        }
    }
}
