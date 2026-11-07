use std::path::PathBuf;

fn main() {
    let result = std::env::args_os().nth(1).map(PathBuf::from)
        .ok_or_else(|| "route-identity-fixture requires an absolute disposable root".to_string())
        .and_then(|root| codex_token_bar_lib::business_store_fixture::run_route_identity_fixture(&root));
    match result {
        Ok(report) => println!("{}", serde_json::to_string(&report).expect("fixture JSON")),
        Err(error) => {
            println!("{}", serde_json::json!({"status":"FAIL", "error":error}));
            std::process::exit(1);
        }
    }
}
