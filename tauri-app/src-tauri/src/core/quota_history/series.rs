use super::{now_unix, QuotaHistoryRow};
use crate::models::QuotaHistoryPoint;
use std::collections::HashMap;
use time::macros::format_description;
use time::{OffsetDateTime, UtcOffset};

const RECENT_INTERVAL_SECONDS: i64 = 5 * 60;
const MAX_CARRY_GAP_SECONDS: f64 = 90.0 * 60.0;

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
    make_interval_history(rows, count, RECENT_INTERVAL_SECONDS)
}

pub(super) fn make_interval_history(
    rows: Vec<QuotaHistoryRow>,
    count: usize,
    interval_seconds: i64,
) -> Vec<QuotaHistoryPoint> {
    let interval_seconds = interval_seconds.max(RECENT_INTERVAL_SECONDS);
    let end = floor_to_bin(now_unix(), interval_seconds);
    let start = end - (count.saturating_sub(1) as f64) * interval_seconds as f64;
    let sorted = sanitized_rows(rows);
    let mut row_index = 0;
    let mut latest: Option<QuotaHistoryRow> = None;

    (0..count)
        .map(|index| {
            let bin_start = start + index as f64 * interval_seconds as f64;
            let end = bin_start + interval_seconds as f64;
            while row_index < sorted.len() && sorted[row_index].created_at <= end {
                latest = Some(sorted[row_index].clone());
                row_index += 1;
            }
            QuotaHistoryPoint {
                label: format_unix_time(bin_start),
                start_unix: bin_start.round() as i64,
                five_hour_remaining_percent: quota_remaining(
                    latest.as_ref(),
                    end,
                    |row| row.five_hour_remaining(),
                    |row| row.five_hour_resets_at,
                ),
                seven_day_remaining_percent: quota_remaining(
                    latest.as_ref(),
                    end,
                    |row| row.seven_day_remaining(),
                    |row| row.seven_day_resets_at,
                ),
            }
        })
        .collect()
}

pub(super) fn make_daily_history(
    rows: Vec<QuotaHistoryRow>,
) -> HashMap<String, DailyQuotaHistory> {
    let sorted = sanitized_rows(rows);
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
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
    let mut last_by_account: HashMap<String, QuotaHistoryRow> = HashMap::new();
    let normalized = rows.into_iter()
        .map(|row| {
            let normalized = row.normalized_after(last_by_account.get(&row.account_key));
            last_by_account.insert(row.account_key.clone(), normalized.clone());
            normalized
        })
        .collect();
    suppress_recovered_full_usage_spikes(normalized)
}

fn suppress_recovered_full_usage_spikes(mut rows: Vec<QuotaHistoryRow>) -> Vec<QuotaHistoryRow> {
    suppress_recovered_full_usage_spikes_for_window(
        &mut rows,
        |row| row.five_hour_used_percent,
        |row| row.five_hour_resets_at,
        |row, value| row.five_hour_used_percent = value,
    );
    suppress_recovered_full_usage_spikes_for_window(
        &mut rows,
        |row| row.seven_day_used_percent,
        |row| row.seven_day_resets_at,
        |row, value| row.seven_day_used_percent = value,
    );
    rows
}

fn suppress_recovered_full_usage_spikes_for_window(
    rows: &mut [QuotaHistoryRow],
    used: impl Fn(&QuotaHistoryRow) -> Option<i32> + Copy,
    reset: impl Fn(&QuotaHistoryRow) -> Option<f64> + Copy,
    mut set_used: impl FnMut(&mut QuotaHistoryRow, Option<i32>),
) {
    let mut index = 0;
    while index < rows.len() {
        let Some(current_used) = used(&rows[index]) else {
            index += 1;
            continue;
        };
        if current_used < 95 {
            index += 1;
            continue;
        }

        let current_account = rows[index].account_key.clone();
        let current_reset = reset(&rows[index]);
        let mut end = index + 1;
        while end < rows.len()
            && rows[end].account_key == current_account
            && same_reset(reset(&rows[end]), current_reset)
            && used(&rows[end]).is_some_and(|value| value >= 95)
        {
            end += 1;
        }

        let previous = previous_same_cycle_low(rows, index, &current_account, current_reset, used, reset);
        let next = next_same_cycle_low(rows, end, &current_account, current_reset, used, reset);
        if let (Some(previous_used), Some(next_used)) = (previous, next) {
            let recovered_floor = previous_used.max(next_used);
            if current_used - recovered_floor >= 20 {
                for row in &mut rows[index..end] {
                    set_used(row, Some(previous_used));
                }
            }
        }

        index = end;
    }
}

fn previous_same_cycle_low(
    rows: &[QuotaHistoryRow],
    index: usize,
    account_key: &str,
    reset_at: Option<f64>,
    used: impl Fn(&QuotaHistoryRow) -> Option<i32> + Copy,
    reset: impl Fn(&QuotaHistoryRow) -> Option<f64> + Copy,
) -> Option<i32> {
    rows[..index]
        .iter()
        .rev()
        .find(|row| row.account_key == account_key && same_reset(reset(row), reset_at))
        .and_then(used)
        .filter(|value| *value <= 80)
}

fn next_same_cycle_low(
    rows: &[QuotaHistoryRow],
    index: usize,
    account_key: &str,
    reset_at: Option<f64>,
    used: impl Fn(&QuotaHistoryRow) -> Option<i32> + Copy,
    reset: impl Fn(&QuotaHistoryRow) -> Option<f64> + Copy,
) -> Option<i32> {
    rows[index..]
        .iter()
        .find(|row| row.account_key == account_key && same_reset(reset(row), reset_at))
        .and_then(used)
        .filter(|value| *value <= 80)
}

fn same_reset(left: Option<f64>, right: Option<f64>) -> bool {
    match (left, right) {
        (Some(left), Some(right)) => (left - right).abs() < 1.0,
        (None, None) => true,
        _ => false,
    }
}

fn floor_to_bin(timestamp: f64, interval_seconds: i64) -> f64 {
    let interval = interval_seconds as f64;
    (timestamp / interval).floor() * interval
}

fn quota_remaining(
    row: Option<&QuotaHistoryRow>,
    at: f64,
    remaining: impl Fn(&QuotaHistoryRow) -> Option<f64>,
    resets_at: impl Fn(&QuotaHistoryRow) -> Option<f64>,
) -> Option<f64> {
    let row = row?;
    let value = remaining(row)?;
    if let Some(reset) = resets_at(row) {
        if at >= reset {
            return Some(1.0);
        }
        return Some(value);
    }
    if at - row.created_at <= MAX_CARRY_GAP_SECONDS {
        Some(value)
    } else {
        None
    }
}

fn average(total: f64, count: u32) -> Option<f64> {
    if count == 0 {
        None
    } else {
        Some((total / f64::from(count)).clamp(0.0, 1.0))
    }
}

fn format_unix_time(value: f64) -> String {
    let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
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
