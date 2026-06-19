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
    let end = floor_to_recent_bin(now_unix());
    let start = end - (count.saturating_sub(1) as f64) * RECENT_INTERVAL_SECONDS as f64;
    let sorted = sanitized_rows(rows);
    let mut row_index = 0;
    let mut latest: Option<QuotaHistoryRow> = None;

    (0..count)
        .map(|index| {
            let bin_start = start + index as f64 * RECENT_INTERVAL_SECONDS as f64;
            let end = bin_start + RECENT_INTERVAL_SECONDS as f64;
            while row_index < sorted.len() && sorted[row_index].created_at <= end {
                latest = Some(sorted[row_index].clone());
                row_index += 1;
            }
            QuotaHistoryPoint {
                label: format_unix_time(bin_start),
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
    rows.into_iter()
        .map(|row| {
            let normalized = row.normalized_after(last_by_account.get(&row.account_key));
            last_by_account.insert(row.account_key.clone(), normalized.clone());
            normalized
        })
        .collect()
}

fn floor_to_recent_bin(timestamp: f64) -> f64 {
    let interval = RECENT_INTERVAL_SECONDS as f64;
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
