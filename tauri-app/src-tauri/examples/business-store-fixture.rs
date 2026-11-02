use std::path::PathBuf;

fn main() {
    let Some(root) = std::env::args_os().nth(1).map(PathBuf::from) else {
        println!("{{\"status\":\"FAIL\",\"error\":\"usage: business-store-fixture <absolute-temp-root>\"}}");
        std::process::exit(2);
    };

    let mode=std::env::args().nth(2);
    let result=if matches!(mode.as_deref(),Some("--pool-crash-child"|"--pool-crash-resume")) {
        let point=std::env::args().nth(3).unwrap_or_default();
        codex_token_bar_lib::business_store_fixture::run_pool_crash_probe(&root,&point,mode.as_deref()==Some("--pool-crash-resume"))
    } else {codex_token_bar_lib::business_store_fixture::run_fixture(&root)};
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
