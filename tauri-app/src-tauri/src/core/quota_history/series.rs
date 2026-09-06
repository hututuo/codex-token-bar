use super::{
    now_unix, quota_cycle_id_for_identity, same_cycle_for_window_with_policy, QuotaHistoryRow,
};
use crate::core::time_series_timeline::{aligned_bin_starts, LONG_RECENT_INTERVAL_SECONDS};
use crate::models::QuotaHistoryPoint;
use std::collections::HashMap;
use time::macros::format_description;
use time::OffsetDateTime;

const MAX_CARRY_GAP_SECONDS: f64 = 90.0 * 60.0;
const LEGACY_FIVE_HOUR_MAX_RESET_SPAN_SECONDS: f64 = 6.0 * 60.0 * 60.0;

#[derive(Clone, Debug)]
pub(super) struct DailyQuotaHistory {
    pub(super) five_hour_remaining_percent: Option<f64>,
    pub(super) seven_day_remaining_percent: Option<f64>,
}

#[derive(Clone, Debug, Default)]
struct DailyQuotaAccumulator {
    five_hour_total: f64,
    five_hour_count: u32,
    seven_day_total: f64,
    seven_day_count: u32,
}

impl DailyQuotaAccumulator {
    fn add(&mut self, row: &QuotaHistoryRow) {
        if let Some(value) = row.five_hour_remaining() {
            self.five_hour_total += value;
            self.five_hour_count = self.five_hour_count.saturating_add(1);
        }
        if let Some(value) = row.seven_day_remaining() {
            self.seven_day_total += value;
            self.seven_day_count = self.seven_day_count.saturating_add(1);
        }
    }

    fn into_history(self) -> DailyQuotaHistory {
        DailyQuotaHistory {
            five_hour_remaining_percent: average(self.five_hour_total, self.five_hour_count),
            seven_day_remaining_percent: average(self.seven_day_total, self.seven_day_count),
        }
    }
}

pub(super) fn make_recent_history(
    rows: Vec<QuotaHistoryRow>,
    count: usize,
) -> Vec<QuotaHistoryPoint> {
    make_interval_history(rows, count, LONG_RECENT_INTERVAL_SECONDS)
}

pub(super) fn make_interval_history(
    rows: Vec<QuotaHistoryRow>,
    count: usize,
    interval_seconds: i64,
) -> Vec<QuotaHistoryPoint> {
    make_interval_history_at(rows, count, interval_seconds, now_unix())
}

pub(super) fn make_interval_history_at(
    rows: Vec<QuotaHistoryRow>,
    count: usize,
    interval_seconds: i64,
    now: f64,
) -> Vec<QuotaHistoryPoint> {
    let interval_seconds = interval_seconds.max(LONG_RECENT_INTERVAL_SECONDS);
    let bin_starts = aligned_bin_starts(now as i64, interval_seconds, count as i64);
    let sorted = sanitized_rows(
        rows.into_iter()
            .filter(|row| row.created_at <= now)
            .collect(),
    );
    let mut row_index = 0;
    let mut latest: Option<QuotaHistoryRow> = None;

    bin_starts
        .into_iter()
        .map(|bin_start| {
            let bin_start = bin_start as f64;
            let end = bin_start + interval_seconds as f64;
            let sample_at = end.min(now);
            while row_index < sorted.len() && sorted[row_index].created_at <= sample_at {
                latest = Some(sorted[row_index].clone());
                row_index += 1;
            }
            let next = sorted.get(row_index);
            QuotaHistoryPoint {
                label: format_unix_time(bin_start),
                start_unix: bin_start.round() as i64,
                five_hour_remaining_percent: quota_remaining(
                    latest.as_ref(),
                    next,
                    bin_start,
                    sample_at,
                    |row| row.five_hour_remaining(),
                    |row| row.five_hour_resets_at,
                    |row| row.five_hour_cycle_generation,
                    |row| row.five_hour_reset_anchor,
                    super::protection::HistoryPolicy::FIVE_HOUR,
                ),
                seven_day_remaining_percent: quota_remaining(
                    latest.as_ref(),
                    next,
                    bin_start,
                    sample_at,
                    |row| row.seven_day_remaining(),
                    |row| row.seven_day_resets_at,
                    |row| row.seven_day_cycle_generation,
                    |row| row.seven_day_reset_anchor,
                    super::protection::HistoryPolicy::SEVEN_DAY,
                ),
                five_hour_cycle_id: latest.as_ref().and_then(|row| {
                    row.stable_identity().and_then(|identity| {
                        quota_cycle_id_for_identity(
                            &identity,
                            "5h",
                            row.five_hour_cycle_generation,
                        )
                    })
                }),
                seven_day_cycle_id: latest.as_ref().and_then(|row| {
                    row.stable_identity().and_then(|identity| {
                        quota_cycle_id_for_identity(
                            &identity,
                            "7d",
                            row.seven_day_cycle_generation,
                        )
                    })
                }),
            }
        })
        .collect()
}

pub(super) fn make_daily_history(
    rows: Vec<QuotaHistoryRow>,
) -> HashMap<String, DailyQuotaHistory> {
    let sorted = sanitized_rows(rows);
    let local_offset = crate::core::localtime::local_offset();
    let mut grouped: HashMap<String, DailyQuotaAccumulator> = HashMap::new();

    for row in sorted {
        let Some(timestamp) = OffsetDateTime::from_unix_timestamp(row.created_at.round() as i64).ok()
        else {
            continue;
        };
        let date = timestamp.to_offset(local_offset).date();
        grouped
            .entry(format_date(date))
            .or_default()
            .add(&row);
    }

    grouped
        .into_iter()
        .map(|(date, usage)| (date, usage.into_history()))
        .collect()
}

pub(super) fn sanitized_rows(rows: Vec<QuotaHistoryRow>) -> Vec<QuotaHistoryRow> {
    let mut rows = reclassify_legacy_seven_day_only_rows(super::merge_history_rows(rows, Vec::new()));
    rows.sort_by(|a, b| a.created_at.total_cmp(&b.created_at));
    let mut states: HashMap<(Option<super::QuotaHistoryIdentity>, String),
        (super::protection::HistoryProtection, super::protection::HistoryProtection)> = HashMap::new();
    rows.into_iter().map(|mut row| {
        let identity = row.stable_identity();
        let fallback = if identity.is_some() { String::new() } else { row.history_match_key() };
        let (five, seven) = states.entry((identity, fallback)).or_insert_with(|| (
            super::protection::HistoryProtection::new(super::protection::HistoryPolicy::FIVE_HOUR),
            super::protection::HistoryProtection::new(super::protection::HistoryPolicy::SEVEN_DAY)
        ));
        let f = five.observe(row.five_hour_used_percent, row.five_hour_resets_at, row.created_at);
        let s = seven.observe(row.seven_day_used_percent, row.seven_day_resets_at, row.created_at);
        row.five_hour_used_percent = f.used;
        row.five_hour_resets_at = f.reset;
        row.seven_day_used_percent = s.used;
        row.seven_day_resets_at = s.reset;
        row
    }).collect()
}

fn reclassify_legacy_seven_day_only_rows(mut rows: Vec<QuotaHistoryRow>) -> Vec<QuotaHistoryRow> {
    for row in &mut rows {
        let looks_like_seven_day = row.seven_day_used_percent.is_none()
            && row.seven_day_resets_at.is_none()
            && row.five_hour_used_percent.is_some()
            && row
                .five_hour_resets_at
                .is_some_and(|reset| reset - row.created_at > LEGACY_FIVE_HOUR_MAX_RESET_SPAN_SECONDS);
        if looks_like_seven_day {
            row.seven_day_used_percent = row.five_hour_used_percent.take();
            row.seven_day_resets_at = row.five_hour_resets_at.take();
        }
    }
    rows
}

fn quota_remaining(
    row: Option<&QuotaHistoryRow>,
    next_row: Option<&QuotaHistoryRow>,
    _previous_boundary: f64,
    at: f64,
    remaining: impl Fn(&QuotaHistoryRow) -> Option<f64>,
    resets_at: impl Fn(&QuotaHistoryRow) -> Option<f64>,
    generation: impl Fn(&QuotaHistoryRow) -> Option<i64>,
    _reset_anchor: impl Fn(&QuotaHistoryRow) -> Option<i64>,
    policy: super::protection::HistoryPolicy,
) -> Option<f64> {
    let row = row?;
    let value = remaining(row)?;
    let boundary_reset = resets_at(row);
    if let Some(reset) = boundary_reset.filter(|reset| *reset > row.created_at) {
        // The clock reaching reset is not a server-confirmed refill.
        if at >= reset {
            return None;
        }
        if let Some(interpolated) =
            interpolated_quota_remaining(
                row,
                next_row,
                at,
                value,
                &remaining,
                &resets_at,
                &generation,
                policy,
            )
        {
            return Some(interpolated);
        }
        return Some(value);
    }
    if let Some(interpolated) =
        interpolated_quota_remaining(
            row,
            next_row,
            at,
            value,
            &remaining,
            &resets_at,
            &generation,
            policy,
        )
    {
        return Some(interpolated);
    }
    if at - row.created_at <= MAX_CARRY_GAP_SECONDS {
        Some(value)
    } else {
        None
    }
}

fn interpolated_quota_remaining(
    row: &QuotaHistoryRow,
    next_row: Option<&QuotaHistoryRow>,
    at: f64,
    start_value: f64,
    remaining: &impl Fn(&QuotaHistoryRow) -> Option<f64>,
    resets_at: &impl Fn(&QuotaHistoryRow) -> Option<f64>,
    generation: &impl Fn(&QuotaHistoryRow) -> Option<i64>,
    policy: super::protection::HistoryPolicy,
) -> Option<f64> {
    let next_row = next_row?;
    if !same_cycle_for_window_with_policy(
        remaining_used(next_row, remaining),
        resets_at(next_row),
        generation(next_row),
        remaining_used(row, remaining),
        resets_at(row),
        generation(row),
        policy,
    ) {
        return None;
    }
    let end_value = remaining(next_row)?;
    if end_value >= start_value || at <= row.created_at || at >= next_row.created_at {
        return None;
    }
    let duration = next_row.created_at - row.created_at;
    if duration <= 0.0 {
        return None;
    }
    let progress = ((at - row.created_at) / duration).clamp(0.0, 1.0);
    Some(start_value + (end_value - start_value) * progress)
}

fn remaining_used(
    row: &QuotaHistoryRow,
    remaining: &impl Fn(&QuotaHistoryRow) -> Option<f64>,
) -> Option<i32> {
    remaining(row).map(|value| ((1.0 - value).clamp(0.0, 1.0) * 100.0).round() as i32)
}


fn average(total: f64, count: u32) -> Option<f64> {
    if count == 0 {
        None
    } else {
        Some((total / f64::from(count)).clamp(0.0, 1.0))
    }
}

fn format_unix_time(value: f64) -> String {
    let offset = crate::core::localtime::local_offset();
    let seconds = value.round() as i64;
    OffsetDateTime::from_unix_timestamp(seconds)
        .unwrap_or_else(|_| OffsetDateTime::UNIX_EPOCH)
        .to_offset(offset)
        .format(format_description!("[hour]:[minute]"))
        .unwrap_or_else(|_| "00:00".into())
}

pub(super) fn format_date(date: time::Date) -> String {
    date.format(format_description!("[year]-[month]-[day]"))
        .unwrap_or_else(|_| "1970-01-01".into())
}
