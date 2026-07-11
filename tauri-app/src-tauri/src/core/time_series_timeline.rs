pub(crate) const LONG_RECENT_INTERVAL_SECONDS: i64 = 5 * 60;
pub(crate) const LONG_RECENT_POINT_COUNT: i64 = 30 * 24 * 12;

pub(crate) fn aligned_bin_starts(
    now_epoch: i64,
    interval_seconds: i64,
    point_count: i64,
) -> Vec<i64> {
    let end_bin = now_epoch - now_epoch.rem_euclid(interval_seconds);
    let start_bin = end_bin - point_count.saturating_sub(1) * interval_seconds;
    (0..point_count)
        .map(|index| start_bin + index * interval_seconds)
        .collect()
}

pub(crate) fn long_recent_bin_starts(now_epoch: i64) -> Vec<i64> {
    aligned_bin_starts(now_epoch, LONG_RECENT_INTERVAL_SECONDS, LONG_RECENT_POINT_COUNT)
}
