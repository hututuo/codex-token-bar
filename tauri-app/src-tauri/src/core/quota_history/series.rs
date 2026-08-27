use super::{
    now_unix, quota_cycle_id_for_identity, same_cycle_for_window, QuotaHistoryRow,
};
use crate::core::time_series_timeline::{aligned_bin_starts, LONG_RECENT_INTERVAL_SECONDS};
use crate::models::QuotaHistoryPoint;
use std::collections::HashMap;
use time::macros::format_description;
use time::OffsetDateTime;

const MAX_CARRY_GAP_SECONDS: f64 = 90.0 * 60.0;
const LEGACY_FIVE_HOUR_MAX_RESET_SPAN_SECONDS: f64 = 6.0 * 60.0 * 60.0;
const TRANSIENT_RESET_GLITCH_MAX_SECONDS: f64 = 30.0 * 60.0;

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
    let rows = reclassify_legacy_seven_day_only_rows(rows);
    let rows = suppress_recovered_full_remaining_jumps(rows);
    let rows = suppress_recovered_usage_spikes(rows);
    let mut last_by_account: HashMap<String, QuotaHistoryRow> = HashMap::new();
    rows.into_iter()
        .map(|row| {
            let key = row.history_match_key();
            let normalized = row.normalized_after(last_by_account.get(&key));
            last_by_account.insert(key, normalized.clone());
            normalized
        })
        .collect()
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

#[derive(Clone, Copy)]
struct WindowObservation {
    row_index: usize,
    created_at: f64,
    used_percent: i32,
    resets_at: Option<f64>,
    cycle_generation: Option<i64>,
}

fn suppress_recovered_full_remaining_jumps(mut rows: Vec<QuotaHistoryRow>) -> Vec<QuotaHistoryRow> {
    suppress_recovered_full_remaining_jumps_for_window(
        &mut rows,
        |row| row.five_hour_used_percent,
        |row| row.five_hour_resets_at,
        |row| row.five_hour_cycle_generation,
        |row, used, reset| {
            row.five_hour_used_percent = Some(used);
            row.five_hour_resets_at = reset;
        },
    );
    suppress_recovered_full_remaining_jumps_for_window(
        &mut rows,
        |row| row.seven_day_used_percent,
        |row| row.seven_day_resets_at,
        |row| row.seven_day_cycle_generation,
        |row, used, reset| {
            row.seven_day_used_percent = Some(used);
            row.seven_day_resets_at = reset;
        },
    );
    rows
}

fn suppress_recovered_full_remaining_jumps_for_window(
    rows: &mut [QuotaHistoryRow],
    used: impl Fn(&QuotaHistoryRow) -> Option<i32> + Copy,
    reset: impl Fn(&QuotaHistoryRow) -> Option<f64> + Copy,
    generation: impl Fn(&QuotaHistoryRow) -> Option<i64> + Copy,
    mut replace: impl FnMut(&mut QuotaHistoryRow, i32, Option<f64>),
) {
    let mut groups: HashMap<String, Vec<WindowObservation>> = HashMap::new();
    for (row_index, row) in rows.iter().enumerate() {
        let Some(used_percent) = used(row) else {
            continue;
        };
        groups
            .entry(row.history_match_key())
            .or_default()
            .push(WindowObservation {
                row_index,
                created_at: row.created_at,
                used_percent: used_percent.clamp(0, 100),
                resets_at: reset(row),
                cycle_generation: generation(row),
            });
    }

    for observations in groups.values() {
        let mut position = 1;
        while position + 1 < observations.len() {
            let previous = observations[position - 1];
            let current = observations[position];
            if current.used_percent > previous.used_percent - 20 {
                position += 1;
                continue;
            }

            let recovery = observations[(position + 1)..]
                .iter()
                .copied()
                .take_while(|candidate| {
                    candidate.created_at - current.created_at <= TRANSIENT_RESET_GLITCH_MAX_SECONDS
                })
                .find(|candidate| {
                    same_cycle_for_window(
                        Some(candidate.used_percent),
                        candidate.resets_at,
                        candidate.cycle_generation,
                        Some(previous.used_percent),
                        previous.resets_at,
                        previous.cycle_generation,
                    )
                        && candidate.used_percent >= previous.used_percent - 5
                });
            let Some(recovery) = recovery else {
                position += 1;
                continue;
            };
            let Some(stable_reset) = previous.resets_at else {
                position += 1;
                continue;
            };
            let recovered_floor = previous.used_percent.min(recovery.used_percent);
            for observation in observations[position..]
                .iter()
                .take_while(|observation| observation.row_index < recovery.row_index)
            {
                if observation.used_percent <= recovered_floor - 20
                    && stable_reset > observation.created_at
                {
                    replace(
                        &mut rows[observation.row_index],
                        previous.used_percent,
                        previous.resets_at,
                    );
                }
            }
            position = observations
                .iter()
                .position(|observation| observation.row_index == recovery.row_index)
                .unwrap_or(position + 1);
        }
    }
}

fn suppress_recovered_usage_spikes(mut rows: Vec<QuotaHistoryRow>) -> Vec<QuotaHistoryRow> {
    suppress_recovered_usage_spikes_for_window(
        &mut rows,
        |row| row.five_hour_used_percent,
        |row| row.five_hour_resets_at,
        |row| row.five_hour_cycle_generation,
        |row, value| row.five_hour_used_percent = value,
    );
    suppress_recovered_usage_spikes_for_window(
        &mut rows,
        |row| row.seven_day_used_percent,
        |row| row.seven_day_resets_at,
        |row| row.seven_day_cycle_generation,
        |row, value| row.seven_day_used_percent = value,
    );
    rows
}

#[derive(Clone, Copy)]
struct UsageSpikeEntry {
    row_index: usize,
    used_percent: i32,
    resets_at: Option<f64>,
    cycle_generation: Option<i64>,
}

fn suppress_recovered_usage_spikes_for_window(
    rows: &mut [QuotaHistoryRow],
    used: impl Fn(&QuotaHistoryRow) -> Option<i32> + Copy,
    reset: impl Fn(&QuotaHistoryRow) -> Option<f64> + Copy,
    generation: impl Fn(&QuotaHistoryRow) -> Option<i64> + Copy,
    mut set_used: impl FnMut(&mut QuotaHistoryRow, Option<i32>),
) {
    let mut groups: HashMap<String, Vec<UsageSpikeEntry>> = HashMap::new();
    for (index, row) in rows.iter().enumerate() {
        if let Some(value) = used(row) {
            groups
                .entry(row.history_match_key())
                .or_default()
                .push(UsageSpikeEntry {
                    row_index: index,
                    used_percent: value.clamp(0, 100),
                    resets_at: reset(row),
                    cycle_generation: generation(row),
                });
        }
    }

    for entries in groups.values() {
        for mut cycle_entries in reset_clusters(entries) {
            cycle_entries.sort_by_key(|entry| entry.row_index);
            for position in 0..cycle_entries.len() {
                let current = cycle_entries[position];
                let previous = position
                    .checked_sub(1)
                    .map(|index| cycle_entries[index].used_percent);
                let next = cycle_entries
                    .get(position + 1)
                    .map(|entry| entry.used_percent);
                if let Some(replacement) =
                    recovered_usage_spike_replacement(current.used_percent, previous, next)
                {
                    set_used(&mut rows[current.row_index], Some(replacement));
                }
            }
        }
    }
}

fn reset_clusters(entries: &[UsageSpikeEntry]) -> Vec<Vec<UsageSpikeEntry>> {
    let mut clusters = Vec::new();
    let mut current = Vec::new();
    for entry in entries.iter().copied() {
        let starts_new_cluster = current.last().is_some_and(|previous: &UsageSpikeEntry| {
            if let (Some(previous_generation), Some(current_generation)) =
                (previous.cycle_generation, entry.cycle_generation)
            {
                return previous_generation != current_generation;
            }
            !same_cycle_for_window(
                Some(entry.used_percent),
                entry.resets_at,
                entry.cycle_generation,
                Some(previous.used_percent),
                previous.resets_at,
                previous.cycle_generation,
            )
        });
        if starts_new_cluster {
            clusters.push(std::mem::take(&mut current));
        }
        current.push(entry);
    }
    if !current.is_empty() {
        clusters.push(current);
    }
    clusters
}

fn recovered_usage_spike_replacement(
    current: i32,
    previous: Option<i32>,
    next: Option<i32>,
) -> Option<i32> {
    if let Some(next) = next.filter(|next| current - *next >= 20) {
        if let Some(previous) = previous {
            if current < 95 && current - previous < 20 {
                return None;
            }
            if previous < 95 {
                return Some(previous);
            }
        }
        return Some(next);
    }
    previous.filter(|previous| *previous <= 5 && current >= 95)
}

fn quota_remaining(
    row: Option<&QuotaHistoryRow>,
    next_row: Option<&QuotaHistoryRow>,
    previous_boundary: f64,
    at: f64,
    remaining: impl Fn(&QuotaHistoryRow) -> Option<f64>,
    resets_at: impl Fn(&QuotaHistoryRow) -> Option<f64>,
    generation: impl Fn(&QuotaHistoryRow) -> Option<i64>,
    reset_anchor: impl Fn(&QuotaHistoryRow) -> Option<i64>,
) -> Option<f64> {
    let row = row?;
    let value = remaining(row)?;
    let boundary_reset = if generation(row).is_some() {
        reset_anchor(row)
            .filter(|anchor| *anchor != 0)
            .and_then(|_| resets_at(row))
    } else {
        resets_at(row)
    };
    if let Some(reset) = boundary_reset.filter(|reset| *reset > row.created_at) {
        if previous_boundary < reset && at >= reset {
            return Some(1.0);
        }
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
) -> Option<f64> {
    let next_row = next_row?;
    if !same_cycle_for_window(
        remaining_used(row, remaining),
        resets_at(row),
        generation(row),
        remaining_used(next_row, remaining),
        resets_at(next_row),
        generation(next_row),
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
