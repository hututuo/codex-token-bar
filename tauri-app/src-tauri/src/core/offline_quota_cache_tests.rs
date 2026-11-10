use super::{
    antigravity_local_quota as ag, claude_desktop_http_cache as http, multi_client_product,
    multi_client_usage::ClaudeLocalQuotaSnapshot,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::Value;

fn fixture() -> Value {
    serde_json::from_str(include_str!("../../../../fixtures/local-quota-caches.json")).unwrap()
}

#[test]
fn shared_http_cache_fixtures_keep_integrity_age_reset_and_zero() {
    for row in fixture()["claude"].as_array().unwrap() {
        let bytes = STANDARD
            .decode(row["entryBase64"].as_str().unwrap())
            .unwrap();
        let now = row["now"].as_f64().unwrap();
        let value = http::decode(&bytes, now);
        assert_eq!(
            value.as_ref().map(|s| s.state.as_str()),
            row["expectedState"].as_str(),
            "{}",
            row["name"]
        );
        assert_eq!(
            value
                .as_ref()
                .and_then(|s| s.five_hour.as_ref())
                .map(|w| w.used_percent),
            row["five"].as_f64()
        );
        assert_eq!(
            value
                .as_ref()
                .and_then(|s| s.seven_day.as_ref())
                .map(|w| w.used_percent),
            row["seven"].as_f64()
        );
        if let Some(value) = value.filter(|s| s.state == "available") {
            assert_eq!(value.source.as_deref(), Some("local-desktop-http-cache"));
            assert!(value
                .five_hour
                .or(value.seven_day)
                .unwrap()
                .resets_at
                .is_some());
        }
        assert!(http::decode(&bytes[..bytes.len() - 1], now).is_none());
    }
}

#[test]
fn shared_antigravity_fixtures_keep_accounts_pools_and_unknown_sample_time() {
    for row in fixture()["antigravityTools"].as_array().unwrap() {
        let value = ag::decode_tools(
            &serde_json::to_vec(&row["data"]).unwrap(),
            row["selectedID"].as_str().unwrap(),
            row["now"].as_f64().unwrap(),
        );
        assert_eq!(value.state, row["expectedState"].as_str().unwrap());
        assert_eq!(
            value
                .windows
                .iter()
                .map(|w| w.used_percent.unwrap())
                .collect::<Vec<_>>(),
            row["used"]
                .as_array()
                .unwrap()
                .iter()
                .map(|n| n.as_f64().unwrap())
                .collect::<Vec<_>>()
        );
        assert!(!serde_json::to_string(&value)
            .unwrap()
            .contains("DO-NOT-PROJECT"));
    }
    for row in fixture()["antigravityState"].as_array().unwrap() {
        let value = ag::decode_state(
            row["data"].as_str().unwrap().as_bytes(),
            row["now"].as_f64().unwrap(),
        );
        assert_eq!(value.state, row["expectedState"].as_str().unwrap());
        assert_eq!(
            value
                .windows
                .iter()
                .map(|w| w.used_percent.unwrap())
                .collect::<Vec<_>>(),
            row["used"]
                .as_array()
                .unwrap()
                .iter()
                .map(|n| n.as_f64().unwrap())
                .collect::<Vec<_>>()
        );
        assert!(value.captured_at.is_none());
        assert_ne!(value.state, "available");
    }
}

#[test]
fn newer_cache_does_not_merge_accounts_and_provider_keeps_official_reset() {
    let missing = ClaudeLocalQuotaSnapshot {
        source: None,
        state: "missing".into(),
        captured_at: None,
        five_hour: None,
        seven_day: None,
    };
    let rows = fixture();
    let fresh = &rows["claude"][0];
    let reading = http::decode(
        &STANDARD
            .decode(fresh["entryBase64"].as_str().unwrap())
            .unwrap(),
        fresh["now"].as_f64().unwrap(),
    )
    .unwrap();
    let selected = http::select(missing.clone(), Some(reading.clone()));
    let ag = ag::decode_tools(
        &serde_json::to_vec(&rows["antigravityTools"][0]["data"]).unwrap(),
        "selected-fixture",
        1_800_000_000.0,
    );
    let projected = multi_client_product::quota_provider_snapshots(&missing, &selected, &ag);
    assert_eq!(projected[1].source, "local-desktop-http-cache");
    assert!(projected[1].windows[0].resets_at.is_some());
    assert_eq!(
        projected
            .iter()
            .find(|r| r.client == "antigravity")
            .unwrap()
            .windows
            .len(),
        2
    );
    let bad = ClaudeLocalQuotaSnapshot {
        source: reading.source,
        state: "invalid".into(),
        captured_at: Some("2028-01-01T00:00:00Z".into()),
        five_hour: None,
        seven_day: None,
    };
    assert_eq!(http::select(selected, Some(bad)).state, "invalid");
}

#[test]
fn tools_reader_is_bounded_selected_only_and_does_not_write_source() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    std::fs::create_dir(root.join("accounts")).unwrap();
    let bytes = serde_json::to_vec(&fixture()["antigravityTools"][0]["data"]).unwrap();
    let file = root.join("accounts/selected-fixture.json");
    std::fs::write(&file, &bytes).unwrap();
    std::fs::write(
        root.join("accounts.json"),
        br#"{"current_account_id":"selected-fixture","accounts":[{"id":"selected-fixture"}]}"#,
    )
    .unwrap();
    assert_eq!(ag::read_tools(root, 1_800_000_000.0).state, "available");
    assert_eq!(std::fs::read(&file).unwrap(), bytes);
    std::fs::write(root.join("accounts.json"), br#"{"current_account_id":"../selected-fixture","accounts":[{"id":"../selected-fixture"}]}"#).unwrap();
    assert_eq!(ag::read_tools(root, 1_800_000_000.0).state, "unavailable");
}
