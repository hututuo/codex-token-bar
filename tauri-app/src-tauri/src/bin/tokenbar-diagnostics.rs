#[path="../core/diagnostics/mod.rs"]
mod diagnostics;
fn main(){std::process::exit(diagnostics::cli().unwrap_or(64));}
