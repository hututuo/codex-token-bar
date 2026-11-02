use std::path::PathBuf;

fn main() {
    let Some(root) = std::env::args_os().nth(1).map(PathBuf::from) else {
        println!("{{\"status\":\"FAIL\",\"error\":\"usage: business-store-fixture <absolute-temp-root>\"}}");
        std::process::exit(2);
    };

    let remaining = std::env::args_os().skip(2).collect::<Vec<_>>();
    let result = if remaining.is_empty() {
        codex_token_bar_lib::business_store_fixture::run_fixture(&root)
    } else if remaining.len() == 2 && remaining[0] == "--source-count" {
        remaining[1].to_str().and_then(|value| value.parse::<u64>().ok())
            .ok_or_else(|| "--source-count requires an integer in 9...8192".to_string())
            .and_then(|count| codex_token_bar_lib::business_store_fixture::run_source_count_fixture(&root, count))
    } else {
        Err("usage: business-store-fixture <absolute-temp-root> [--source-count N]".into())
    };
    match result {
        Ok(report) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&report).unwrap_or_else(|error| {
                    format!(
                        "{{\"status\":\"FAIL\",\"error\":{}}}",
                        serde_json::json!(error.to_string())
                    )
                })
            );
        }
        Err(error) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "status": "FAIL",
                    "error": error
                }))
                .unwrap_or_else(|serialize_error| {
                    format!(
                        "{{\"status\":\"FAIL\",\"error\":{}}}",
                        serde_json::json!(serialize_error.to_string())
                    )
                })
            );
            std::process::exit(1);
        }
    }
}
