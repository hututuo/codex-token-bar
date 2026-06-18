use crate::models::{
    AccountInfo, ActivityDay, CacheHitRankingItem, DashboardSnapshot, DashboardStats,
    FloatingPanelSnapshot, LiveRateSnapshot, ProviderRepairStep, ProviderRepairSnapshot,
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

pub fn live_rate_snapshot() -> LiveRateSnapshot {
    LiveRateSnapshot {
        scope_label: "全会话".into(),
        thread_title: "等待任意会话输出".into(),
        tokens_per_second: 43.1,
        total_tokens_today: 61_461_000,
        requests_today: 513,
        max_tokens_per_second: 200.0,
        precise_enabled: true,
    }
}

pub fn floating_panel_snapshot() -> FloatingPanelSnapshot {
    FloatingPanelSnapshot {
        tokens_per_second: 43.1,
        trend_label: "节奏稳，多 3%".into(),
        total_tokens_label: "总 43.6亿".into(),
        today_tokens_label: "今 6146.1万".into(),
        requests_label: "次 513".into(),
        five_hour_label: "5h 100% 00:59".into(),
        seven_day_label: "7d 83% 06/18".into(),
        unread: true,
    }
}

pub fn provider_repair_snapshot() -> ProviderRepairSnapshot {
    ProviderRepairSnapshot {
        detected_provider: "openai".into(),
        session_files_found: 182,
        inconsistent_count: 0,
        steps: vec![
            ProviderRepairStep {
                label: "扫描".into(),
                status: "未发现不一致".into(),
                done: true,
                healthy: true,
            },
            ProviderRepairStep {
                label: "备份".into(),
                status: "等待备份".into(),
                done: false,
                healthy: true,
            },
            ProviderRepairStep {
                label: "修复".into(),
                status: "未进行修复".into(),
                done: false,
                healthy: true,
            },
            ProviderRepairStep {
                label: "验证".into(),
                status: "未验证".into(),
                done: false,
                healthy: true,
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
