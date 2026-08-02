use super::*;
use crate::models::{AccountInfo, QuotaLimit, ResetCreditSummary};
use serde::Deserialize;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SharedIdentityFixture {
    fixture_version: u32,
    identity_version: i64,
    scenarios: Vec<SharedIdentityScenario>,
}

#[derive(Debug, Deserialize)]
struct SharedIdentityScenario {
    id: String,
    steps: Vec<SharedIdentityStep>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SharedIdentityStep {
    operation: String,
    home_identity: Option<String>,
    stable_account_key: Option<String>,
    display_name: String,
    plan: String,
    limit_id: String,
    source: Option<String>,
    used_percent: Option<i32>,
    expected_accepted: Option<bool>,
    expected_used_percents: Option<Vec<i32>>,
}

#[test]
fn shared_quota_history_identity_fixture_is_strict_and_fail_closed() {
    let fixture: SharedIdentityFixture = serde_json::from_str(include_str!(
        "../../../../Tests/SharedFixtures/quota-history-identity-v1.json"
    ))
    .unwrap();
    assert_eq!(fixture.fixture_version, 1);
    assert_eq!(fixture.identity_version, QUOTA_HISTORY_IDENTITY_VERSION);

    for scenario in fixture.scenarios {
        let path = temp_db_path(&format!("shared-identity-{}", scenario.id));
        let database = QuotaHistoryDatabase { path: path.clone() };
        let connection = database.open().unwrap();
        ensure_schema(&connection).unwrap();
        drop(connection);

        for step in scenario.steps {
            assert!(
                !step.limit_id.trim().is_empty(),
                "scenario {} step limit id",
                scenario.id
            );
            let reset = now_unix() as i64 + 3_600;
            let used_percent = step.used_percent.unwrap_or_default();
            let snapshot = bundle_with_plan(
                &step.display_name,
                &step.plan,
                used_percent as f64 / 100.0,
                reset,
                used_percent as f64 / 100.0,
                reset + 500_000,
            );
            let identity = step.home_identity.as_deref().and_then(|home| {
                QuotaHistoryIdentity::from_canonical_parts(
                    Path::new(home),
                    step.stable_account_key.as_deref(),
                    &step.plan,
                    &step.limit_id,
                )
            });

            match step.operation.as_str() {
                "write" => {
                    let accepted = database
                        .record_for_identity(identity.as_ref(), &snapshot)
                        .unwrap();
                    assert_eq!(
                        accepted,
                        step.expected_accepted.unwrap_or(true),
                        "scenario {} write acceptance",
                        scenario.id
                    );
                }
                "read" => {
                    let mut actual = database
                        .rows_for_identity(identity.as_ref(), &snapshot, 31.0 * 24.0 * 60.0 * 60.0)
                        .unwrap()
                        .into_iter()
                        .filter_map(|row| row.five_hour_used_percent)
                        .collect::<Vec<_>>();
                    actual.sort_unstable();
                    let mut expected = step.expected_used_percents.unwrap_or_default();
                    expected.sort_unstable();
                    assert_eq!(actual, expected, "scenario {} read", scenario.id);
                }
                "legacyWrite" => {
                    let connection = database.open().unwrap();
                    let mut legacy_row = history_row(
                        now_unix() - 600.0,
                        &format!(
                            "{}|{}|{}",
                            step.display_name, step.plan, step.limit_id
                        ),
                        &step.plan,
                        Some(&step.limit_id),
                        used_percent,
                        reset as f64,
                        used_percent,
                        (reset + 500_000) as f64,
                    );
                    legacy_row.account_name = Some(step.display_name.clone());
                    insert_history_row_with_source(
                        &connection,
                        &legacy_row,
                        step.source.as_deref(),
                    );
                }
                operation => panic!("unsupported fixture operation {operation}"),
            }
        }

        let _ = std::fs::remove_file(path);
    }
}

#[test]
fn attribution_identity_serializes_only_hashed_scope_and_canonical_dimensions() {
    let home = "/Users/private-account/.codex";
    let stable_account_key = "sub:private-account-id";
    let identity = QuotaHistoryIdentity::from_canonical_parts(
        Path::new(home),
        Some(stable_account_key),
        "chatgpt-pro",
        "codex",
    )
    .unwrap();
    let public_identity = identity.attribution_identity();

    assert_eq!(public_identity.plan, "Pro");
    assert_eq!(public_identity.limit, "codex");
    assert_eq!(public_identity.scope_key.len(), "sha256:".len() + 64);
    assert!(public_identity.scope_key.starts_with("sha256:"));
    assert!(public_identity.scope_key["sha256:".len()..]
        .chars()
        .all(|character| character.is_ascii_hexdigit()));

    let serialized = serde_json::to_value(&public_identity).unwrap();
    assert_eq!(serialized["scopeKey"], public_identity.scope_key);
    assert_eq!(serialized["plan"], "Pro");
    assert_eq!(serialized["limit"], "codex");
    assert!(serialized.get("scope_key").is_none());
    let serialized_text = serialized.to_string();
    assert!(!serialized_text.contains(home));
    assert!(!serialized_text.contains(stable_account_key));

    let mut bundle = bundle("本地用户", 0.2, 1_781_715_600, 0.4, 1_782_144_492);
    bundle.updated_at = "2026-07-31T08:20:35Z".into();
    bundle.attribution_identity = Some(public_identity.clone());
    let bundle_json = serde_json::to_value(&bundle).unwrap();
    assert_eq!(bundle_json["updatedAt"], "2026-07-31T08:20:35Z");
    assert_eq!(
        bundle_json["attributionIdentity"]["scopeKey"],
        public_identity.scope_key
    );
    assert!(bundle_json.get("updated_at").is_none());
    assert!(bundle_json.get("attribution_identity").is_none());
    let bundle_text = bundle_json.to_string();
    assert!(!bundle_text.contains(home));
    assert!(!bundle_text.contains(stable_account_key));

    let other_home = QuotaHistoryIdentity::from_canonical_parts(
        Path::new("/Users/other/.codex"),
        Some(stable_account_key),
        "Pro",
        "codex",
    )
    .unwrap()
    .attribution_identity();
    let other_account = QuotaHistoryIdentity::from_canonical_parts(
        Path::new(home),
        Some("sub:other-account-id"),
        "Pro",
        "codex",
    )
    .unwrap()
    .attribution_identity();
    let other_limit = QuotaHistoryIdentity::from_canonical_parts(
        Path::new(home),
        Some(stable_account_key),
        "Pro",
        "gpt-5.3-codex-spark",
    )
    .unwrap()
    .attribution_identity();
    assert_ne!(public_identity.scope_key, other_home.scope_key);
    assert_ne!(public_identity.scope_key, other_account.scope_key);
    assert_ne!(public_identity.scope_key, other_limit.scope_key);
}

#[test]
fn legacy_shared_quota_history_is_copied_to_tauri_support_on_first_use() {
    let root = temp_dir_path("legacy-migration");
    let _env = app_paths::app_path_test_env_guard(&[
        ("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", root.join("support")),
        (
            "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
            root.join("support").join("CodexTokenBarTauri"),
        ),
    ]);
    let legacy_path = app_paths::legacy_shared_quota_history_database_path().unwrap();
    std::fs::create_dir_all(legacy_path.parent().unwrap()).unwrap();
    let connection = rusqlite::Connection::open(&legacy_path).unwrap();
    ensure_schema(&connection).unwrap();
    insert_history_row_with_source(
        &connection,
        &history_row(
            now_unix() - 600.0,
            "legacy-user|Pro|codex",
            "Pro",
            Some("codex"),
            24,
            now_unix() + 3_600.0,
            41,
            now_unix() + 500_000.0,
        ),
        Some("swift"),
    );
    drop(connection);

    let tauri_path = app_paths::quota_history_database_path().unwrap();
    assert!(legacy_path.ends_with("CodexTokenBar/quota-history.sqlite"));
    assert!(tauri_path.ends_with("CodexTokenBarTauri/quota-history.sqlite"));
    assert!(!tauri_path.exists());

    let database = QuotaHistoryDatabase::default().unwrap();
    assert_eq!(database.path, tauri_path);
    assert!(legacy_path.exists());
    assert!(database.path.exists());

    let migrated = rusqlite::Connection::open(&database.path).unwrap();
    let stored = migrated
        .query_row(
            "SELECT source, five_hour_used_percent, seven_day_used_percent FROM quota_snapshots WHERE account_key = 'legacy-user|Pro|codex';",
            [],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<i32>>(1)?,
                    row.get::<_, Option<i32>>(2)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(stored.0.as_deref(), Some("swift"));
    assert_eq!(stored.1, Some(24));
    assert_eq!(stored.2, Some(41));

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn existing_tauri_quota_history_is_not_overwritten_by_legacy_migration() {
    let root = temp_dir_path("legacy-migration-existing-target");
    let _env = app_paths::app_path_test_env_guard(&[
        ("CODEX_TOKEN_BAR_SUPPORT_BASE_DIR", root.join("support")),
        (
            "CODEX_TOKEN_BAR_TAURI_SUPPORT_DIR",
            root.join("support").join("CodexTokenBarTauri"),
        ),
    ]);
    let legacy_path = app_paths::legacy_shared_quota_history_database_path().unwrap();
    std::fs::create_dir_all(legacy_path.parent().unwrap()).unwrap();
    let legacy = rusqlite::Connection::open(&legacy_path).unwrap();
    ensure_schema(&legacy).unwrap();
    insert_history_row_with_source(
        &legacy,
        &history_row(
            now_unix() - 600.0,
            "legacy-user|Pro|codex",
            "Pro",
            Some("codex"),
            80,
            now_unix() + 3_600.0,
            81,
            now_unix() + 500_000.0,
        ),
        Some("swift"),
    );
    drop(legacy);

    let tauri_path = app_paths::quota_history_database_path().unwrap();
    std::fs::create_dir_all(tauri_path.parent().unwrap()).unwrap();
    let tauri = rusqlite::Connection::open(&tauri_path).unwrap();
    ensure_schema(&tauri).unwrap();
    insert_history_row_with_source(
        &tauri,
        &history_row(
            now_unix() - 300.0,
            "tauri-user|Plus|codex",
            "Plus",
            Some("codex"),
            12,
            now_unix() + 3_600.0,
            13,
            now_unix() + 500_000.0,
        ),
        Some("tauri"),
    );
    drop(tauri);

    let database = QuotaHistoryDatabase::default().unwrap();
    assert_eq!(database.path, tauri_path);
    let retained = rusqlite::Connection::open(&database.path).unwrap();
    let tauri_count: i64 = retained
        .query_row(
            "SELECT count(*) FROM quota_snapshots WHERE account_key = 'tauri-user|Plus|codex';",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let legacy_count: i64 = retained
        .query_row(
            "SELECT count(*) FROM quota_snapshots WHERE account_key = 'legacy-user|Pro|codex';",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(tauri_count, 1);
    assert_eq!(legacy_count, 0);

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn record_normalizes_same_reset_window_regressions() {
    let path = temp_db_path("normalize");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.84, reset as i64, 0.20, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 0.71, reset as i64, 0.21, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database.recent_five_minute_history(4).unwrap();
    let latest = history.last().unwrap();
    assert_eq!(latest.five_hour_remaining_percent, Some(0.16));
    assert_eq!(latest.seven_day_remaining_percent, Some(0.79));

    let _ = std::fs::remove_file(path);
}

#[test]
fn normalizer_matches_swift_reset_grace_and_recovered_spike_rules() {
    let reset = 1_800_000_000.0;

    assert_eq!(
        normalized_used_percent(Some(71), Some(reset + 90.0), Some(84), Some(reset)),
        Some(84)
    );
    assert_eq!(
        normalized_used_percent(Some(62), Some(reset + 90.0), Some(84), Some(reset)),
        Some(62)
    );
    assert_eq!(
        normalized_used_percent(Some(71), Some(reset + 121.0), Some(84), Some(reset)),
        Some(71)
    );
    assert_eq!(normalized_used_percent(Some(110), None, None, None), Some(100));
}

#[test]
fn history_normalizes_regression_across_legacy_and_canonical_keys() {
    let created_at = 1_800_000_000.0;
    let reset = created_at + 3.0 * 60.0 * 60.0;
    let previous = history_row(
        created_at,
        "tester|pro",
        "pro",
        None,
        84,
        reset,
        40,
        reset + 500_000.0,
    );
    let mut legacy = previous.clone();
    legacy.created_at += 5.0 * 60.0;
    legacy.account_key = "tester|Pro|codex".into();
    legacy.plan_type = Some("Pro".into());
    legacy.limit_name = Some("codex".into());
    legacy.five_hour_used_percent = Some(71);
    legacy.five_hour_resets_at = Some(reset + 90.0);

    let sanitized = super::series::sanitized_rows(vec![previous, legacy]);

    assert_eq!(sanitized[1].five_hour_used_percent, Some(84));
}

#[test]
fn history_suppresses_midcycle_spike_across_reset_timestamp_drift() {
    let created_at = 1_800_000_000.0;
    let reset = created_at + 3.0 * 60.0 * 60.0;
    let mut previous = history_row(
        created_at,
        "tester|Pro|codex",
        "Pro",
        Some("codex"),
        10,
        reset,
        20,
        reset + 500_000.0,
    );
    let mut spike = previous.clone();
    spike.created_at += 5.0 * 60.0;
    spike.five_hour_used_percent = Some(45);
    spike.five_hour_resets_at = Some(reset + 90.0);
    let mut recovered = previous.clone();
    recovered.created_at += 10.0 * 60.0;
    recovered.five_hour_used_percent = Some(12);
    previous.status = "stable-before".into();
    spike.status = "official-spike".into();
    recovered.status = "stable-after".into();

    let sanitized = super::series::sanitized_rows(vec![previous, spike, recovered]);

    assert_eq!(sanitized[1].five_hour_used_percent, Some(10));
    assert_eq!(sanitized[2].five_hour_used_percent, Some(12));
}

#[test]
fn interval_history_interpolates_between_same_cycle_samples() {
    let now = 1_800_000_000.0;
    let reset = now + 3.0 * 60.0 * 60.0;
    let first = history_row(
        now - 4.0 * 60.0 * 60.0,
        "tester|Pro|codex",
        "Pro",
        Some("codex"),
        20,
        reset,
        40,
        reset + 500_000.0,
    );
    let mut next = first.clone();
    next.created_at = now - 30.0 * 60.0;
    next.five_hour_used_percent = Some(22);

    let history = super::series::make_interval_history_at(
        vec![first, next],
        49,
        5 * 60,
        now,
    );

    assert!(
        history
            .iter()
            .filter_map(|point| point.five_hour_remaining_percent)
            .any(|value| value > 0.781 && value < 0.799),
        "quota curve should interpolate 80% to 78% across a no-sample gap"
    );
}

#[test]
fn history_recovers_from_isolated_full_usage_spike() {
    let path = temp_db_path("full-spike");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.00, reset as i64, 0.20, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 1.00, reset as i64, 0.20, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 0.15, reset as i64, 0.21, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database.recent_five_minute_history(4).unwrap();
    let latest = history.last().unwrap();
    assert_eq!(latest.five_hour_remaining_percent, Some(0.85));
    assert_eq!(latest.seven_day_remaining_percent, Some(0.79));

    let _ = std::fs::remove_file(path);
}

#[test]
fn history_suppresses_recovered_full_usage_spike_runs() {
    let path = temp_db_path("full-spike-run");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.02, reset as i64, 0.03, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 1.00, reset as i64, 1.00, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 1.00, reset as i64, 1.00, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 0.06, reset as i64, 0.04, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database.recent_five_minute_history(12).unwrap();
    assert!(history
        .iter()
        .all(|point| point.five_hour_remaining_percent != Some(0.0)));
    assert!(history
        .iter()
        .all(|point| point.seven_day_remaining_percent != Some(0.0)));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.94));
    assert_eq!(history.last().unwrap().seven_day_remaining_percent, Some(0.96));

    let _ = std::fs::remove_file(path);
}

#[test]
fn record_writes_canonical_codex_key_and_source() {
    let path = temp_db_path("canonical-key-source");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("来先生", 0.01, reset as i64, 0.50, (reset + 500_000.0) as i64))
        .unwrap();

    let connection = database.open().unwrap();
    let stored = connection
        .query_row(
            r#"
            SELECT account_key, plan_type, limit_name, source,
                   identity_version, home_identity, stable_account_key,
                   identity_plan_type, identity_limit_id
            FROM quota_snapshots ORDER BY id DESC LIMIT 1;
            "#,
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, Option<String>>(8)?,
                ))
            },
        )
        .unwrap();

    assert_eq!(stored.0, "来先生|Pro|codex");
    assert_eq!(stored.1.as_deref(), Some("Pro"));
    assert_eq!(stored.2.as_deref(), Some("codex"));
    assert_eq!(stored.3.as_deref(), Some("tauri"));
    assert_eq!(stored.4, Some(QUOTA_HISTORY_IDENTITY_VERSION));
    assert!(stored.5.as_deref().is_some_and(|home| !home.is_empty()));
    assert_eq!(stored.6.as_deref(), Some("sub:test:来先生"));
    assert_eq!(stored.7.as_deref(), Some("Pro"));
    assert_eq!(stored.8.as_deref(), Some("codex"));

    let _ = std::fs::remove_file(path);
}

#[test]
fn record_uses_read_plan_label_instead_of_inventing_pro() {
    let path = temp_db_path("plan-label");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle_with_plan(
            "来先生",
            "Plus",
            0.01,
            reset as i64,
            0.50,
            (reset + 500_000.0) as i64,
        ))
        .unwrap();

    let connection = database.open().unwrap();
    let stored = connection
        .query_row(
            "SELECT account_key, plan_type, limit_name FROM quota_snapshots ORDER BY id DESC LIMIT 1;",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .unwrap();

    assert_eq!(stored.0, "来先生|Plus|codex");
    assert_eq!(stored.1.as_deref(), Some("Plus"));
    assert_eq!(stored.2.as_deref(), Some("codex"));

    let _ = std::fs::remove_file(path);
}

#[test]
fn record_unknown_plan_does_not_write_fake_pro() {
    let path = temp_db_path("unknown-plan");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;
    let snapshot = bundle_with_plan(
        "来先生",
        "计划待读取",
        0.01,
        reset as i64,
        0.50,
        (reset + 500_000.0) as i64,
    );
    let identity = QuotaHistoryIdentity::from_bundle(
        Path::new("/fixture/unknown-plan"),
        Some("sub:unknown-plan"),
        &snapshot,
        Some("codex"),
    );

    assert!(identity.is_none());
    assert!(!database
        .record_for_identity(identity.as_ref(), &snapshot)
        .unwrap());

    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let stored_count: i64 = connection
        .query_row("SELECT count(*) FROM quota_snapshots;", [], |row| row.get(0))
        .unwrap();
    assert_eq!(stored_count, 0);

    let _ = std::fs::remove_file(path);
}

#[test]
fn blank_stable_limit_cannot_write_or_read_codex_history() {
    let path = temp_db_path("blank-stable-limit");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() as i64 + 3_600;
    let codex_snapshot = bundle_with_plan(
        "Limit User",
        "Plus",
        0.10,
        reset,
        0.10,
        reset + 500_000,
    );
    let codex_identity = QuotaHistoryIdentity::from_canonical_parts(
        Path::new("/fixture/blank-limit"),
        Some("sub:blank-limit"),
        "Plus",
        "codex",
    )
    .unwrap();
    database
        .record_for_identity(Some(&codex_identity), &codex_snapshot)
        .unwrap();

    for limit_id in ["", "   "] {
        let blank_snapshot = bundle_with_plan(
            "Limit User",
            "Plus",
            0.90,
            reset,
            0.90,
            reset + 500_000,
        );
        let blank_identity = QuotaHistoryIdentity::from_canonical_parts(
            Path::new("/fixture/blank-limit"),
            Some("sub:blank-limit"),
            "Plus",
            limit_id,
        );
        let accepted = database
            .record_for_identity(blank_identity.as_ref(), &blank_snapshot)
            .unwrap();
        let blank_rows = database
            .rows_for_identity(
                blank_identity.as_ref(),
                &blank_snapshot,
                31.0 * 24.0 * 60.0 * 60.0,
            )
            .unwrap();

        assert!(blank_identity.is_none());
        assert!(!accepted);
        assert!(blank_rows.is_empty());
    }

    let codex_used = database
        .rows_for_identity(
            Some(&codex_identity),
            &codex_snapshot,
            31.0 * 24.0 * 60.0 * 60.0,
        )
        .unwrap()
        .into_iter()
        .filter_map(|row| row.five_hour_used_percent)
        .collect::<Vec<_>>();
    assert_eq!(codex_used, vec![10]);

    let _ = std::fs::remove_file(path);
}

#[test]
fn schema_adds_versioned_identity_without_rewriting_legacy_rows() {
    let path = temp_db_path("identity-migration");
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            r#"
            CREATE TABLE quota_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                account_key TEXT NOT NULL,
                plan_type TEXT,
                limit_name TEXT,
                account_name TEXT,
                five_hour_used_percent INTEGER,
                five_hour_resets_at REAL,
                seven_day_used_percent INTEGER,
                seven_day_resets_at REAL,
                status TEXT NOT NULL
            );
            INSERT INTO quota_snapshots (
                created_at, account_key, plan_type, limit_name, account_name,
                five_hour_used_percent, five_hour_resets_at,
                seven_day_used_percent, seven_day_resets_at, status
            ) VALUES (1, 'Legacy User|Pro|codex', 'Pro', 'codex', 'Legacy User',
                      10, 100, 20, 200, 'legacy');
            "#,
        )
        .unwrap();

    ensure_schema(&connection).unwrap();
    let columns = connection
        .prepare("PRAGMA table_info(quota_snapshots);")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .collect::<SqlResult<Vec<_>>>()
        .unwrap();

    for expected in [
        "source",
        "identity_version",
        "home_identity",
        "stable_account_key",
        "identity_plan_type",
        "identity_limit_id",
    ] {
        assert!(columns.iter().any(|column| column == expected));
    }
    assert!(columns.iter().all(|column| {
        !column.contains("fingerprint")
            && !column.contains("token")
            && !column.contains("auth")
    }));
    let legacy = connection
        .query_row(
            "SELECT account_key, identity_version, home_identity, stable_account_key FROM quota_snapshots WHERE status = 'legacy';",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<i64>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(legacy.0, "Legacy User|Pro|codex");
    assert_eq!(legacy.1, None);
    assert_eq!(legacy.2, None);
    assert_eq!(legacy.3, None);

    let claim_table_count: i64 = connection
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'quota_history_legacy_claims';",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(claim_table_count, 1);

    let _ = std::fs::remove_file(path);
}

#[test]
fn recent_history_includes_legacy_fake_pro_rows_for_same_codex_account() {
    let path = temp_db_path("legacy-fake-pro");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let reset = now + 3_600.0;

    insert_history_row_with_source(
        &connection,
        &history_row(
            now - 600.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            10,
            reset,
            20,
            reset + 500_000.0,
        ),
        Some("swift"),
    );
    database
        .record(&bundle_with_plan(
            "tester",
            "Plus",
            0.15,
            reset as i64,
            0.21,
            (reset + 500_000.0) as i64,
        ))
        .unwrap();

    let history = database.recent_five_minute_history(12).unwrap();
    assert!(history
        .iter()
        .filter_map(|point| point.five_hour_remaining_percent)
        .any(|value| value > 0.85 && value < 0.90));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.85));

    let _ = std::fs::remove_file(path);
}

#[test]
fn legacy_fake_pro_bridge_is_time_and_source_bounded() {
    let path = temp_db_path("legacy-fake-pro-bounds");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let reset = now + 3_600.0;

    for (created_at, source, used) in [
        (now - 46.0 * 24.0 * 60.0 * 60.0, Some("swift"), 80),
        (now - 600.0, Some("tauri"), 70),
    ] {
        insert_history_row_with_source(
            &connection,
            &history_row(
                created_at,
                "tester|Pro|codex",
                "Pro",
                Some("codex"),
                used,
                reset,
                used,
                reset + 500_000.0,
            ),
            source,
        );
    }
    drop(connection);

    let snapshot = bundle_with_plan(
        "tester",
        "Plus",
        0.15,
        reset as i64,
        0.15,
        (reset + 500_000.0) as i64,
    );
    let identity = QuotaHistoryIdentity::from_bundle(
        Path::new("/fixture/bounded-bridge"),
        Some("sub:bounded-bridge"),
        &snapshot,
        Some("codex"),
    )
    .unwrap();
    database
        .record_for_identity(Some(&identity), &snapshot)
        .unwrap();
    let used = database
        .rows_for_identity(
            Some(&identity),
            &snapshot,
            365.0 * 24.0 * 60.0 * 60.0,
        )
        .unwrap()
        .into_iter()
        .filter_map(|row| row.five_hour_used_percent)
        .collect::<Vec<_>>();

    assert_eq!(used, vec![15]);
    let _ = std::fs::remove_file(path);
}

#[test]
fn recent_history_includes_legacy_codex_account_key_rows() {
    let path = temp_db_path("legacy-key");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let reset = now + 3_600.0;

    insert_row(
        &connection,
        &history_row(
            now - 600.0,
            "tester|pro",
            "pro",
            None,
            10,
            reset,
            20,
            reset + 500_000.0,
        ),
    )
    .unwrap();
    insert_row(
        &connection,
        &history_row(
            now - 300.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            15,
            reset,
            21,
            reset + 500_000.0,
        ),
    )
    .unwrap();

    let history = database.recent_five_minute_history(12).unwrap();
    assert!(history
        .iter()
        .filter_map(|point| point.five_hour_remaining_percent)
        .any(|value| value > 0.85 && value < 0.90));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.85));

    let _ = std::fs::remove_file(path);
}

#[test]
fn recent_history_mixes_different_sources_for_same_codex_account() {
    let path = temp_db_path("source-merge");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let reset = now + 3_600.0;

    insert_history_row_with_source(
        &connection,
        &history_row(
            now - 600.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            10,
            reset,
            20,
            reset + 500_000.0,
        ),
        Some("swift"),
    );
    insert_history_row_with_source(
        &connection,
        &history_row(
            now - 300.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            12,
            reset,
            21,
            reset + 500_000.0,
        ),
        Some("tauri"),
    );

    let history = database.recent_five_minute_history(12).unwrap();
    assert!(history
        .iter()
        .filter_map(|point| point.five_hour_remaining_percent)
        .any(|value| value > 0.88 && value < 0.90));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.88));

    let _ = std::fs::remove_file(path);
}

#[test]
fn recent_history_does_not_merge_non_codex_limit_rows() {
    let path = temp_db_path("non-codex-limit");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let reset = now + 3_600.0;

    insert_row(
        &connection,
        &history_row(
            now - 600.0,
            "tester|Pro|gpt-5-high",
            "Pro",
            Some("gpt-5-high"),
            50,
            reset,
            50,
            reset + 500_000.0,
        ),
    )
    .unwrap();
    insert_row(
        &connection,
        &history_row(
            now - 300.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            10,
            reset,
            20,
            reset + 500_000.0,
        ),
    )
    .unwrap();

    let history = database.recent_five_minute_history(12).unwrap();
    assert!(history
        .iter()
        .all(|point| point.five_hour_remaining_percent != Some(0.50)));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.90));

    let _ = std::fs::remove_file(path);
}

#[test]
fn history_suppresses_recovered_midcycle_usage_spike() {
    let path = temp_db_path("midcycle-spike");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let reset = now + 3_600.0;

    for (offset, used) in [(-900.0, 10), (-600.0, 45), (-300.0, 12)] {
        insert_row(
            &connection,
            &history_row(
                now + offset,
                "tester|Pro|codex",
                "Pro",
                Some("codex"),
                used,
                reset,
                20,
                reset + 500_000.0,
            ),
        )
        .unwrap();
    }

    let history = database.recent_five_minute_history(12).unwrap();
    assert!(history
        .iter()
        .all(|point| point.five_hour_remaining_percent != Some(0.55)));
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.88));

    let _ = std::fs::remove_file(path);
}

#[test]
fn history_allows_recovery_on_new_reset_window() {
    let path = temp_db_path("new-reset-recovery");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let connection = database.open().unwrap();
    ensure_schema(&connection).unwrap();
    let now = now_unix();
    let old_reset = now - 60.0;
    let new_reset = now + 5.0 * 3_600.0;

    insert_row(
        &connection,
        &history_row(
            now - 600.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            100,
            old_reset,
            20,
            now + 500_000.0,
        ),
    )
    .unwrap();
    insert_row(
        &connection,
        &history_row(
            now - 300.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            0,
            new_reset,
            20,
            now + 500_000.0,
        ),
    )
    .unwrap();

    let history = database.recent_five_minute_history(12).unwrap();
    assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(1.0));

    let _ = std::fs::remove_file(path);
}

#[test]
fn history_reclassifies_legacy_seven_day_only_rows_written_into_five_hour_columns() {
    let created_at = 1_800_000_000.0;
    let seven_day_reset = created_at + 7.0 * 24.0 * 60.0 * 60.0;
    let mut legacy = history_row(
        created_at,
        "tester|Pro|codex",
        "Pro",
        Some("codex"),
        0,
        seven_day_reset,
        0,
        seven_day_reset,
    );
    legacy.seven_day_used_percent = None;
    legacy.seven_day_resets_at = None;

    let sanitized = super::series::sanitized_rows(vec![legacy]);

    assert_eq!(sanitized[0].five_hour_used_percent, None);
    assert_eq!(sanitized[0].five_hour_resets_at, None);
    assert_eq!(sanitized[0].seven_day_used_percent, Some(0));
    assert_eq!(sanitized[0].seven_day_resets_at, Some(seven_day_reset));
}

#[test]
fn history_suppresses_recovered_full_remaining_jump_even_when_reset_temporarily_shifts() {
    let created_at = 1_800_000_000.0;
    let stable_five_reset = created_at + 4.0 * 60.0 * 60.0;
    let shifted_five_reset = stable_five_reset - 2.0 * 60.0 * 60.0;
    let stable_seven_reset = created_at + 157.0 * 60.0 * 60.0;
    let shifted_seven_reset = stable_seven_reset + 2.0 * 60.0 * 60.0;
    let mut previous = history_row(
        created_at,
        "tester|Pro|codex",
        "Pro",
        Some("codex"),
        45,
        stable_five_reset,
        32,
        stable_seven_reset,
    );
    let mut glitch = previous.clone();
    glitch.created_at += 4.0 * 60.0;
    glitch.five_hour_used_percent = Some(2);
    glitch.five_hour_resets_at = Some(shifted_five_reset);
    glitch.seven_day_used_percent = Some(1);
    glitch.seven_day_resets_at = Some(shifted_seven_reset);
    let mut recovered = previous.clone();
    recovered.created_at += 6.0 * 60.0;
    recovered.five_hour_used_percent = Some(46);
    recovered.seven_day_used_percent = Some(33);
    previous.status = "stable-before".into();
    glitch.status = "official-glitch".into();
    recovered.status = "stable-after".into();

    let sanitized = super::series::sanitized_rows(vec![previous, glitch, recovered]);

    assert_eq!(sanitized[1].five_hour_used_percent, Some(45));
    assert_eq!(sanitized[1].five_hour_resets_at, Some(stable_five_reset));
    assert_eq!(sanitized[1].seven_day_used_percent, Some(32));
    assert_eq!(sanitized[1].seven_day_resets_at, Some(stable_seven_reset));
    assert_eq!(sanitized[2].five_hour_used_percent, Some(46));
    assert_eq!(sanitized[2].seven_day_used_percent, Some(33));
}

#[test]
fn quota_history_points_include_start_unix_for_time_aligned_merge() {
    let path = temp_db_path("start-unix");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.20, reset as i64, 0.40, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database
        .recent_five_minute_history(LONG_RECENT_POINT_COUNT as usize)
        .unwrap();
    assert!(history.iter().all(|point| point.start_unix > 0));
    for pair in history.windows(2) {
        assert_eq!(pair[1].start_unix - pair[0].start_unix, 5 * 60);
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn overlay_history_matches_points_by_start_unix_not_position() {
    let mut points = vec![recent_point(1_000), recent_point(1_300), recent_point(1_600)];
    let history = vec![
        QuotaHistoryPoint {
            label: "00:25".into(),
            start_unix: 1_300,
            five_hour_remaining_percent: Some(0.88),
            seven_day_remaining_percent: Some(0.77),
        },
        QuotaHistoryPoint {
            label: "00:30".into(),
            start_unix: 1_600,
            five_hour_remaining_percent: Some(0.66),
            seven_day_remaining_percent: Some(0.55),
        },
    ];

    overlay_history(&mut points, &history);

    assert_eq!(points[0].five_hour_remaining_percent, None);
    assert_eq!(points[1].five_hour_remaining_percent, Some(0.88));
    assert_eq!(points[2].seven_day_remaining_percent, Some(0.55));
}

#[test]
fn reset_crossing_synthesizes_one_full_point_for_five_minute_and_hourly_axes() {
    for interval in [5 * 60, 60 * 60] {
        let now = fixed_series_now(interval);
        let current_bin_start = fixed_bin_start(interval);
        let reset = current_bin_start - 2.0 * interval as f64;
        let row = history_row(
            reset - 2.0 * interval as f64,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            50,
            reset,
            30,
            now + 500_000.0,
        );

        let history =
            super::series::make_interval_history_at(vec![row], 7, interval, now);
        let five_values = history
            .iter()
            .map(|point| point.five_hour_remaining_percent)
            .collect::<Vec<_>>();
        let reset_index = history
            .iter()
            .position(|point| {
                let sample_end = point.start_unix as f64 + interval as f64;
                (point.start_unix as f64) < reset && sample_end >= reset
            })
            .unwrap();

        assert_eq!(five_values.iter().filter(|value| **value == Some(1.0)).count(), 1);
        assert_eq!(five_values[reset_index], Some(1.0));
        assert!(five_values.iter().skip(reset_index + 1).all(Option::is_none));
    }
}

#[test]
fn current_partial_bin_does_not_predict_reset_or_consume_future_row() {
    for interval in [5 * 60, 60 * 60, 6 * 60 * 60] {
        let bin_start = fixed_bin_start(interval);
        let now = bin_start + interval as f64 / 2.0;
        let reset = now + interval as f64 / 4.0;
        let old_row = history_row(
            bin_start - interval as f64,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            50,
            reset,
            30,
            reset + 500_000.0,
        );
        let future_row = history_row(
            now + interval as f64 / 8.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            20,
            reset + 5.0 * interval as f64,
            10,
            reset + 500_000.0,
        );

        let history = super::series::make_interval_history_at(
            vec![old_row.clone(), future_row],
            3,
            interval,
            now,
        );

        assert_eq!(history.last().unwrap().five_hour_remaining_percent, Some(0.50));
        assert_eq!(history.last().unwrap().seven_day_remaining_percent, Some(0.70));

        let crossed = super::series::make_interval_history_at(
            vec![old_row.clone()],
            3,
            interval,
            reset + interval as f64 / 8.0,
        );
        assert_eq!(crossed.last().unwrap().five_hour_remaining_percent, Some(1.0));

        let next_bin = super::series::make_interval_history_at(
            vec![old_row],
            3,
            interval,
            bin_start + interval as f64 + interval as f64 / 8.0,
        );
        assert_eq!(
            next_bin
                .iter()
                .filter(|point| point.five_hour_remaining_percent == Some(1.0))
                .count(),
            1
        );
        assert!(next_bin.last().unwrap().five_hour_remaining_percent.is_none());
    }
}

#[test]
fn reset_carry_is_unknown_until_a_post_reset_sample_then_recovers() {
    let interval = 5 * 60;
    let now = fixed_series_now(interval);
    let current_bin_start = fixed_bin_start(interval);
    let reset = current_bin_start - 2.0 * 60.0 * 60.0;
    let old_row = history_row(
        reset - 60.0 * 60.0,
        "tester|Pro|codex",
        "Pro",
        Some("codex"),
        50,
        reset,
        30,
        now + 500_000.0,
    );
    let new_row = history_row(
        reset + 30.0 * 60.0,
        "tester|Pro|codex",
        "Pro",
        Some("codex"),
        20,
        now + 5.0 * 60.0 * 60.0,
        31,
        now + 500_000.0,
    );

    let history = super::series::make_interval_history_at(
        vec![old_row, new_row.clone()],
        48,
        interval,
        now,
    );
    let boundary = history
        .iter()
        .position(|point| point.start_unix as f64 + interval as f64 == reset)
        .unwrap();
    let recovered = history
        .iter()
        .position(|point| point.start_unix as f64 + interval as f64 >= new_row.created_at)
        .unwrap();

    assert_eq!(history[boundary].five_hour_remaining_percent, Some(1.0));
    assert!(history[(boundary + 1)..recovered]
        .iter()
        .all(|point| point.five_hour_remaining_percent.is_none()));
    assert_eq!(history[recovered].five_hour_remaining_percent, Some(0.80));
}

#[test]
fn stale_reset_uses_bounded_carry_and_windows_reset_independently() {
    let interval = 5 * 60;
    let now = fixed_series_now(interval);
    let current_bin_start = fixed_bin_start(interval);
    let created_at = current_bin_start - 2.0 * 60.0 * 60.0;
    let five_reset = created_at - 60.0;
    let seven_reset = current_bin_start - 30.0 * 60.0;
    let row = history_row(
        created_at,
        "tester|Pro|codex",
        "Pro",
        Some("codex"),
        50,
        five_reset,
        30,
        seven_reset,
    );

    let history =
        super::series::make_interval_history_at(vec![row], 36, interval, now);
    let five_values = history
        .iter()
        .map(|point| point.five_hour_remaining_percent)
        .collect::<Vec<_>>();
    let seven_boundary = history
        .iter()
        .position(|point| point.start_unix as f64 + interval as f64 == seven_reset)
        .unwrap();

    assert!(!five_values.contains(&Some(1.0)));
    assert!(five_values.contains(&Some(0.50)));
    assert!(history.last().unwrap().five_hour_remaining_percent.is_none());
    assert_eq!(history[seven_boundary].seven_day_remaining_percent, Some(1.0));
    assert_eq!(history[seven_boundary].five_hour_remaining_percent, Some(0.50));
    assert!(history[seven_boundary + 1].seven_day_remaining_percent.is_none());
}

#[test]
fn six_hour_axis_does_not_expand_reset_boundary_into_continuous_full_quota() {
    let interval = 6 * 60 * 60;
    let now = fixed_series_now(interval);
    let current_bin_start = fixed_bin_start(interval);
    let reset = current_bin_start - 2.0 * interval as f64;
    let row = history_row(
        reset - interval as f64,
        "tester|Pro|codex",
        "Pro",
        Some("codex"),
        50,
        reset,
        30,
        now + 500_000.0,
    );

    let history =
        super::series::make_interval_history_at(vec![row], 8, interval, now);
    assert_eq!(
        history
            .iter()
            .filter(|point| point.five_hour_remaining_percent == Some(1.0))
            .count(),
        1
    );
    assert!(history
        .iter()
        .skip_while(|point| point.five_hour_remaining_percent != Some(1.0))
        .skip(1)
        .all(|point| point.five_hour_remaining_percent.is_none()));
}

#[test]
fn daily_history_groups_quota_samples_by_local_day() {
    let path = temp_db_path("daily");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.20, reset as i64, 0.40, (reset + 500_000.0) as i64))
        .unwrap();
    database
        .record(&bundle("tester", 0.30, reset as i64, 0.50, (reset + 500_000.0) as i64))
        .unwrap();

    let local_offset = crate::core::localtime::local_offset();
    let today = format_date(OffsetDateTime::now_utc().to_offset(local_offset).date());
    let history = database.daily_history(1).unwrap();
    let quota = history.get(&today).unwrap();

    assert_eq!(quota.five_hour_remaining_percent, Some(0.75));
    assert_eq!(quota.seven_day_remaining_percent, Some(0.55));

    let _ = std::fs::remove_file(path);
}

#[test]
fn recent_history_uses_canonical_five_minute_axis() {
    let path = temp_db_path("recent-axis");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 3_600.0;

    database
        .record(&bundle("tester", 0.20, reset as i64, 0.40, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database
        .recent_five_minute_history(LONG_RECENT_POINT_COUNT as usize)
        .unwrap();
    let usage_timestamps = crate::core::time_series_timeline::long_recent_bin_starts(
        history.last().unwrap().start_unix,
    );
    assert_eq!(history.len(), usage_timestamps.len());
    assert_eq!(history.first().unwrap().start_unix, usage_timestamps[0]);
    assert_eq!(
        history.last().unwrap().start_unix,
        *usage_timestamps.last().unwrap()
    );
    assert!(history
        .iter()
        .all(|point| point.label.len() == "00:00".len()));
    for pair in history.windows(2) {
        let left = minutes_since_midnight(&pair[0].label);
        let right = minutes_since_midnight(&pair[1].label);
        assert_eq!((right - left).rem_euclid(24 * 60), 5);
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn interval_history_supports_hour_and_six_hour_axes() {
    let path = temp_db_path("interval-axis");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 12.0 * 3_600.0;

    database
        .record(&bundle("tester", 0.20, reset as i64, 0.40, (reset + 500_000.0) as i64))
        .unwrap();

    let hourly = database.recent_history(168, 60 * 60).unwrap();
    assert_eq!(hourly.len(), 168);
    assert!(hourly
        .iter()
        .all(|point| point.label.len() == "00:00".len()));

    let six_hour = database.recent_history(120, 6 * 60 * 60).unwrap();
    assert_eq!(six_hour.len(), 120);
    assert!(six_hour
        .iter()
        .all(|point| point.label.len() == "00:00".len()));

    let _ = std::fs::remove_file(path);
}

#[test]
fn history_bundle_builds_all_axes_from_one_read() {
    let path = temp_db_path("history-bundle");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 12.0 * 3_600.0;

    database
        .record(&bundle("tester", 0.20, reset as i64, 0.40, (reset + 500_000.0) as i64))
        .unwrap();

    let history = database
        .history_bundle(365, LONG_RECENT_POINT_COUNT as usize)
        .unwrap();
    assert_eq!(
        history.recent_24h.len(),
        LONG_RECENT_POINT_COUNT as usize
    );
    assert_eq!(history.recent_7d.len(), 7 * 24);
    assert_eq!(history.recent_30d.len(), 30 * 4);
    assert!(history.daily.iter().any(|point| {
        point.five_hour_remaining_percent == Some(0.80)
            && point.seven_day_remaining_percent == Some(0.60)
    }));
    assert_eq!(
        history.recent_24h.last().unwrap().five_hour_remaining_percent,
        Some(0.80)
    );
    assert_eq!(
        history.recent_7d.last().unwrap().seven_day_remaining_percent,
        Some(0.60)
    );

    let _ = std::fs::remove_file(path);
}

#[test]
fn history_bundle_for_current_account_does_not_follow_a_concurrent_latest_account() {
    let path = temp_db_path("current-account-filter");
    let database = QuotaHistoryDatabase { path: path.clone() };
    let reset = now_unix() + 12.0 * 3_600.0;
    let account_a = bundle("account-a", 0.20, reset as i64, 0.40, (reset + 500_000.0) as i64);
    let account_b = bundle("account-b", 0.70, reset as i64, 0.80, (reset + 500_000.0) as i64);

    database.record(&account_a).unwrap();
    database.record(&account_b).unwrap();

    let history_a = database
        .history_bundle_for(&account_a, 365, LONG_RECENT_POINT_COUNT as usize)
        .unwrap();
    let history_b = database
        .history_bundle_for(&account_b, 365, LONG_RECENT_POINT_COUNT as usize)
        .unwrap();

    assert_eq!(
        history_a.recent_24h.last().unwrap().five_hour_remaining_percent,
        Some(0.80)
    );
    assert_eq!(
        history_b.recent_24h.last().unwrap().five_hour_remaining_percent,
        Some(0.30)
    );
    let _ = std::fs::remove_file(path);
}

#[test]
fn concurrent_account_record_and_load_stays_on_each_account_filter() {
    use std::sync::{Arc, Barrier};

    let path = temp_db_path("concurrent-account-filter");
    let reset = now_unix() + 12.0 * 3_600.0;
    let barrier = Arc::new(Barrier::new(3));
    let recorded = Arc::new(Barrier::new(3));
    let cases = [
        ("account-a", 0.20, 0.80),
        ("account-b", 0.70, 0.30),
    ];
    let handles = cases
        .into_iter()
        .map(|(name, used, expected_remaining)| {
            let path = path.clone();
            let barrier = barrier.clone();
            let recorded = recorded.clone();
            std::thread::spawn(move || {
                let database = QuotaHistoryDatabase { path };
                let account = bundle(
                    name,
                    used,
                    reset as i64,
                    used,
                    (reset + 500_000.0) as i64,
                );
                barrier.wait();
                database.record(&account).unwrap();
                recorded.wait();
                let history = database
                    .history_bundle_for(&account, 365, LONG_RECENT_POINT_COUNT as usize)
                    .unwrap();
                (
                    history.recent_24h.last().unwrap().five_hour_remaining_percent,
                    expected_remaining,
                )
            })
        })
        .collect::<Vec<_>>();

    barrier.wait();
    recorded.wait();
    for handle in handles {
        let (actual, expected) = handle.join().unwrap();
        assert_eq!(actual, Some(expected));
    }
    let _ = std::fs::remove_file(path);
}

#[test]
fn partial_window_rows_remain_missing_until_that_window_is_measured_again() {
    let interval = 5 * 60;
    let current_bin_start = fixed_bin_start(interval);
    let now = fixed_series_now(interval);
    let start = current_bin_start - 2.0 * interval as f64;

    for unavailable_window in ["five", "seven"] {
        let first = history_row(
            start + 1.0,
            "tester|Pro|codex",
            "Pro",
            Some("codex"),
            10,
            current_bin_start + 3_600.0,
            20,
            current_bin_start + 500_000.0,
        );
        let mut partial = first.clone();
        partial.created_at = start + interval as f64 + 1.0;
        partial.five_hour_used_percent = Some(30);
        partial.seven_day_used_percent = Some(40);
        let mut full = partial.clone();
        full.created_at = current_bin_start + 1.0;
        full.five_hour_used_percent = Some(35);
        full.seven_day_used_percent = Some(45);
        assert!(full.created_at <= now);

        match unavailable_window {
            "five" => {
                partial.five_hour_used_percent = None;
                partial.five_hour_resets_at = None;
            }
            "seven" => {
                partial.seven_day_used_percent = None;
                partial.seven_day_resets_at = None;
            }
            _ => unreachable!(),
        }

        let sanitized = super::series::sanitized_rows(vec![
            first.clone(),
            partial.clone(),
            full.clone(),
        ]);
        if unavailable_window == "five" {
            assert_eq!(sanitized[1].five_hour_used_percent, None);
            assert_eq!(sanitized[1].seven_day_used_percent, Some(40));
        } else {
            assert_eq!(sanitized[1].five_hour_used_percent, Some(30));
            assert_eq!(sanitized[1].seven_day_used_percent, None);
        }

        let series = super::series::make_interval_history_at(
            vec![first, partial, full],
            3,
            interval,
            now,
        );
        if unavailable_window == "five" {
            assert_eq!(series[1].five_hour_remaining_percent, None);
            assert!(matches!(
                series[1].seven_day_remaining_percent,
                Some(value) if value > 0.55 && value <= 0.60
            ));
            assert_eq!(series[2].five_hour_remaining_percent, Some(0.65));
        } else {
            assert!(matches!(
                series[1].five_hour_remaining_percent,
                Some(value) if value > 0.65 && value <= 0.70
            ));
            assert_eq!(series[1].seven_day_remaining_percent, None);
            assert_eq!(series[2].seven_day_remaining_percent, Some(0.55));
        }
    }
}

#[test]
fn unavailable_window_ignores_compatibility_zero_when_building_history_row() {
    let reset = now_unix() as i64 + 3_600;
    for unavailable_window in ["five", "seven"] {
        let mut snapshot = bundle("tester", 0.20, reset, 0.40, reset + 500_000);
        let limit = if unavailable_window == "five" {
            &mut snapshot.quota.five_hour
        } else {
            &mut snapshot.quota.seven_day
        };
        limit.availability = crate::models::QuotaAvailability::Unavailable;
        limit.remaining_percent = Some(0.0);
        limit.used_percent = Some(1.0);

        let identity = QuotaHistoryIdentity::from_bundle(
            Path::new("/fixture/unavailable-window"),
            Some("sub:unavailable-window"),
            &snapshot,
            Some("codex"),
        )
        .unwrap();
        let row = QuotaHistoryRow::from_bundle(&identity, &snapshot, now_unix());
        if unavailable_window == "five" {
            assert_eq!(row.five_hour_used_percent, None);
            assert_eq!(row.five_hour_resets_at, None);
            assert_eq!(row.seven_day_used_percent, Some(40));
        } else {
            assert_eq!(row.five_hour_used_percent, Some(20));
            assert_eq!(row.seven_day_used_percent, None);
            assert_eq!(row.seven_day_resets_at, None);
        }
    }
}

fn bundle(
    name: &str,
    five_used: f64,
    five_reset: i64,
    seven_used: f64,
    seven_reset: i64,
) -> AccountQuotaBundle {
    bundle_with_plan(name, "Pro", five_used, five_reset, seven_used, seven_reset)
}

fn bundle_with_plan(
    name: &str,
    plan_label: &str,
    five_used: f64,
    five_reset: i64,
    seven_used: f64,
    seven_reset: i64,
) -> AccountQuotaBundle {
    AccountQuotaBundle {
        updated_at: "2026-07-31T00:00:00Z".into(),
        attribution_identity: None,
        account: AccountInfo {
            display_name: name.into(),
            plan_label: plan_label.into(),
        },
        quota: QuotaSnapshot {
            five_hour: QuotaLimit {
                label: "5h".into(),
                availability: crate::models::QuotaAvailability::Measured,
                remaining_percent: Some(1.0 - five_used),
                used_percent: Some(five_used),
                resets_at: "12:00".into(),
                resets_at_unix: Some(five_reset),
            },
            seven_day: QuotaLimit {
                label: "7d".into(),
                availability: crate::models::QuotaAvailability::Measured,
                remaining_percent: Some(1.0 - seven_used),
                used_percent: Some(seven_used),
                resets_at: "06/18".into(),
                resets_at_unix: Some(seven_reset),
            },
            reset_credit: ResetCreditSummary {
                available_count: 0,
                status: "0 张重置卡".into(),
                credits: Vec::new(),
            },
            pace_label: "测试".into(),
        },
        quota_history_daily: Vec::new(),
        quota_history_24h: Vec::new(),
        quota_history_7d: Vec::new(),
        quota_history_30d: Vec::new(),
        warnings: Vec::new(),
        diagnostics: Vec::new(),
    }
}

#[allow(clippy::too_many_arguments)]
fn history_row(
    created_at: f64,
    account_key: &str,
    plan_type: &str,
    limit_name: Option<&str>,
    five_used_percent: i32,
    five_reset: f64,
    seven_used_percent: i32,
    seven_reset: f64,
) -> QuotaHistoryRow {
    QuotaHistoryRow {
        created_at,
        account_key: account_key.into(),
        plan_type: Some(plan_type.into()),
        limit_name: limit_name.map(str::to_string),
        account_name: Some("tester".into()),
        source: None,
        five_hour_used_percent: Some(five_used_percent),
        five_hour_resets_at: Some(five_reset),
        seven_day_used_percent: Some(seven_used_percent),
        seven_day_resets_at: Some(seven_reset),
        status: "测试".into(),
        identity_version: None,
        home_identity: None,
        stable_account_key: None,
        identity_plan_type: None,
        identity_limit_id: None,
    }
}

fn insert_history_row_with_source(
    connection: &rusqlite::Connection,
    row: &QuotaHistoryRow,
    source: Option<&str>,
) {
    connection
        .execute(
            r#"
            INSERT INTO quota_snapshots (
                created_at, account_key, plan_type, limit_name, account_name, source,
                five_hour_used_percent, five_hour_resets_at,
                seven_day_used_percent, seven_day_resets_at, status
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
            "#,
            rusqlite::params![
                row.created_at,
                row.account_key,
                row.plan_type,
                row.limit_name,
                row.account_name,
                source,
                row.five_hour_used_percent,
                row.five_hour_resets_at,
                row.seven_day_used_percent,
                row.seven_day_resets_at,
                row.status
            ],
        )
        .unwrap();
}

fn temp_db_path(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "codex-token-bar-quota-history-{label}-{}-{}.sqlite",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn temp_dir_path(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "codex-token-bar-quota-history-{label}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn minutes_since_midnight(label: &str) -> i32 {
    let (hour, minute) = label.split_once(':').unwrap();
    hour.parse::<i32>().unwrap() * 60 + minute.parse::<i32>().unwrap()
}

fn fixed_bin_start(interval_seconds: i64) -> f64 {
    crate::core::time_series_timeline::aligned_bin_starts(
        1_800_000_000,
        interval_seconds,
        1,
    )[0] as f64
}

fn fixed_series_now(interval_seconds: i64) -> f64 {
    fixed_bin_start(interval_seconds) + interval_seconds as f64 / 2.0
}

fn recent_point(start_unix: i64) -> RecentUsagePoint {
    RecentUsagePoint {
        label: "00:00".into(),
        start_unix,
        tokens: 0,
        calls: 0,
        input_tokens: 0,
        cached_input_tokens: 0,
        output_tokens: 0,
        model_breakdowns: Vec::new(),
        cache_hit_rate: None,
        five_hour_remaining_percent: None,
        seven_day_remaining_percent: None,
        source_contribution_epoch: None,
        source_contributions: Vec::new(),
    }
}
