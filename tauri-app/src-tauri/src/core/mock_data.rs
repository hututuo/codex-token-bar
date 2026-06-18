use crate::models::{
    AccountInfo, ActivityDay, CacheHitRankingItem, DashboardSnapshot, DashboardStats,
    QuotaLimit, QuotaSnapshot, RecentUsagePoint, ResetCreditSummary,
};

pub fn dashboard_snapshot() -> DashboardSnapshot {
    DashboardSnapshot {
        generated_at: "2026-06-18T13:30:00Z".into(),
        account: AccountInfo {
            display_name: "来先生".into(),
            plan_label: "Pro".into(),
        },
        stats: DashboardStats {
            total_tokens: 4_360_000_000,
            peak_day_tokens: 390_000_000,
            peak_thread_tokens: 410_000_000,
            current_streak_days: 10,
            longest_streak_days: 27,
            total_calls: 513,
            total_threads: 182,
        },
        quota: QuotaSnapshot {
            five_hour: QuotaLimit {
                label: "5h".into(),
                remaining_percent: 1.0,
                used_percent: 0.0,
                resets_at: "00:59".into(),
            },
            seven_day: QuotaLimit {
                label: "7d".into(),
                remaining_percent: 0.83,
                used_percent: 0.17,
                resets_at: "06/18 09:56".into(),
            },
            reset_credit: ResetCreditSummary {
                available_count: 1,
                status: "1 张重置卡可用".into(),
            },
            pace_label: "节奏稳，多 3%".into(),
        },
        activity_days: mock_activity_days(),
        recent_usage_24h: mock_recent_usage(),
        cache_hit_ranking: vec![
            CacheHitRankingItem {
                rank: 1,
                title: "Codex Token Bar 迁移方案".into(),
                subtitle: "多轮缓存命中稳定".into(),
                hit_rate: 0.94,
                input_tokens: 820_000,
                cached_tokens: 771_000,
            },
            CacheHitRankingItem {
                rank: 2,
                title: "悬浮窗视觉调整".into(),
                subtitle: "排除第一轮后统计".into(),
                hit_rate: 0.89,
                input_tokens: 610_000,
                cached_tokens: 543_000,
            },
            CacheHitRankingItem {
                rank: 3,
                title: "会话消失修复".into(),
                subtitle: "provider / index / backup".into(),
                hit_rate: 0.86,
                input_tokens: 540_000,
                cached_tokens: 464_000,
            },
        ],
    }
}

fn mock_activity_days() -> Vec<ActivityDay> {
    (0..84)
        .map(|idx| {
            let value = if idx > 64 {
                ((idx - 63) as f64 / 22.0).min(1.0)
            } else if idx % 17 == 0 {
                0.32
            } else {
                0.06
            };
            ActivityDay {
                date: format!("2026-{:02}-{:02}", 3 + idx / 28, 1 + idx % 28),
                tokens: (value * 58_000_000.0) as u64,
                calls: (value * 16.0).round() as u32,
                cache_hit_rate: 0.78 + value * 0.18,
            }
        })
        .collect()
}

fn mock_recent_usage() -> Vec<RecentUsagePoint> {
    (0..48)
        .map(|idx| {
            let active = idx > 34;
            let wave = ((idx % 7) as f64 + 1.0) / 8.0;
            RecentUsagePoint {
                label: format!("{:02}:00", (idx / 2) % 24),
                tokens: if active { (wave * 8_600_000.0) as u64 } else { 0 },
                calls: if active { (wave * 8.0).round() as u32 } else { 0 },
                cache_hit_rate: if active { Some(0.84 + wave * 0.12) } else { None },
                five_hour_remaining_percent: if idx > 30 { Some(1.0 - wave * 0.08) } else { None },
                seven_day_remaining_percent: if idx > 30 { Some(0.84 - wave * 0.02) } else { None },
            }
        })
        .collect()
}
