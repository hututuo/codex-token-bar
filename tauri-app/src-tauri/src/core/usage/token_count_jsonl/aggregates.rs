use super::TokenEvent;
use crate::models::{ActivityDay, DashboardStats, RecentUsagePoint};
use std::collections::{HashMap, HashSet};
use time::macros::format_description;
use time::{Date, Duration, OffsetDateTime, UtcOffset};

const RECENT_INTERVAL_SECONDS: i64 = 5 * 60;
const RECENT_POINT_COUNT: i64 = 30 * 24 * 12;
const HOURLY_INTERVAL_SECONDS: i64 = 60 * 60;
const SEVEN_DAY_POINT_COUNT: i64 = 7 * 24;
const SIX_HOUR_INTERVAL_SECONDS: i64 = 6 * 60 * 60;
const THIRTY_DAY_POINT_COUNT: i64 = 30 * 4;

#[derive(Default)]
pub(super) struct TokenAccumulator {
    pub(super) tokens: u64,
    pub(super) calls: u32,
    pub(super) input_tokens: u64,
    pub(super) cached_input_tokens: u64,
    pub(super) output_tokens: u64,
}

impl TokenAccumulator {
    pub(super) fn add(&mut self, event: &TokenEvent) {
        self.tokens = self.tokens.saturating_add(event.tokens);
        self.calls = self.calls.saturating_add(1);
        self.input_tokens = self.input_tokens.saturating_add(event.input_tokens);
        self.cached_input_tokens = self
            .cached_input_tokens
            .saturating_add(event.cached_input_tokens.min(event.input_tokens));
        self.output_tokens = self.output_tokens.saturating_add(event.output_tokens);
    }

    pub(super) fn cache_hit_rate(&self) -> f64 {
        if self.input_tokens == 0 {
            0.0
        } else {
            (self.cached_input_tokens as f64 / self.input_tokens as f64).clamp(0.0, 1.0)
        }
    }
}

pub(super) fn activity_days_at(
    events: &[TokenEvent],
    now_utc: OffsetDateTime,
    local_offset: UtcOffset,
) -> Vec<ActivityDay> {
    let today = now_utc.to_offset(local_offset).date();
    let start = today - Duration::days(364);
    let mut grouped: HashMap<Date, TokenAccumulator> = HashMap::new();

    for event in events {
        let day = event.timestamp.to_offset(local_offset).date();
        if day >= start && day <= today {
            grouped.entry(day).or_default().add(event);
        }
    }

    (0..365)
        .map(|offset| {
            let day = start + Duration::days(offset);
            let usage = grouped.remove(&day).unwrap_or_default();
            ActivityDay {
                date: format_date(day),
                tokens: usage.tokens,
                calls: usage.calls,
                cache_hit_rate: usage.cache_hit_rate(),
                five_hour_remaining_percent: None,
                seven_day_remaining_percent: None,
            }
        })
        .collect()
}

pub(super) fn recent_usage(
    events: &[TokenEvent],
    local_offset: UtcOffset,
) -> Vec<RecentUsagePoint> {
    usage_series(events, local_offset, RECENT_INTERVAL_SECONDS, RECENT_POINT_COUNT)
}

pub(super) fn recent_usage_7d(
    events: &[TokenEvent],
    local_offset: UtcOffset,
) -> Vec<RecentUsagePoint> {
    usage_series(events, local_offset, HOURLY_INTERVAL_SECONDS, SEVEN_DAY_POINT_COUNT)
}

pub(super) fn recent_usage_30d(
    events: &[TokenEvent],
    local_offset: UtcOffset,
) -> Vec<RecentUsagePoint> {
    usage_series(
        events,
        local_offset,
        SIX_HOUR_INTERVAL_SECONDS,
        THIRTY_DAY_POINT_COUNT,
    )
}

fn usage_series(
    events: &[TokenEvent],
    local_offset: UtcOffset,
    interval_seconds: i64,
    point_count: i64,
) -> Vec<RecentUsagePoint> {
    let now_epoch = OffsetDateTime::now_utc().unix_timestamp();
    let end_bin = floor_to_bin(now_epoch, interval_seconds);
    let start_bin = end_bin - (point_count.saturating_sub(1)) * interval_seconds;
    let mut grouped: HashMap<i64, TokenAccumulator> = HashMap::new();

    for event in events {
        let bin_epoch = floor_to_bin(event.timestamp.unix_timestamp(), interval_seconds);
        if bin_epoch < start_bin || bin_epoch > end_bin {
            continue;
        }
        grouped.entry(bin_epoch).or_default().add(event);
    }

    (0..point_count)
        .map(|offset| {
            let bin_epoch = start_bin + offset * interval_seconds;
            let bin_time = OffsetDateTime::from_unix_timestamp(bin_epoch)
                .unwrap_or_else(|_| OffsetDateTime::now_utc());
            let usage = grouped.remove(&bin_epoch).unwrap_or_default();
            RecentUsagePoint {
                label: format_time(bin_time.to_offset(local_offset)),
                start_unix: bin_epoch,
                tokens: usage.tokens,
                calls: usage.calls,
                input_tokens: usage.input_tokens,
                cached_input_tokens: usage.cached_input_tokens,
                output_tokens: usage.output_tokens,
                cache_hit_rate: if usage.input_tokens > 0 {
                    Some(usage.cache_hit_rate())
                } else {
                    None
                },
                five_hour_remaining_percent: None,
                seven_day_remaining_percent: None,
            }
        })
        .collect()
}

pub(super) fn stats_at(
    events: &[TokenEvent],
    days: &[ActivityDay],
    today: Date,
) -> DashboardStats {
    let total_tokens = events.iter().map(|event| event.tokens).sum();
    let peak_day_tokens = days.iter().map(|day| day.tokens).max().unwrap_or(0);
    let mut by_session: HashMap<&str, u64> = HashMap::new();
    let mut sessions = HashSet::new();

    for event in events {
        sessions.insert(event.session_id.as_str());
        *by_session.entry(event.session_id.as_str()).or_default() += event.tokens;
    }

    DashboardStats {
        total_tokens,
        peak_day_tokens,
        peak_thread_tokens: by_session.values().copied().max().unwrap_or(0),
        current_streak_days: current_streak_days_at(days, today),
        longest_streak_days: longest_streak_days(days),
        total_calls: u32::try_from(events.len()).unwrap_or(u32::MAX),
        total_threads: u32::try_from(sessions.len()).unwrap_or(u32::MAX),
    }
}

fn floor_to_bin(timestamp: i64, interval_seconds: i64) -> i64 {
    timestamp - timestamp.rem_euclid(interval_seconds)
}

fn current_streak_days_at(days: &[ActivityDay], today: Date) -> u32 {
    let mut active = HashSet::new();
    for day in days {
        let Ok(date) = Date::parse(&day.date, format_description!("[year]-[month]-[day]")) else {
            continue;
        };
        if date <= today && day.tokens > 0 {
            active.insert(date);
        }
    }

    let yesterday = today - Duration::days(1);
    let mut cursor = if active.contains(&today) {
        today
    } else if active.contains(&yesterday) {
        yesterday
    } else {
        return 0;
    };
    let mut streak = 0_u32;
    while active.contains(&cursor) {
        streak = streak.saturating_add(1);
        cursor -= Duration::days(1);
    }
    streak
}

fn longest_streak_days(days: &[ActivityDay]) -> u32 {
    let mut best = 0;
    let mut current = 0;
    for day in days {
        if day.tokens > 0 {
            current += 1;
            best = best.max(current);
        } else {
            current = 0;
        }
    }
    best
}

fn format_date(date: Date) -> String {
    date.format(format_description!("[year]-[month]-[day]"))
        .unwrap_or_else(|_| "1970-01-01".into())
}

fn format_time(date: OffsetDateTime) -> String {
    date.format(format_description!("[hour]:[minute]"))
        .unwrap_or_else(|_| "00:00".into())
}

#[cfg(test)]
mod current_streak_tests {
    use super::*;

    fn day(date: &str, tokens: u64) -> ActivityDay {
        ActivityDay {
            date: date.into(),
            tokens,
            calls: u32::from(tokens > 0),
            cache_hit_rate: 0.0,
            five_hour_remaining_percent: None,
            seven_day_remaining_percent: None,
        }
    }

    #[test]
    fn current_streak_is_anchored_to_injected_local_today() {
        let today = Date::from_calendar_date(2026, time::Month::July, 11).unwrap();
        let cases = [
            ("today active", vec![day("2026-07-11", 1)], 1),
            ("yesterday grace", vec![day("2026-07-10", 1)], 1),
            (
                "two empty",
                vec![day("2026-07-10", 0), day("2026-07-11", 0)],
                0,
            ),
            (
                "today minus two plus today",
                vec![day("2026-07-09", 1), day("2026-07-11", 1)],
                1,
            ),
            (
                "duplicate date merged",
                vec![day("2026-07-11", 0), day("2026-07-11", 1)],
                1,
            ),
            ("stale only", vec![day("2026-07-09", 1)], 0),
            (
                "future ignored",
                vec![day("2026-07-11", 1), day("2026-07-12", 1)],
                1,
            ),
            (
                "history gap",
                vec![
                    day("2026-07-07", 1),
                    day("2026-07-09", 1),
                    day("2026-07-10", 1),
                ],
                2,
            ),
        ];

        for (name, days, expected) in cases {
            assert_eq!(current_streak_days_at(&days, today), expected, "{name}");
        }
    }

    #[test]
    fn activity_days_and_stats_share_the_same_injected_local_today() {
        let now = OffsetDateTime::from_unix_timestamp(1_783_785_599).unwrap();
        let offset = UtcOffset::from_hms(8, 0, 0).unwrap();
        let event = TokenEvent {
            timestamp: now,
            session_id: "shared-now".into(),
            tokens: 7,
            input_tokens: 7,
            cached_input_tokens: 0,
            output_tokens: 0,
            user_prompt: String::new(),
            assistant_response: String::new(),
        };

        let (days, stats) = super::super::activity_days_and_stats_at(&[event], now, offset);

        assert_eq!(days.last().unwrap().date, "2026-07-11");
        assert_eq!(days.last().unwrap().tokens, 7);
        assert_eq!(stats.current_streak_days, 1);
    }
}

#[cfg(test)]
mod cache_hit_normalization_tests {
    use super::*;

    fn event(timestamp: OffsetDateTime, input_tokens: u64, cached_input_tokens: u64) -> TokenEvent {
        TokenEvent {
            timestamp,
            session_id: "cache-normalization".into(),
            tokens: input_tokens,
            input_tokens,
            cached_input_tokens,
            output_tokens: 0,
            user_prompt: String::new(),
            assistant_response: String::new(),
        }
    }

    #[test]
    fn malformed_cached_input_is_clamped_per_event_across_daily_and_recent_aggregates() {
        let now = OffsetDateTime::now_utc();
        let events = vec![event(now, 100, 250), event(now, 50, 80)];
        let offset = UtcOffset::UTC;

        let mut accumulated = TokenAccumulator::default();
        for event in &events {
            accumulated.add(event);
        }
        assert_eq!(accumulated.input_tokens, 150);
        assert_eq!(accumulated.cached_input_tokens, 150);
        assert_eq!(accumulated.cache_hit_rate(), 1.0);

        let days = activity_days_at(&events, now, offset);
        let today = days.last().unwrap();
        assert_eq!(today.cache_hit_rate, 1.0);

        let recent = recent_usage(&events, offset);
        let point = recent.iter().find(|point| point.calls == 2).unwrap();
        assert_eq!(point.input_tokens, 150);
        assert_eq!(point.cached_input_tokens, 150);
        assert_eq!(point.cache_hit_rate, Some(1.0));
    }
}
