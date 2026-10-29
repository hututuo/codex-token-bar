use std::path::PathBuf;

fn main() {
    let Some(root) = std::env::args_os().nth(1).map(PathBuf::from) else {
        println!("{{\"status\":\"FAIL\",\"error\":\"usage: business-store-fixture <absolute-temp-root>\"}}");
        std::process::exit(2);
    };

    match codex_token_bar_lib::business_store_fixture::run_fixture(&root) {
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
